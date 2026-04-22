module LazyCircus.App.Log where

import GHC.Stack (CallStack, getCallStack, srcLocModule, srcLocStartLine)
import RIO
import RIO.Map qualified as M
import RIO.Text hiding (foldl')

-- | Structured key-value logging metadata accumulated alongside application messages.
newtype LoggingContext = LogContext (Map Text Text) deriving (Semigroup, Monoid)

-- | Environment capability that provides access to the current logging context.
class HasLoggingContext env where
    logContextL :: Lens' env LoggingContext

-- | Add key-value pairs to an existing logging context, preferring the new values.
putInLoggingContext :: LoggingContext -> [(Text, Text)] -> LoggingContext
putInLoggingContext lc values = LogContext (M.fromList values) <> lc

-- | Keep only the selected keys from a logging context.
getFromLoggingContext :: LoggingContext -> [Text] -> LoggingContext
getFromLoggingContext (LogContext st) keys = LogContext (M.filterWithKey (\k _v -> k `elem` keys) st)

instance Display LoggingContext where
    display (LogContext lc) =
        foldl'
            (\acc (k, v) -> acc <> display k <> "=" <> display v <> " ")
            mempty
            (M.toList lc)

-- | Source location metadata extracted from a call stack for structured logging.
data CallSite = CallSite
    { csModule :: !Text
    , csLine :: !Int
    }
    deriving (Eq, Show)

-- | Extract the first call site from a GHC call stack, if available.
extractCallSite :: CallStack -> Maybe CallSite
extractCallSite cs = do
    (_, loc) <- listToMaybe $ getCallStack cs
    pure $
        CallSite
            { csModule = pack $ srcLocModule loc
            , csLine = srcLocStartLine loc
            }

type LogQueue = TQueue AppLogMsgWithContext

-- | Log payload variants with different sensitivity and severity levels.
data AppLogMsg
    = AppLogMsg !Text
    | SensitiveLogMsg !Text
    | ErrorLogMsg !Text
    | WarnLogMsg !Text

-- | Logged message paired with the structured context and call site captured at emission time.
data AppLogMsgWithContext = AppLogMsgWithContext
    { logMsg :: AppLogMsg
    , logContext :: LoggingContext
    , logCallSite :: Maybe CallSite
    }

instance HasLogLevel AppLogMsgWithContext where
    getLogLevel (AppLogMsgWithContext msg _ _) = getLogLevel msg

instance HasLogSource AppLogMsgWithContext where
    getLogSource (AppLogMsgWithContext msg _ _) = getLogSource msg

instance Display AppLogMsgWithContext where
    display (AppLogMsgWithContext msg ctx mCallSite) =
        formatCallSite mCallSite <> display msg <> " | " <> display ctx
      where
        formatCallSite Nothing = mempty
        formatCallSite (Just cs) = display (csModule cs) <> ":" <> display (csLine cs) <> " | "

instance HasLogLevel AppLogMsg where
    getLogLevel (AppLogMsg _) = LevelInfo
    getLogLevel (SensitiveLogMsg _) = LevelDebug
    getLogLevel (ErrorLogMsg _) = LevelError
    getLogLevel (WarnLogMsg _) = LevelWarn

instance HasLogSource AppLogMsg where
    getLogSource (AppLogMsg _) = "App"
    getLogSource (SensitiveLogMsg _) = "AppSecret"
    getLogSource (ErrorLogMsg _) = "App"
    getLogSource (WarnLogMsg _) = "App"

instance Display AppLogMsg where
    display (AppLogMsg msg) = display msg
    display (SensitiveLogMsg msg) = display msg
    display (ErrorLogMsg msg) = display msg
    display (WarnLogMsg msg) = display msg

-- | Minimal runtime environment required to drain queued application log messages.
data LogApp = LogApp
    { logFunc :: LogFunc
    , genLogFunc :: GLogFunc AppLogMsgWithContext
    , logQueue :: LogQueue
    }

-- | Environment capability that exposes the shared application log queue.
class HasLogQueue env where
    logQueueL :: Lens' env (TQueue AppLogMsgWithContext)

instance HasLogFunc LogApp where
    logFuncL = lens logFunc (\x y -> x{logFunc = y})

instance HasGLogFunc LogApp where
    type GMsg LogApp = AppLogMsgWithContext
    gLogFuncL = lens genLogFunc (\x y -> x{genLogFunc = y})

instance HasLogQueue LogApp where
    logQueueL = lens logQueue (\x y -> x{logQueue = y})

-- | Continuously drain the log queue and emit each contextualized message through the generic logger.
logWorker :: RIO LogApp ()
logWorker = do
    logQueue <- view logQueueL
    forever $ do
        msg <- atomically $ readTQueue logQueue
        glog msg

{- | Emit a log message from a sub-language interpreter, automatically capturing call site and context.
This is the shared implementation used by all sub-language log handlers.
-}
sublangLog ::
    (HasLogQueue env, HasLoggingContext env, MonadReader env m, MonadIO m) =>
    CallStack ->
    Text ->
    AppLogMsg ->
    m ()
sublangLog cs langTag msg = do
    q <- view logQueueL
    logCtx <- view logContextL
    let callSite = extractCallSite cs
        enrichedCtx = putInLoggingContext logCtx [("lang", langTag)]
        contextualMsg = AppLogMsgWithContext msg enrichedCtx callSite
    atomically $ writeTQueue q contextualMsg
