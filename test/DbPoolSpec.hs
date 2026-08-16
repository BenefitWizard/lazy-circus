{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | hspec coverage for the 'DefaultApp' PostgreSQL pool concurrency semantics:
-- per-script connection checkout, concurrent transactions on distinct connections,
-- and async-queue integration with the worker pool. All scenarios run through the
-- production performer path (@runDefaultPerformer . 'LazyCircus.Scenario.run' \@Script \@NoServiceLib@),
-- so each DB script checks out its own pooled connection exactly like production.
module DbPoolSpec (spec) where

import Common (CircusActT (..), SimpleDb, simpleDb)
import Data.Pool (destroyAllResources)
import Database.PostgreSQL.Simple (Connection, Only (..), close, fromOnly, query_)
import Database.PostgreSQL.Simple.ToField (toField)
import Database.PostgreSQL.Simple.Types (Query (..))
import DemoEnv (setupDatabase, testConnectionString)
import LazyCircus (dbScript)
import LazyCircus.App.Default (DefaultApp (..), DefaultAppConfig (..), MailCreds (..), newDefaultApp)
import LazyCircus.App.Service (NoServiceLib (..))
import LazyCircus.AsyncWorker (runAsyncWorkerPool)
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Scene.DB (DBScript, create, rawQuery, withTransaction)
import LazyCircus.Scenario (DbMode (..), ScenarioProgram, evalScript, run, runAsync)
import LazyCircus.Script (Script)
import RIO
import Test.Hspec
import TestDbSupport (openTestConn)

-- | Generous upper bound for one pool scenario, tolerating slow CI machines.
tenSeconds :: Int
tenSeconds = 10 * 1000000

-- | Marker circus_id isolating the rows inserted by the async-queue scenario.
asyncMarkerCircusId :: Int32
asyncMarkerCircusId = 424242

-- | Names of the rows the async-queue scenario schedules for insertion.
asyncActNames :: [Text]
asyncActNames = map (\i -> "pool async act " <> tshow i) [1 :: Int .. 3]

-- | Fixed advisory-lock key shared by both concurrent transactions of the isolation scenario.
advisoryLockKey :: Int64
advisoryLockKey = 90210

-- | Reads the session's backend pid while holding the checked-out connection
-- for a moment, so two concurrent scripts are guaranteed to be in flight together.
heldPidQuery :: Query
heldPidQuery = "SELECT pg_backend_pid() FROM (SELECT pg_sleep(0.3)) AS hold"

-- | Takes the fixed-key transactional advisory lock; decodes a witness row count.
advisoryLockQuery :: Query
advisoryLockQuery = "SELECT 1 FROM (SELECT pg_advisory_xact_lock(?)) AS lock_holder"

-- | Selects the marker rows inserted by the async worker pool scenario.
markerSelect :: Query
markerSelect =
    Query . encodeUtf8 $
        "SELECT name FROM circus_acts WHERE circus_id = "
            <> tshow asyncMarkerCircusId
            <> " ORDER BY id"

-- | Run a test action with a DefaultApp over a fresh test database and a
-- 10-connection read-write pool, built honestly through 'newDefaultApp'.
-- PRE-CONTRACT: PostgreSQL must be reachable at 127.0.0.1:5432.
-- POST-CONTRACT: Both pools are released via 'destroyAllResources' after the
-- action completes, honouring the 'newDefaultApp' teardown contract.
withPoolTestApp :: (DefaultApp NoServiceLib -> IO ()) -> IO ()
withPoolTestApp action = do
    setupDatabase
    bracket
        ( newDefaultApp
            DefaultAppConfig
                { cfgPgConnectionString = testConnectionString
                , cfgPgConnectionStringReadOnly = Nothing
                , cfgPgPoolMaxResources = 10
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

-- | Execute a scenario through the production performer stack, mirroring 'runDemoScenario'.
runProdScenario :: DefaultApp NoServiceLib -> ScenarioProgram Script NoServiceLib a -> IO a
runProdScenario app scenario =
    runRIO app $ runDefaultPerformer $ run @Script @NoServiceLib scenario

-- | Run two probes concurrently and collect both results under a ten-second budget.
-- PRE-CONTRACT: The probes are independent actions sharing one app.
-- POST-CONTRACT: Returns 'Just' both results once both probes finish, or 'Nothing'
-- only when the deadline passed.
concurrentPair :: IO a -> IO a -> IO (Maybe (a, a))
concurrentPair probeA probeB = timeout tenSeconds $ do
    a <- async probeA
    b <- async probeB
    waitBoth a b

-- | Start a worker pool of the requested size draining the app's scheduled-actions queue.
-- PRE-CONTRACT: No other drainer may run on the same queue (the app built by
-- 'withPoolTestApp' starts no workers of its own).
-- POST-CONTRACT: The pool is cancelled and reaped on release, strictly BEFORE the
-- surrounding 'withPoolTestApp' teardown destroys the connection pools, so a dead
-- worker can never touch a destroyed pool.
withWorkerPool :: Word -> DefaultApp NoServiceLib -> IO a -> IO a
withWorkerPool size app =
    bracket
        (async (runRIO app (runAsyncWorkerPool size (runDefaultPerformer . run @Script @NoServiceLib))))
        (\workers -> cancel workers >> void (waitCatch workers))
        . const

-- | Reads the backend pid after holding the connection briefly.
heldPidScript :: DBScript SimpleDb [Only Int]
heldPidScript = rawQuery heldPidQuery []

-- | Inside one transaction: acquires the fixed-key transactional advisory lock,
-- then reads the backend pid while holding the connection briefly, so the
-- transaction (and its pooled connection) stays open while the concurrent twin
-- blocks on the same lock.
advisoryPidScript :: DBScript SimpleDb [Only Int]
advisoryPidScript = withTransaction $ do
    _ :: [Only Int] <- rawQuery advisoryLockQuery [toField advisoryLockKey]
    rawQuery heldPidQuery []

-- | Inserts one marker row via the 'simpleDb' create service.
insertActScenario :: Text -> ScenarioProgram Script NoServiceLib ()
insertActScenario actName = void $ evalScript $ dbScript simpleDb ReadWrite $ create CircusAct
    { circusActId = Nothing
    , circusActName = Just actName
    , circusId = Just asyncMarkerCircusId
    , circusActDescription = Just "inserted by the async worker pool"
    , circusActAudienceReaction = Nothing
    }

-- | Schedules one async insert per marker row through the production runAsync path.
scheduleInsertsScenario :: ScenarioProgram Script NoServiceLib ()
scheduleInsertsScenario = mapM_ (runAsync . insertActScenario) asyncActNames

-- | Polls the marker rows until every scheduled insert is visible, up to 50 x 200ms.
-- PRE-CONTRACT: The connection targets the database the pool workers write to.
-- POST-CONTRACT: Returns the visible marker names ordered by insertion id; the list
-- is shorter than 'asyncActNames' only when the deadline passed.
pollMarkerRows :: Connection -> Int -> IO [Text]
pollMarkerRows conn remaining = do
    names <- map fromOnly <$> query_ conn markerSelect
    if length names >= length asyncActNames || remaining <= 0
        then pure names
        else threadDelay 200000 >> pollMarkerRows conn (remaining - 1)

spec :: Spec
spec = aroundAll withPoolTestApp $
    describe "DbPool" $ do
        it "checks out distinct backend connections for concurrent DB scripts" $ \app -> do
            let fetchPid = runProdScenario app (evalScript $ dbScript simpleDb ReadWrite heldPidScript)
            mPids <- concurrentPair fetchPid fetchPid
            case mPids of
                Nothing -> expectationFailure "concurrent pid probes did not complete within 10s"
                Just ([Only pidA], [Only pidB]) -> pidA `shouldNotBe` pidB
                Just (otherA, otherB) ->
                    expectationFailure ("unexpected pid probe shapes: " <> show (otherA, otherB))

        it "runs concurrent same-key advisory transactions on distinct connections" $ \app -> do
            let fetchTxnPid = runProdScenario app (evalScript $ dbScript simpleDb ReadWrite advisoryPidScript)
            mPids <- concurrentPair fetchTxnPid fetchTxnPid
            case mPids of
                Nothing -> expectationFailure "concurrent advisory transactions did not complete within 10s"
                Just ([Only pidA], [Only pidB]) -> pidA `shouldNotBe` pidB
                Just (otherA, otherB) ->
                    expectationFailure ("unexpected pid probe shapes: " <> show (otherA, otherB))

        it "drains runAsync-scheduled inserts through the worker pool" $ \app ->
            withWorkerPool 3 app $ do
                runProdScenario app scheduleInsertsScenario
                names <- bracket openTestConn close (\conn -> pollMarkerRows conn 50)
                names `shouldMatchList` asyncActNames
