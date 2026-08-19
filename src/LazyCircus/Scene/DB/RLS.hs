{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module LazyCircus.Scene.DB.RLS (
    RLSContext (..),
    unRLSContext,
    noRLS,
    RLSConfigError (..),
    setRLSContext,
) where

import Control.Exception qualified as CE
import Database.PostgreSQL.Simple (SqlError (..))
import Database.PostgreSQL.Simple qualified as Simple
import Database.PostgreSQL.Simple.Types (Only (..), Query (..))
import RIO

-- | Row-level security settings applied inside a transaction.
-- Each pair maps to a @SET LOCAL rls.<key> = <value>@ statement (the value
-- is bound as a parameter; the key is interpolated and is a domain-level
-- constant). The setting is scoped to the current transaction and reset on
-- COMMIT\/ROLLBACK, so a pooled connection never leaks its context to the
-- next checkout.
-- Construct directly with domain-specific keys, e.g. @RLSContext [("tenant_id", "42")]@;
-- combine contexts with '<>' / 'mempty'.
newtype RLSContext = RLSContext [(Text, Text)]
    deriving (Show, Eq, Semigroup, Monoid)

unRLSContext :: RLSContext -> [(Text, Text)]
unRLSContext (RLSContext pairs) = pairs

noRLS :: RLSContext
noRLS = mempty

data RLSConfigError = RLSConfigError
    { rlsConfigKey :: Text
    , rlsConfigMessage :: ByteString
    }
    deriving (Show)

instance Exception RLSConfigError

{- | Apply the RLS context on the connection, scoped to the CURRENT transaction.

Each pair becomes @SET LOCAL rls.<key> = <value>@ with the value bound as
a parameter (extended query protocol; @SET@ accepts bind parameters in
Parse\/Bind — verified against PostgreSQL 17 by test/DBLangSpec.hs). The
LOCAL scope means the setting vanishes on COMMIT\/ROLLBACK, so a pooled
connection checked out by the next script starts context-free.

PRE-CONTRACT: Must be called inside an open transaction (right after BEGIN),
otherwise the setting is applied to the whole session and leaks across pool
reuse (withTransaction' satisfies this by calling it immediately after
'Simple.withTransaction' opens BEGIN).
POST-CONTRACT: @current_setting('rls.<key>')@ returns the value for the
remainder of the transaction. Throws 'RLSConfigError' on a SQL failure.
-}
setRLSContext :: Simple.Connection -> Maybe RLSContext -> IO ()
setRLSContext _ Nothing = pure ()
setRLSContext conn (Just ctx) = for_ (unRLSContext ctx) $ \(k, v) -> do
    result <-
        CE.try $
            Simple.execute
                conn
                (Query $ encodeUtf8 $ "SET LOCAL rls." <> k <> " = ?")
                (Only v)
    case result of
        Left (e :: SqlError) ->
            throwIO $
                RLSConfigError
                    { rlsConfigKey = k
                    , rlsConfigMessage = sqlErrorMsg e
                    }
        Right _ -> pure ()
