{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilyDependencies #-}

-- | Generic in-process service primitives shared by backend service runtimes.
--
-- PURPOSE: Provide mailbox-based concurrency primitives for building isolated
--   in-process services with serialized access in the style of Erlang gen_server:
--   synchronous calls ('callService') and fire-and-forget casts ('castService')
--   share one FIFO mailbox served by a single worker loop.
-- SCOPE: Mailbox creation, worker loops, service handler lifecycle,
--   service-lib environment integration, and tool description types.
module LazyCircus.App.Service (
    Envelope (..),
    ServiceHandler (..),
    Service,
    HasFailbackValue (..),
    createMailbox,
    worker,
    createService,
    createServiceWithCast,
    callService,
    castService,
    IsInServiceLib (..),
    HasServiceLib (..),
    NoServiceLib (..),
    callViaServiceLib,
    castViaServiceLib,
    runAllWorkers,
    -- IsResponseFor (..),
    -- * Tool descriptions
    ToolDescription (..),
    hideSchemaParams,
    hideToolParams,
    HasToolDescriptions (..),
    ToolCallExec (..),
    HasToolCallExec (..),
)
where

import Data.Aeson (Value (Array, Object, String))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import RIO
import qualified RIO.Vector as V

-- | One message in a service mailbox, in the style of an Erlang gen_server: a
--   synchronous call carrying its reply channel, or a fire-and-forget cast.
data Envelope request response
    = CallMsg request (TMVar response) -- ^ synchronous call; the worker posts the handler result or the failback value into the channel
    | CastMsg request -- ^ fire-and-forget; the worker discards the result and swallows handler exceptions

-- | Runtime handle that stores the mailbox consumed by a service worker.
data ServiceHandler a b = ServiceHandler
    { serviceHandlerMailbox :: TQueue (Envelope a b)  -- ^ mailbox shared by all callers; messages are served FIFO by one worker
    }

-- | Service constructor result that returns a handler together with its worker action.
type Service a b m = m (ServiceHandler a b, m ())

-- | Provide the fallback response returned when a worker action throws.
class HasFailbackValue a where
    failbackValue :: a

-- | Allocate a fresh empty mailbox for one service worker.
-- POST-CONTRACT: The returned mailbox is empty and ready for use.
createMailbox :: (MonadIO m) => m (TQueue (Envelope a b))
createMailbox = newTQueueIO

-- | Run the service loop by consuming envelopes from the mailbox: casts go to
--   the cast handler, calls go to the call handler whose result is posted into
--   the caller's reply channel.
-- PRE-CONTRACT: The loop must be forked in its own thread (e.g. via 'runAllWorkers').
-- POST-CONTRACT: The loop survives any synchronous handler exception: a failed
--   cast is swallowed silently, a failed call posts 'failbackValue'; messages
--   are processed FIFO in arrival order.
worker ::
    (MonadUnliftIO m, HasFailbackValue b) =>
    (a -> m ()) ->
    (a -> m b) ->
    TQueue (Envelope a b) ->
    m ()
worker castF callF mailbox = do
    envelope <- atomically $ readTQueue mailbox
    case envelope of
        CastMsg a -> do
            _ <- tryAny $ castF a
            pure ()
        CallMsg a reply -> do
            result <- tryAny $ callF a
            case result of
                Left _ -> atomically $ putTMVar reply failbackValue
                Right b -> atomically $ putTMVar reply b
    worker castF callF mailbox

-- | Build a service handler whose casts run the same handler as calls, with the
--   result discarded. Use 'createServiceWithCast' when casts need distinct logic.
-- POST-CONTRACT: The returned worker action must be forked separately for the
--   service to become active; until then 'callService' blocks and 'castService'
--   silently accumulates messages in the mailbox.
createService :: (MonadUnliftIO m, HasFailbackValue b) => (a -> m b) -> Service a b m
createService f = createServiceWithCast (void . f) f

-- | Build a service handler with separate handlers for casts and calls.
-- POST-CONTRACT: The returned worker action must be forked separately for the
--   service to become active; until then 'callService' blocks and 'castService'
--   silently accumulates messages in the mailbox.
createServiceWithCast ::
    (MonadUnliftIO m, HasFailbackValue b) =>
    (a -> m ()) ->
    (a -> m b) ->
    Service a b m
createServiceWithCast castF callF = do
    mailbox <- createMailbox
    pure (ServiceHandler mailbox, worker castF callF mailbox)

-- | Send one request through the handler and wait for the serialized response.
-- PRE-CONTRACT: The handler must be associated with a running worker thread.
-- POST-CONTRACT: The response corresponds to this request; the call blocks
--   behind earlier mailbox messages (calls and casts) in FIFO order.
callService :: (MonadIO m) => ServiceHandler a b -> a -> m b
callService h a = do
    reply <- newEmptyTMVarIO
    atomically $ writeTQueue (serviceHandlerMailbox h) (CallMsg a reply)
    atomically $ readTMVar reply

-- | Send one fire-and-forget request to the worker and return immediately.
-- PRE-CONTRACT: The handler must be associated with a running worker thread.
-- POST-CONTRACT: Returns before the handler runs; the request is processed FIFO
--   after all earlier mailbox messages; a handler exception is swallowed and
--   never reported to the caller; delivery is not guaranteed (e.g. if the
--   worker thread died, the message is silently dropped).
castService :: (MonadIO m) => ServiceHandler a b -> a -> m ()
castService h a = atomically $ writeTQueue (serviceHandlerMailbox h) (CastMsg a)

-- class IsServiceLib serviceLib

-- type ServiceResponse serviceLib

-- | Dispatch a typed request through a service-lib environment to obtain a response.
-- The functional dependency states that a request type maps to exactly one
-- response type per service library — the request determines the reply, as in
-- an Erlang gen_server.
class IsInServiceLib serviceLib request response | serviceLib request -> response where
    callFromServiceLib :: (MonadUnliftIO m) => serviceLib -> request -> m response

    -- | Fire-and-forget dispatch of a typed request through a service-lib environment.
    -- Default delegates to 'callFromServiceLib' and blocks until the response
    -- arrives — override it with 'castService' when true async behavior is needed.
    castFromServiceLib :: (MonadUnliftIO m) => serviceLib -> request -> m ()
    castFromServiceLib serviceLib request = void $ callFromServiceLib serviceLib request

-- class IsResponseFor request response | response -> request

-- | Environment capability that provides access to a service-lib value
--   via a lens, used by 'callViaServiceLib'.
class HasServiceLib env serviceLib | env -> serviceLib where
    serviceLibL :: Lens' env serviceLib

-- | Sentinel type indicating that an environment has no service-lib attached.
data NoServiceLib = NoServiceLib

-- type ServiceResponse NoServiceLib = ()

-- | Retrieve the service-lib from the reader environment and dispatch the request.
-- PRE-CONTRACT: The environment must satisfy 'HasServiceLib' for the inferred
--   serviceLib type, and that serviceLib must satisfy 'IsInServiceLib' for
--   the given request and response types.
callViaServiceLib ::
    ( MonadUnliftIO m
    , IsInServiceLib serviceLib request response
    , HasServiceLib env serviceLib
    , -- , IsResponseFor request response
      MonadReader env m
    ) =>
    request -> m response
callViaServiceLib req = do
    serviceLib <- view serviceLibL
    callFromServiceLib serviceLib req

-- | Retrieve the service-lib from the reader environment and fire-and-forget
--   the request through it.
-- PRE-CONTRACT: The environment must satisfy 'HasServiceLib' for the inferred
--   serviceLib type, and that serviceLib must satisfy 'IsInServiceLib' for
--   the given request and response types.
-- POST-CONTRACT: Returns before the request is handled, unless the instance
--   relies on the blocking default of 'castFromServiceLib'.
castViaServiceLib ::
    ( MonadUnliftIO m
    , IsInServiceLib serviceLib request response
    , HasServiceLib env serviceLib
    , MonadReader env m
    ) =>
    request -> m ()
castViaServiceLib req = do
    serviceLib <- view serviceLibL
    castFromServiceLib serviceLib req

-- | Fork all worker actions as concurrent threads and return their handles.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: All workers are running asynchronously; caller is responsible
--   for cleanup (e.g., 'mapM_ cancel' or 'mapM_ wait').
runAllWorkers :: (MonadUnliftIO m) => [m ()] -> m [Async ()]
runAllWorkers = mapM async

-- | Description of a single tool that can be offered to an AI model.
-- Used by TH-generated code to build tool lists and by the performer
-- to thread tool descriptions into the AI runtime environment.
data ToolDescription = ToolDescription
    { toolDescName        :: Text        -- ^ machine-readable tool identifier used in JSON dispatch
    , toolDescDescription :: Text        -- ^ human-readable description of what the tool does
    , toolDescParameters  :: Maybe Value -- ^ JSON Schema describing the tool's input parameters
    }
    deriving (Show, Eq)

-- | Removes the given parameter keys from a tool's JSON Schema.
-- PRE-CONTRACT: Names are JSON keys as they appear after any fieldLabelModifier.
-- POST-CONTRACT: Absent keys are a no-op; a non-Object schema is returned
--   unchanged; a @required@ field that is missing or not a real JSON array is
--   left untouched (sum-type schemas use @oneOf@ instead of @required@).
hideSchemaParams :: [Text] -> Value -> Value
hideSchemaParams names schema = case schema of
    Object km -> Object $ hideRequired $ hidePropertiesEntry km
    _ -> schema
  where
    keys = map Key.fromText names

    -- | Drops hidden keys from the @properties@ sub-object; leaves a
    --   missing or non-Object @properties@ untouched.
    hidePropertiesEntry km = case KM.lookup "properties" km of
        Just (Object pm) -> KM.insert "properties" (Object $ KM.filterWithKey (\k _ -> k `notElem` keys) pm) km
        _ -> km

    -- | Drops hidden keys from @required@ only when it is a real JSON array.
    hideRequired km = case KM.lookup "required" km of
        Just (Array reqs) -> KM.insert "required" (Array $ V.filter keepParam reqs) km
        _ -> km

    -- | Keeps required entries whose text is not one of the hidden names
    keepParam (String t) = Key.fromText t `notElem` keys
    keepParam _ = True

-- | Applies 'hideSchemaParams' to a tool description's parameter schema.
-- POST-CONTRACT: A tool without parameters ('toolDescParameters' = 'Nothing') stays 'Nothing'.
hideToolParams :: [Text] -> ToolDescription -> ToolDescription
hideToolParams names tool = tool
    { toolDescParameters = hideSchemaParams names <$> toolDescParameters tool
    }

-- | Environment capability that exposes the list of available tool descriptions
-- to the AI interpreter.
class HasToolDescriptions env where
    toolDescriptionsL :: Lens' env [ToolDescription]

-- | Closure that dispatches a named tool call with JSON arguments.
newtype ToolCallExec = ToolCallExec
    { runToolCallExec :: Text -> Value -> IO Value
    }

-- | Environment capability for tool execution.
class HasToolCallExec env where
    toolCallExecL :: Lens' env ToolCallExec