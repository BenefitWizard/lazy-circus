module LazyCircus.DB.Types where

import Database.Beam
import Database.Beam.Postgres
import RIO (Bool)

type PgDB db = DatabaseSettings Postgres db

-- | Alias a Beam table entity bound to the Postgres backend for a specific database schema.
type TargetDBTable table db = DatabaseEntity Postgres db (TableEntity table)

-- | Alias the Beam primary-key type for a table specialized to concrete row identities.
type PK table = PrimaryKey table Identity

-- type Assigment table = forall s. (Beamable table) => (table (QField s) -> QAssignment Postgres s)

-- | Alias a Beam update assignment builder over one table row expression.
type Assigment table = forall s. (table (QField s) -> QAssignment Postgres s)

-- type Filtration table = forall s. (Beamable table) => (table (QExpr Postgres s) -> QExpr Postgres s Bool)

-- | Alias a Beam filter predicate builder over one table row expression.
type Filtration table = forall s. (table (QExpr Postgres s) -> QExpr Postgres s Bool)
