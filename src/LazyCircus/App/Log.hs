module LazyCircus.App.Log where

import Data.List qualified as List
import GHC.Stack (CallStack, getCallStack, srcLocModule, srcLocStartLine)
import RIO
import RIO.Map qualified as M
import RIO.Text hiding (foldl')
import RIO.Time (UTCTime, getCurrentTime, formatTime, defaultTimeLocale)

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
    | NoticeLogMsg !Text
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
    getLogLevel (NoticeLogMsg _) = LevelDebug
    getLogLevel (ErrorLogMsg _) = LevelError
    getLogLevel (WarnLogMsg _) = LevelWarn

instance HasLogSource AppLogMsg where
    getLogSource (AppLogMsg _) = "App"
    getLogSource (SensitiveLogMsg _) = "AppSecret"
    getLogSource (NoticeLogMsg _) = "App"
    getLogSource (ErrorLogMsg _) = "App"
    getLogSource (WarnLogMsg _) = "App"

instance Display AppLogMsg where
    display (AppLogMsg msg) = display msg
    display (SensitiveLogMsg msg) = display msg
    display (NoticeLogMsg msg) = display msg
    display (ErrorLogMsg msg) = display msg
    display (WarnLogMsg msg) = display msg

-- | Minimal runtime environment required to drain queued application log messages.
data LogApp = LogApp
    { logFunc :: LogFunc
    , genLogFunc :: GLogFunc AppLogMsgWithContext
    , logQueue :: LogQueue
    , logProfile :: LogProfile
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

{- | Environment capability that exposes the active log visibility profile.
POST-CONTRACT: 'logWorker' consults 'logProfileL' once per drained message;
  changing the lens target affects only messages drained afterwards.
-}
class HasLogProfile env where
    logProfileL :: Lens' env LogProfile

instance HasLogProfile LogApp where
    logProfileL = lens logProfile (\x y -> x{logProfile = y})

{- | Continuously drain the log queue and emit each contextualized message through the generic logger.
PRE-CONTRACT: runs forever; terminate it by cancelling the worker thread.
POST-CONTRACT: every queued message is removed from the queue; only messages
  accepted by 'shouldRender' under the profile from 'logProfileL' reach the
  generic logger — filtered messages are silently dropped.
-}
logWorker :: RIO LogApp ()
logWorker = do
    logQueue <- view logQueueL
    forever $ do
        msg <- atomically $ readTQueue logQueue
        profile <- view logProfileL
        when (shouldRender profile msg) $ glog msg

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

-- | Visibility profile controlling which severities reach the rendered log.
data LogProfile
    = LogDev  -- ^ development: render every message, including sensitive ones
    | LogProd -- ^ production: drop @LevelDebug@ messages (sensitive and notice diagnostics)
    deriving (Eq, Show)

-- | Decide whether a message passes the profile's visibility filter.
-- POST-CONTRACT: @LogDev@ accepts every message; @LogProd@ accepts only
--   messages of 'LevelInfo' severity or higher.
shouldRender :: LogProfile -> AppLogMsgWithContext -> Bool
shouldRender LogDev _ = True
shouldRender LogProd msg = getLogLevel msg >= LevelInfo

-- | Render one complete log line: ISO-8601 UTC timestamp, bracketed level
-- tag, call site (@module:line@), message text, and structured context as
-- @k=v@ pairs.
-- POST-CONTRACT: the result contains no newline; the trailing
--   @\" | k=v ...\"@ segment is omitted when the context is empty.
renderLogLine :: UTCTime -> AppLogMsgWithContext -> Utf8Builder
renderLogLine now msg =
    renderTimestamp now
        <> " ["
        <> msgTag payload
        <> "] "
        <> maybe mempty renderCallSite (logCallSite msg)
        <> display payload
        <> renderContext (logContext msg)
  where
    payload = logMsg msg

    -- | Renders a call site as @module:line@ followed by its separating pipe.
    renderCallSite cs = display (csModule cs) <> ":" <> display (csLine cs) <> " | "

    -- | Renders context pairs space-separated; an empty context renders as 'mempty'.
    renderContext (LogContext pairs)
        | M.null pairs = mempty
        | otherwise =
            " | "
                <> mconcat
                    (List.intersperse " " [display k <> "=" <> display v | (k, v) <- M.toList pairs])

    -- | Bracketed severity tag for a log payload variant.
    msgTag AppLogMsg{} = "INFO"
    msgTag WarnLogMsg{} = "WARN"
    msgTag ErrorLogMsg{} = "ERROR"
    msgTag SensitiveLogMsg{} = "SENSITIVE"
    msgTag NoticeLogMsg{} = "NOTICE"

-- | RIO log function printing @[LEVEL] ISO-8601 message@ lines to stdout.
-- POST-CONTRACT: every logged entry is a single line terminated by a newline;
--   the timestamp format matches 'renderTimestamp'.
timestampedLogFunc :: LogFunc
timestampedLogFunc = mkLogFunc $ \_cs _src level msg -> do
    now <- getCurrentTime
    hPutBuilder stdout $ getUtf8Builder $
        "[" <> levelTag level <> "] " <> renderTimestamp now <> " " <> msg <> "\n"
  where
    -- | Render a RIO log level as a bracketed tag.
    levelTag LevelDebug = "DEBUG"
    levelTag LevelInfo = "INFO"
    levelTag LevelWarn = "WARN"
    levelTag LevelError = "ERROR"
    levelTag (LevelOther t) = display t

-- | Render a UTC timestamp as ISO-8601 with second precision.
renderTimestamp :: UTCTime -> Utf8Builder
renderTimestamp = fromString . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
