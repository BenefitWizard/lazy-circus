{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}

module LazyCircus.Scene.DB.Lang (
    DBLangF (..),
    create,
    createMany,
    createAsIs,
    createManyAsIs,
    delete,
    update,
    updateMany,
    findAll,
    find,
    runQuery,
    rawQuery,
    withTransaction,
    withTransactionRLS,
    withQSTransaction,
    DBScript,
) where

import Control.Monad.Free.Church (F)
import Control.Monad.Free.Church qualified as CF
import Control.Monad.Free.Class qualified as MF
import Database.Beam.Postgres (Pg)
import Database.PostgreSQL.Simple qualified as Simple
import Database.PostgreSQL.Simple.ToField qualified as ToField
import LazyCircus.DB.Service (
    HasCreateService,
    HasDeleteService,
    HasReadService,
    HasUpdateService,
    LId,
    )
import LazyCircus.DB.Types
import LazyCircus.Scene.DB.RLS (RLSContext, rlsQSId)
import LazyCircus.Scene.Log (HasLogLang (..), LogLangF)
import RIO

liftFC :: (Functor f, MF.MonadFree f m) => f a -> m a
liftFC = CF.liftF

data DBLangF db a where
    Update :: (HasUpdateService db table) => table Maybe -> LId table -> ([table Identity] -> a) -> DBLangF db a
    UpdateMany :: (HasUpdateService db table) => table Maybe -> [LId table] -> ([table Identity] -> a) -> DBLangF db a
    Create :: (HasCreateService db table) => [table Maybe] -> ([table Identity] -> a) -> DBLangF db a
    Delete :: (HasDeleteService db table) => LId table -> a -> DBLangF db a
    CreateAsIs :: (HasCreateService db table) => [table Identity] -> ([table Identity] -> a) -> DBLangF db a
    Find :: (HasReadService db table) => LId table -> ([table Identity] -> a) -> DBLangF db a
    RunQuery :: (PgDB db -> Pg b) -> (b -> a) -> DBLangF db a
    RawQuery :: (Simple.FromRow b) => Simple.Query -> [ToField.Action] -> ([b] -> a) -> DBLangF db a
    WithTransaction :: Maybe RLSContext -> DBScript db b -> (b -> a) -> DBLangF db a
    DBLog :: LogLangF (DBScript db) b -> (b -> a) -> DBLangF db a

instance Functor (DBLangF db) where
    fmap f (Create table next) = Create table (f . next)
    fmap f (Delete lid next) = Delete lid (f next)
    fmap f (CreateAsIs table next) = CreateAsIs table (f . next)
    fmap f (Update table lid next) = Update table lid (f . next)
    fmap f (Find lid next) = Find lid (f . next)
    fmap f (RunQuery pg next) = RunQuery pg (f . next)
    fmap f (RawQuery q params next) = RawQuery q params (f . next)
    fmap f (WithTransaction ctx db next) = WithTransaction ctx db (f . next)
    fmap f (UpdateMany table lids next) = UpdateMany table lids (f . next)
    fmap f (DBLog logOp next) = DBLog logOp (f . next)

instance HasLogLang (DBLangF db) (DBScript db) where
    embedLog logOp = DBLog logOp id

{- | Lifts a single create request into the database script language.
PRE-CONTRACT: The target table must provide a create service for the selected database.
POST-CONTRACT: Produces a script that returns the first inserted row, or Nothing when the database returns no rows.
-}
create :: (HasCreateService db table) => table Maybe -> F (DBLangF db) (Maybe (table Identity))
create table = liftFC $ Create [table] listToMaybe

{- | Lifts a delete request identified by a lookup key into the database script language.
PRE-CONTRACT: The target table must provide a delete service for the selected database.
POST-CONTRACT: Produces a script that deletes matching rows and returns unit.
-}
delete :: (HasDeleteService db table) => LId table -> F (DBLangF db) ()
delete lid = liftFC $ Delete lid ()

{- | Lifts a batched create request into the database script language.
PRE-CONTRACT: The target table must provide a create service for the selected database.
POST-CONTRACT: Produces a script that returns all inserted rows.
-}
createMany :: (HasCreateService db table) => [table Maybe] -> F (DBLangF db) [table Identity]
createMany tables = liftFC $ Create tables id

{- | Lifts insertion of a fully materialized row into the database script language.
PRE-CONTRACT: The target table must support insertion for the selected database.
POST-CONTRACT: Produces a script that returns the first inserted row, or Nothing when the database returns no rows.
-}
createAsIs :: (HasCreateService db table) => table Identity -> F (DBLangF db) (Maybe (table Identity))
createAsIs table = liftFC $ CreateAsIs [table] listToMaybe

{- | Lifts insertion of multiple fully materialized rows into the database script language.
PRE-CONTRACT: The target table must support insertion for the selected database.
POST-CONTRACT: Produces a script that returns all inserted rows.
-}
createManyAsIs :: (HasCreateService db table) => [table Identity] -> F (DBLangF db) [table Identity]
createManyAsIs tables = liftFC $ CreateAsIs tables id

{- | Lifts an update request for a single lookup key into the database script language.
PRE-CONTRACT: The target table must provide an update service for the selected database.
POST-CONTRACT: Produces a script that returns the rows reported as updated by the interpreter.
-}
update :: (HasUpdateService db table) => table Maybe -> LId table -> F (DBLangF db) [table Identity]
update table lid = liftFC $ Update table lid id

{- | Lifts an update request that targets multiple lookup keys into the database script language.
PRE-CONTRACT: The target table must provide an update service for the selected database.
POST-CONTRACT: Produces a script that returns the rows reported as updated by the interpreter.
-}
updateMany :: (HasUpdateService db table) => table Maybe -> [LId table] -> F (DBLangF db) [table Identity]
updateMany table lids = liftFC $ UpdateMany table lids id

{- | Lifts a lookup that returns all rows matched by a lookup key into the database script language.
PRE-CONTRACT: The target table must provide a read service for the selected database.
POST-CONTRACT: Produces a script that returns every matching row reported by the interpreter.
-}
findAll :: (HasReadService db table) => LId table -> F (DBLangF db) [table Identity]
findAll lid = liftFC $ Find lid id

{- | Lifts a lookup that keeps only the first matched row into the database script language.
PRE-CONTRACT: The target table must provide a read service for the selected database.
POST-CONTRACT: Produces a script that returns 'Nothing' when the interpreter reports no matches.
-}
find :: (HasReadService db table) => LId table -> F (DBLangF db) (Maybe (table Identity))
find lid = liftFC $ Find lid listToMaybe

{- | Lifts a raw Beam query into the database script language.
PRE-CONTRACT: The query must be valid for the selected database schema.
POST-CONTRACT: Produces a script that returns the query result supplied by the interpreter.
-}
runQuery :: (PgDB db -> Pg b) -> F (DBLangF db) b
runQuery pg = liftFC $ RunQuery pg id

{- | Lifts a raw SQL SELECT query into the database script language.
PRE-CONTRACT: The SQL must be a parameterized SELECT statement whose result rows can be decoded with the supplied 'Simple.FromRow' instance.
POST-CONTRACT: Produces a script that returns all rows decoded by the interpreter.
-}
rawQuery :: (Simple.FromRow b) => Simple.Query -> [ToField.Action] -> F (DBLangF db) [b]
rawQuery q params = liftFC $ RawQuery q params id

{- | Lifts a database subprogram so an interpreter can run it transactionally.
PRE-CONTRACT: The nested script must be valid for the same database language.
POST-CONTRACT: Produces a script that returns the nested result after transactional execution.
-}
withTransaction :: DBScript db b -> F (DBLangF db) b
withTransaction dbScript = liftFC $ WithTransaction Nothing dbScript id

{- | Lifts a database subprogram with RLS context so an interpreter can run it transactionally with row-level security.
PRE-CONTRACT: The nested script must be valid for the same database language.
POST-CONTRACT: Produces a script that returns the nested result after transactional execution with RLS applied.
-}
withTransactionRLS :: RLSContext -> DBScript db b -> F (DBLangF db) b
withTransactionRLS ctx script = liftFC $ WithTransaction (Just ctx) script id

{- | Convenience wrapper for QuickSpell RLS context.
PRE-CONTRACT: The nested script must be valid for the same database language.
POST-CONTRACT: Produces a script that returns the nested result after transactional execution with QuickSpell RLS applied.
-}
withQSTransaction :: Int32 -> DBScript db b -> F (DBLangF db) b
withQSTransaction qsId script = liftFC $ WithTransaction (Just $ rlsQSId qsId) script id

type DBScript db = F (DBLangF db)
