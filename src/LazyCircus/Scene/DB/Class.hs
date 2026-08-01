{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}

module LazyCircus.Scene.DB.Class (
    HasDbConnection (..),
    DBScriptPerformer (..),
    DbError (..),
    runDB,
    withDb,
) where

import Control.Monad.Free.Church (iterM)
import Database.Beam (all_, filter_, runDelete, runSelectReturningList, select, val_, (||.))
import Database.Beam qualified as Beam (delete, update)
import Database.Beam.Backend.SQL.BeamExtensions (runInsertReturningList, runUpdateReturningList)
import Database.Beam.Postgres (Pg, runBeamPostgres)
import Database.Beam.Postgres.Full (PgSelectLockingOptions (..), PgSelectLockingStrength (..), lockingAllTablesFor_)
import Database.Beam.Schema.Tables (Beamable, Columnar' (..), changeBeamRep)
import Database.PostgreSQL.Simple qualified as Simple
import Database.PostgreSQL.Simple.ToField qualified as ToField
import LazyCircus.App.Log (HasLogQueue, HasLoggingContext)
import LazyCircus.DB.Service
    ( HasCreateService
    , HasDeleteService
    , HasReadService
    , HasUpdateService
    , LId
    , generateAssigment
    , generateFiltration
    , generateInsert
    , generateSelect
    , getTargetTable
    )
import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.DB.Lang
import LazyCircus.Scene.DB.RLS (RLSContext, setRLSContext)
import LazyCircus.Scene.Log (handleLogLang, timedAndLog)
import LazyCircus.Scenario (DbMode (..))
import RIO

-- | Environment capability that exposes the PostgreSQL connection used by the default DB interpreter.
class HasDbConnection env where
    dbConnectionL :: Lens' env Simple.Connection

-- | Capability class for interpreting operations in the database free language.
class (Monad m) => DBScriptPerformer m where
    create' :: (HasCreateService db table) => PgDB db -> DbMode -> [table Maybe] -> m [table Identity]
    createAsIs' :: (HasCreateService db table) => PgDB db -> DbMode -> [table Identity] -> m [table Identity]
    find' :: (HasReadService db table) => PgDB db -> DbMode -> LId table -> m [table Identity]

    {- | Interprets a locking lookup that reads rows matching a lookup key and acquires a row lock on them.
    PRE-CONTRACT: Must be called inside 'withTransaction'; a 'FOR UPDATE' lock is released at COMMIT/ROLLBACK. Outside a transaction Postgres auto-commits each statement and the lock is a no-op.
    NOTE: 'WaitNoWait' raises a 'SqlError' (Postgres error) if the row is already locked; it propagates like other raw backend errors.
    -}
    lockAndFind' :: (HasReadService db table) => PgDB db -> DbMode -> LockSpec -> LId table -> m [table Identity]
    update' :: (HasUpdateService db table) => PgDB db -> DbMode -> table Maybe -> LId table -> m [table Identity]
    updateMany' :: (HasUpdateService db table) => PgDB db -> DbMode -> table Maybe -> [LId table] -> m [table Identity]
    delete' :: (HasDeleteService db table) => PgDB db -> DbMode -> LId table -> m ()
    runQuery' :: PgDB db -> DbMode -> (PgDB db -> Pg b) -> m b
    rawQuery' :: (Simple.FromRow b) => DbMode -> Simple.Query -> [ToField.Action] -> m [b]
    withTransaction' :: PgDB db -> DbMode -> Maybe RLSContext -> DBScript db b -> m b

instance
    ( Monad m
    , HasDbConnection env
    , HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadIO m
    , MonadUnliftIO m
    ) =>
    DBScriptPerformer m
    where
    create' db _mode tables = timedAndLog "DB" "Create" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $ runInsertReturningList (generateInsert db tables)

    createAsIs' db _mode tables = timedAndLog "DB" "CreateAsIs" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $ runInsertReturningList (generateInsert db (map identityToMaybe tables))

    find' db _mode lid = timedAndLog "DB" "Find" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $ runSelectReturningList $ generateSelect db lid

    lockAndFind' db _mode spec lid = timedAndLog "DB" "LockAndFind" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $
            runSelectReturningList $ select $
                lockingAllTablesFor_ (toPgStrength (lockSpecStrength spec))
                                     (toPgWaiting (lockSpecWaiting spec)) $
                filter_ (generateFiltration db lid) $
                all_ (getTargetTable db)
      where
        -- | Maps the DSL lock strength onto the beam-postgres locking-strength enum (the 'FOR UPDATE' family).
        toPgStrength LockUpdate = PgSelectLockingStrengthUpdate
        toPgStrength LockNoKeyUpdate = PgSelectLockingStrengthNoKeyUpdate
        toPgStrength LockShare = PgSelectLockingStrengthShare
        toPgStrength LockKeyShare = PgSelectLockingStrengthKeyShare
        -- | Maps the DSL waiting policy onto the optional 'NOWAIT'/'SKIP LOCKED' clause; 'WaitDefault' yields no clause.
        toPgWaiting WaitDefault = Nothing
        toPgWaiting WaitNoWait = Just PgSelectLockingOptionsNoWait
        toPgWaiting WaitSkipLocked = Just PgSelectLockingOptionsSkipLocked

    update' db _mode table lid = timedAndLog "DB" "Update" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $
            runUpdateReturningList $
                Beam.update (getTargetTable db) (generateAssigment db table) (generateFiltration db lid)

    updateMany' db _mode table lids = timedAndLog "DB" "UpdateMany" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $
            runUpdateReturningList $
                Beam.update (getTargetTable db) (generateAssigment db table) $
                    \t -> foldr (\lid' rest -> generateFiltration db lid' t ||. rest) (val_ False) lids

    delete' db _mode lid = timedAndLog "DB" "Delete" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn $ runDelete $
            Beam.delete (getTargetTable db) (\t -> generateFiltration db lid t)

    runQuery' db _mode pg = timedAndLog "DB" "RunQuery" $ do
        conn <- view dbConnectionL
        liftIO $ runBeamPostgres conn (pg db)

    rawQuery' _mode q params = timedAndLog "DB" "RawQuery" $ do
        conn <- view dbConnectionL
        liftIO $ Simple.query conn q params

    withTransaction' db mode mCtx script = timedAndLog "DB" "WithTransaction" $ do
        conn <- view dbConnectionL
        withRunInIO $ \runInIO ->
            Simple.withTransaction conn $ do
                setRLSContext conn mCtx
                runInIO (runDB db mode script)

data DbError
    = DbReadOnlyViolation
    deriving (Show)

instance Exception DbError

{- | Interprets a 'DBScript' by folding each algebra instruction into the provided 'DBScriptPerformer'.
PRE-CONTRACT: The target monad must provide a 'DBScriptPerformer' instance that handles every 'DBLangF' constructor,
and must also provide 'HasLogQueue' and 'HasLoggingContext' for logging support.
POST-CONTRACT: Executes the scripted database operations in order and returns the final script result in the target monad.
-}
runDB ::
    ( DBScriptPerformer m
    , HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadIO m
    , MonadUnliftIO m
    ) =>
    PgDB db ->
    DbMode ->
    DBScript db a ->
    m a
runDB db mode = iterM go
  where
    go (Create tables next) = do
        ensureReadWrite mode
        result <- create' db mode tables
        next result
    go (CreateAsIs tables next) = do
        ensureReadWrite mode
        result <- createAsIs' db mode tables
        next result
    go (Find lid next) = do
        result <- find' db mode lid
        next result
    go (LockAndFind spec lid next) = do
        result <- lockAndFind' db mode spec lid
        next result
    go (Update table lid next) = do
        ensureReadWrite mode
        result <- update' db mode table lid
        next result
    go (UpdateMany table lids next) = do
        ensureReadWrite mode
        result <- updateMany' db mode table lids
        next result
    go (Delete lid next) = do
        ensureReadWrite mode
        delete' db mode lid
        next
    go (RunQuery pg next) = do
        result <- runQuery' db mode pg
        next result
    go (RawQuery q params next) = do
        result <- rawQuery' mode q params
        next result
    go (WithTransaction mCtx script next) = do
        result <- withTransaction' db mode mCtx script
        next result
    go (DBLog logOp next) = handleLogLang "DB" (runDB db mode) (fmap next logOp)

{- | Backward-compatible alias for the environment-driven DB interpreter.
PRE-CONTRACT: The environment must expose a PostgreSQL connection through 'dbConnectionL'.
POST-CONTRACT: Executes the scripted database operations against the current environment connection.
-}
withDb ::
    ( HasDbConnection env
    , HasLogQueue env
    , HasLoggingContext env
    , MonadReader env m
    , MonadIO m
    , MonadUnliftIO m
    ) =>
    PgDB db ->
    DbMode ->
    DBScript db a ->
    m a
withDb = runDB

ensureReadWrite :: (MonadIO m) => DbMode -> m ()
ensureReadWrite ReadWrite = pure ()
ensureReadWrite ReadOnly = throwIO DbReadOnlyViolation

identityToMaybe :: (Beamable t) => t Identity -> t Maybe
identityToMaybe = changeBeamRep (\(Columnar' a) -> Columnar' (Just a))
