module LazyCircus.DB.Class (
    HasPgConnection (..),
    HasPgConnectionReadOnly (..),
) where

import Database.Beam.Postgres (Connection)
import RIO

-- | Environment capability that exposes the active PostgreSQL connection.
class HasPgConnection env where
    postgresL :: Lens' env Connection

{- | Environment capability that exposes an optional read-only PostgreSQL connection.
When the read-only connection is not available (Nothing), interpreters should fall back
to the primary read-write connection.
-}
class HasPgConnectionReadOnly env where
    postgresReadOnlyL :: Lens' env (Maybe Connection)
