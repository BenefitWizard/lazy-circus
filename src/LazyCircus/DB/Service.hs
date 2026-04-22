{-# LANGUAGE TypeFamilyDependencies #-}

module LazyCircus.DB.Service where

import Database.Beam
import Database.Beam.Postgres

import LazyCircus.DB.Types
import RIO

-- | Capability class that maps a Beam table type to its concrete table entity inside a database schema.
class
    ( Beamable table
    , Database Postgres db
    , FromBackendRow Postgres (table Identity)
    ) =>
    IsInDb db table
    where
    getTargetTable :: db f -> f (TableEntity table)

class (IsInDb db table) => HasCreateService db table where
    generateInsert :: PgDB db -> [table Maybe] -> SqlInsert Postgres table

-- runCreate :: (MonadIO m) => Connection -> PgDB db -> [table Maybe] -> m [table Identity]
-- runCreate conn db inptTable = runInsertDebug conn (generateInsert db inptTable)

-- | Capability class for tables that support lookup identifiers, select builders, and a default find runner.
class (IsInDb db table) => HasReadService db table where
    type LId table = result | result -> table

    -- generateSelect :: PgDB db -> LookupId (PK table) -> SqlSelect Postgres (table Identity)
    generateSelect :: PgDB db -> LId table -> SqlSelect Postgres (table Identity)
    generateFiltration :: PgDB db -> LId table -> Filtration table

-- runFind :: (MonadIO m) => Connection -> PgDB db -> LookupId (PK table) -> m [table Identity]
-- runFind :: (MonadIO m) => Connection -> PgDB db -> LId table -> m [table Identity]
-- runFind conn db lid = runSelectDebug conn (generateSelect db lid)

-- | Capability class for tables that can build Beam update assignments and execute a default update runner.
class (HasReadService db table) => HasUpdateService db table where
    generateAssigment :: PgDB db -> table Maybe -> Assigment table

-- runUpdate :: (MonadIO m) => Connection -> PgDB db -> table Maybe -> LId table -> m [table Identity]
-- runUpdate c db inpTable lid =
--     let table = getTargetTable db
--         updateCommand = update table (generateAssigment db inpTable) (generateFiltration db lid) :: SqlUpdate Postgres table
--      in runUpdateDebugWithReturn c updateCommand

class (HasReadService db table) => HasDeleteService db table where
    generateDelete :: PgDB db -> LId table -> SqlDelete Postgres table
    generateDelete db lid =
        let table = getTargetTable db
            deleteCommand = delete table (\t -> generateFiltration db lid t)
         in deleteCommand

-- runDelete :: (MonadIO m) => Connection -> PgDB db -> table Maybe -> LId table -> m [table Identity]
-- runDelete c db _inpTable lid = runDeleteDebug c (generateDelete db lid)