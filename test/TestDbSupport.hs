{-# LANGUAGE OverloadedStrings #-}

module TestDbSupport (
    TestDbEnv (..),
    TestRow (..),
    withFreshTestDb,
    runDbScript,
    queryActs,
    openTestConn,
    ) where

import Common (migration)
import Database.PostgreSQL.Simple (Connection, Only (..), close, connectPostgreSQL, execute_, query_)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Query (..))
import LazyCircus.App.Log
import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.DB.Class (HasDbConnection (..), withDb)
import LazyCircus.Scene.DB.Lang (DBScript)
import LazyCircus.Scenario (DbMode)
import RIO
import RIO.ByteString qualified as B
import RIO.Time (NominalDiffTime)
import Test.Hspec (ActionWith)

data TestDbEnv = TestDbEnv
    { testDbConn :: Connection
    , testDbLogQueue :: LogQueue
    , testDbLogContext :: LoggingContext
    }

data TestRow = TestRow
    { testRowId :: Int32
    , testRowName :: Text
    , testRowCircusId :: Int32
    , testRowDescription :: Text
    , testRowAudienceReaction :: Maybe Text
    }
    deriving (Eq, Show)

instance FromRow TestRow where
    fromRow = TestRow <$> field <*> field <*> field <*> field <*> field

instance HasDbConnection TestDbEnv where
    dbConnectionL = lens testDbConn (\env conn -> env{testDbConn = conn})

instance HasLogQueue TestDbEnv where
    logQueueL = lens testDbLogQueue (\env queue -> env{testDbLogQueue = queue})

instance HasLoggingContext TestDbEnv where
    logContextL = lens testDbLogContext (\env ctx -> env{testDbLogContext = ctx})

withFreshTestDb :: ActionWith TestDbEnv -> IO ()
withFreshTestDb action = bracket setup teardown action
  where
    setup = do
        adminConn <- retryConnect adminConnectionString
        recreateTestDatabase adminConn
        close adminConn

        bootstrapConn <- retryConnect adminTestConnectionString
        void $ execute_ bootstrapConn (Query "SET client_min_messages TO warning")
        void $ execute_ bootstrapConn (Query $ encodeUtf8 migration)
        close bootstrapConn

        conn <- retryConnect testConnectionString
        queue <- newTQueueIO
        pure $ TestDbEnv conn queue mempty

    teardown env = close (testDbConn env)

runDbScript :: PgDB db -> DbMode -> DBScript db a -> TestDbEnv -> IO a
runDbScript db mode script env = runRIO env (withDb db mode script)

queryActs :: TestDbEnv -> IO [TestRow]
queryActs env =
    query_
        (testDbConn env)
        (Query "SELECT id, name, circus_id, description, audience_reaction FROM circus_acts ORDER BY id")

-- | Opens a fresh connection to the test database.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The returned connection is open, authenticated as
-- @lazy_circus_app@ against @lazy_circus_test@, and must be 'close'd by the
-- caller (typically via 'bracket'). Intended for multi-connection concurrency
-- tests that need an independent second/third connection to the same database
-- (e.g. holding a @FOR UPDATE@ row lock on one connection while a Lazy Circus
-- @findLocked@ / @findAllLocked@ read runs on another).
openTestConn :: IO Connection
openTestConn = connectPostgreSQL testConnectionString

recreateTestDatabase :: Connection -> IO ()
recreateTestDatabase conn = do
    terminateConnections conn
    void $ execute_ conn (Query "DROP DATABASE IF EXISTS lazy_circus_test")
    void $ execute_ conn (Query "CREATE DATABASE lazy_circus_test")

terminateConnections :: Connection -> IO ()
terminateConnections conn = do
    let killSessions =
            Query "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'lazy_circus_test' AND pid <> pg_backend_pid()"
    void (query_ conn killSessions :: IO [Only Bool])

retryConnect :: ByteString -> IO Connection
retryConnect connectionString = retrying 20 0.25
  where
    retrying :: Int -> NominalDiffTime -> IO Connection
    retrying attempts delaySeconds =
        connectPostgreSQL connectionString `catchAny` \err ->
            if attempts <= 1
                then throwIO err
                else do
                    threadDelay $ floor (delaySeconds * 1000000)
                    retrying (attempts - 1) delaySeconds

adminConnectionString :: ByteString
adminConnectionString = B.pack $ map (fromIntegral . fromEnum) "host=127.0.0.1 port=5432 user=postgres password=my_password dbname=postgres"

adminTestConnectionString :: ByteString
adminTestConnectionString = B.pack $ map (fromIntegral . fromEnum) "host=127.0.0.1 port=5432 user=postgres password=my_password dbname=lazy_circus_test"

testConnectionString :: ByteString
testConnectionString = B.pack $ map (fromIntegral . fromEnum) "host=127.0.0.1 port=5432 user=lazy_circus_app password=my_password dbname=lazy_circus_test"
