{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilyDependencies #-}

-- | Generic in-process service primitives shared by backend service runtimes.
--
-- PURPOSE: Provide request/response-channel based concurrency primitives
--   for building isolated in-process services with serialized access.
-- SCOPE: Pipe creation, worker loops, service handler lifecycle,
--   service-lib environment integration, and tool description types.
module LazyCircus.App.Service (
    Request,
    Response,
    Pipe,
    ServiceHandler (..),
    Service,
    HasFailbackValue (..),
    createPipe,
    worker,
    createService,
    callService,
    IsInServiceLib (..),
    HasServiceLib (..),
    NoServiceLib (..),
    callViaServiceLib,
    runAllWorkers,
    -- IsResponseFor (..),
    -- * Tool descriptions
    ToolDescription (..),
    HasToolDescriptions (..),
    ToolCallExec (..),
    HasToolCallExec (..),
)
where

import Data.Aeson (Value)
import RIO

-- | Request channel used to deliver one service input to the worker.
type Request a = MVar a

-- | Response channel used to deliver one worker result back to the caller.
type Response b = MVar b

-- | Pair of request and response channels owned by one service worker.
type Pipe a b = (Request a, Response b)

-- | Runtime handle that stores the channels and semaphore for a service worker.
data ServiceHandler a b = ServiceHandler
    { serviceHandlerPipe :: Pipe a b  -- ^ request and response channels for this worker
    , serviceHandlerSem  :: QSem      -- ^ binary semaphore serialising concurrent callers
    }

-- | Service constructor result that returns a handler together with its worker action.
type Service a b m = m (ServiceHandler a b, m ())

-- | Provide the fallback response returned when a worker action throws.
class HasFailbackValue a where
    failbackValue :: a

-- | Allocate a fresh request and response channel pair for one service worker.
-- POST-CONTRACT: Both channels in the returned Pipe are empty and ready for use.
createPipe :: (MonadIO m) => m (Pipe a b)
createPipe = do
    request <- newEmptyMVar
    response <- newEmptyMVar
    pure (request, response)

-- | Run the service loop by consuming requests, executing the handler, and posting either its result or a fallback response.
-- POST-CONTRACT: On handler exception the failback value is placed in the
--   response channel and the loop continues without crashing.
worker :: (MonadUnliftIO m, HasFailbackValue b) => (a -> m b) -> Pipe a b -> m ()
worker f pipe@(request, response) = do
    a <- takeMVar request
    result <- tryAny $ f a
    case result of
        Left _ -> do
            putMVar response $ failbackValue
        Right result ->
            putMVar response $ result
    worker f pipe

-- | Build a service handler together with the worker action that serves its request loop.
-- POST-CONTRACT: The returned worker action must be forked separately for the
--   service to become active; until then calls to 'callService' will block.
createService :: (MonadUnliftIO m, HasFailbackValue b) => (a -> m b) -> Service a b m
createService f = do
    pipe <- createPipe
    sem <- newQSem 1
    pure (ServiceHandler pipe sem, worker f pipe)

-- | Send one request through the handler and wait for the serialized response.
-- PRE-CONTRACT: The handler must be associated with a running worker thread.
-- POST-CONTRACT: The binary semaphore ensures at most one concurrent caller
--   per handler; the response corresponds to the request.
callService :: (MonadUnliftIO m) => ServiceHandler a b -> a -> m b
callService h a = do
    let (request, response) = serviceHandlerPipe h
        sem' = serviceHandlerSem h
    bracket_ (waitQSem sem') (signalQSem sem') $ do
        putMVar request a
        takeMVar response

-- class IsServiceLib serviceLib

-- type ServiceResponse serviceLib

-- | Dispatch a typed request through a service-lib environment to obtain a response.
class IsInServiceLib serviceLib request response where
    callFromServiceLib :: (MonadUnliftIO m) => serviceLib -> request -> m response

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