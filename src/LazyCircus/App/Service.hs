{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilyDependencies #-}

-- | Generic in-process service primitives shared by backend service runtimes.
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
)
where

import RIO

-- | Request channel used to deliver one service input to the worker.
type Request a = MVar a

-- | Response channel used to deliver one worker result back to the caller.
type Response b = MVar b

-- | Pair of request and response channels owned by one service worker.
type Pipe a b = (Request a, Response b)

-- | Runtime handle that stores the channels and semaphore for a service worker.
data ServiceHandler a b = ServiceHandler
    { pipe :: Pipe a b
    , sem :: QSem
    }

-- | Service constructor result that returns a handler together with its worker action.
type Service a b m = m (ServiceHandler a b, m ())

-- | Provide the fallback response returned when a worker action throws.
class HasFailbackValue a where
    failbackValue :: a

-- | Allocate a fresh request and response channel pair for one service worker.
createPipe :: (MonadIO m) => m (Pipe a b)
createPipe = do
    request <- newEmptyMVar
    response <- newEmptyMVar
    pure (request, response)

-- | Run the service loop by consuming requests, executing the handler, and posting either its result or a fallback response.
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
createService :: (MonadUnliftIO m, HasFailbackValue b) => (a -> m b) -> Service a b m
createService f = do
    pipe <- createPipe
    sem <- newQSem 1
    pure (ServiceHandler pipe sem, worker f pipe)

-- | Send one request through the handler and wait for the serialized response.
callService :: (MonadUnliftIO m) => ServiceHandler a b -> a -> m b
callService h a = do
    let (request, response) = pipe h
        sem' = sem h
    bracket_ (waitQSem sem') (signalQSem sem') $ do
        putMVar request a
        takeMVar response

-- class IsServiceLib serviceLib

-- type ServiceResponse serviceLib

class IsInServiceLib serviceLib request response where
    callFromServiceLib :: (MonadUnliftIO m) => serviceLib -> request -> m response

-- class IsResponseFor request response | response -> request

class HasServiceLib env serviceLib | env -> serviceLib where
    serviceLibL :: Lens' env serviceLib

data NoServiceLib = NoServiceLib

-- type ServiceResponse NoServiceLib = ()

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