{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Scenario-level coverage for 'tenantTransaction' ("LazyCircus"): the body
-- runs as one ReadWrite transaction with the RLS context applied via
-- @SET LOCAL rls.*@, the setting is gone from the same session once the
-- wrapper commits, and exceptions roll back and propagate through the
-- scenario layer.
module TenantTransactionSpec (spec) where

import Common (CircusActT (..), SimpleDb, rlsCircusId, simpleDb)
import Data.Pool (destroyAllResources)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.Types (Query (..))
import DemoEnv (setupDatabase, testConnectionString)
import LazyCircus (dbScript, tenantTransaction)
import LazyCircus.App.Default (DefaultApp (..), DefaultAppConfig (..), MailCreds (..), newDefaultApp)
import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Scene.DB (DBScript, create, rawQuery)
import LazyCircus.Scenario (DbMode (..), ScenarioProgram, evalScript, run)
import LazyCircus.Script (Script)
import RIO
import Test.Hspec

spec :: Spec
spec = around withTenantApp $
    describe "TenantTransaction" $ do
        it "exposes the tenant setting inside the wrapper and hides it outside (same session)" $ \app -> do
            [(insideSetting, insidePid)] <-
                runProdScenario app $ tenantTransaction simpleDb (rlsCircusId 42) settingAndPid
            insideSetting `shouldBe` "42"

            [(outsideSetting, outsidePid)] <-
                runProdScenario app $ evalScript $ dbScript simpleDb ReadWrite settingAndPidMissingOk
            outsideSetting `shouldBe` Just ""
            outsidePid `shouldBe` insidePid

        it "rolls back and propagates exceptions raised by the body" $ \app -> do
            runProdScenario app (tenantTransaction simpleDb (rlsCircusId 7) failingTenantScript)
                `shouldThrow` anyException

            remaining <- runProdScenario app $ evalScript $ dbScript simpleDb ReadWrite countActs
            remaining `shouldBe` [Only (0 :: Int64)]

-- | Execute a scenario through the production performer stack.
runProdScenario :: DefaultApp NoServiceLib -> ScenarioProgram Script NoServiceLib a -> IO a
runProdScenario app scenario =
    runRIO app $ runDefaultPerformer $ run @Script @NoServiceLib scenario

-- | Run an action with a production DefaultApp over a freshly migrated test
-- database and a single-connection read-write pool, so consecutive scenarios
-- observe the same backend session.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: The pool is destroyed after the action completes.
withTenantApp :: (DefaultApp NoServiceLib -> IO ()) -> IO ()
withTenantApp action = do
    setupDatabase
    bracket
        ( newDefaultApp
            DefaultAppConfig
                { cfgPgConnectionString = testConnectionString
                , cfgPgConnectionStringReadOnly = Nothing
                , cfgPgPoolMaxResources = 1
                , cfgBotConfigs = []
                , cfgAiApiKey = Nothing
                , cfgAiBaseUrl = Nothing
                , cfgMailCreds = MailCreds "127.0.0.1" 1025 "test" "" "Test" False
                , cfgExtraContext = mempty
                , cfgSqlLogAction = Nothing
                , cfgServiceLib = NoServiceLib
                }
        )
        ( \app -> do
            destroyAllResources (pgDbPool app)
            mapM_ destroyAllResources (pgDbPoolReadOnly app)
        )
        action

-- | Inserts one demo act, then fails with a SQL error, all inside the wrapper.
failingTenantScript :: DBScript SimpleDb ()
failingTenantScript = do
    _ <- create doomedActMaybe
    _ <- badQuery
    pure ()

-- | One demo act inserted by the rollback test before the failure hits.
doomedActMaybe :: CircusActT Maybe
doomedActMaybe =
    CircusAct
        { circusActId = Nothing
        , circusActName = Just "Doomed"
        , circusId = Just 7
        , circusActDescription = Just "rolled back"
        , circusActAudienceReaction = Just Nothing
        }

-- | Failing probe: a raw query naming a nonexistent column, so the SQL error
-- surfaces from PostgreSQL itself.
badQuery :: DBScript SimpleDb [Only Int]
badQuery = rawQuery (Query "SELECT definitely_missing_column FROM circus_acts") []

-- | Counts the rows left in the demo table.
countActs :: DBScript SimpleDb [Only Int64]
countActs = rawQuery (Query "SELECT count(*) FROM circus_acts") []

-- | Reads the tenant setting (required form) and the backend pid of the session.
settingAndPid :: DBScript SimpleDb [(Text, Int32)]
settingAndPid = rawQuery (Query "SELECT current_setting('rls.circus_id'), pg_backend_pid()") []

-- | Reads the tenant setting in missing-ok form together with the backend pid,
-- so the same session can be identified across two consecutive scripts.
settingAndPidMissingOk :: DBScript SimpleDb [(Maybe Text, Int32)]
settingAndPidMissingOk = rawQuery (Query "SELECT current_setting('rls.circus_id', true), pg_backend_pid()") []
