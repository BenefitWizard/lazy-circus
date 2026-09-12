{-# LANGUAGE OverloadedStrings #-}

-- | A database-free 'DefaultApp' fixture shared by the BDD test suites.
--
-- The pool create action is 'fail', so any accidental checkout throws instead
-- of connecting: the app can be built and used while PostgreSQL is stopped.
-- 'newDefaultApp' cannot be used for such fixtures — it probes its pool
-- (and therefore the database) EAGERLY at construction.
module TestSupport.DbFreeApp
    ( mkDbFreeApp
    ) where

import Crypto.JOSE (KeyMaterialGenParam (OctGenParam), genJWK)
import Data.Pool (defaultPoolConfig, newPool)
import Database.PostgreSQL.Simple (close)
import LazyCircus.App.Default (DefaultApp (..), MailCreds (..))
import LazyCircus.App.Service (NoServiceLib (..), ToolCallExec (..))
import LazyCircus.AsyncWorker.Types (TimedActions (..))
import LazyCircus.Telegram (makeBotEnv)
import Network.HTTP.Client.TLS (newTlsManager)
import OpenAI.V1 (getClientEnv, makeMethods)
import RIO
import RIO.HashMap qualified as HM
import RIO.Map qualified as M
import RIO.Process (mkDefaultProcessContext)
import Servant.Auth.Server (defaultJWTSettings)
import Telegram.Bot.API (Token (..))

{- | Build a 'DefaultApp' that never contacts PostgreSQL: the pool create
action is 'fail', so any accidental checkout throws instead of connecting.
One bot named @botName@ is registered so @tgScript botName@ resolves;
building its bot environment performs no network I/O, and Mocked Telegram
mode never touches it.
POST-CONTRACT: the caller owns pool teardown via @destroyAllResources (pgDbPool app)@
if the pool was replaced with a live one; for this fixture the pool never
allocates, so teardown is a no-op.
-}
mkDbFreeApp :: Text -> IO (DefaultApp NoServiceLib)
mkDbFreeApp botName = do
    pgPool <-
        newPool
            ( defaultPoolConfig
                (fail "TestSupport.DbFreeApp: the DB pool must never be checked out")
                close
                30
                1
            )
    logQueueVal <- newTQueueIO
    asyncTasksVal <- newTQueueIO
    timedEntriesVar <- newTVarIO []
    timedNextSeqVar <- newTVarIO 0
    let timedTasksVal = TimedActions {timedActionsEntries = timedEntriesVar, timedActionsNextSeq = timedNextSeqVar}
    manager <- newTlsManager
    jwk <- genJWK (OctGenParam 256)
    processCtx <- mkDefaultProcessContext
    aiEnv <- getClientEnv "http://127.0.0.1:1"
    botEnv <- makeBotEnv manager (Token "123456:test-token", botName)
    pure App
        { logFunc = mkLogFunc (\_ _ _ _ -> pure ())
        , genLogFunc = mkGLogFunc (\_ _ -> pure ())
        , pgDbPool = pgPool
        , pgDbPoolReadOnly = Nothing
        , appProcessContext = processCtx
        , botEnvs = M.singleton botName botEnv
        , jwtSettings = defaultJWTSettings jwk
        , logQueue = logQueueVal
        , extraContext = HM.empty
        , logContext = mempty
        , mailCreds =
            MailCreds
                { mailHost = "localhost"
                , mailPort = 2525
                , mailLogin = ""
                , mailPassword = ""
                , mailName = "dbfree"
                , mailUseTls = False
                }
        , asyncTasks = asyncTasksVal
        , timedTasks = timedTasksVal
        , aiMethods = makeMethods aiEnv "not-configured" Nothing Nothing
        , sqlLogAction = \_ -> pure ()
        , serviceLib = NoServiceLib
        , appToolDescriptions = []
        , toolCallExec = ToolCallExec (\_ _ -> fail "TestSupport.DbFreeApp: no tool execution")
        , httpManager = manager
        }
