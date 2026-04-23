module SimpleService where

import LazyCircus.App.Service
import RIO

data SimpleRequest
    = Add Int Int
    | Subtract Int Int

data SimpleResponse = SimpleResult Int
    deriving (Show, Eq)

data AddExpressionRequest = AddExpressionRequest Text
    deriving (Show, Eq)

data AddExpressionResponse = AddExpressionResult Text
    deriving (Show, Eq)

data AllServices = AllServices
    { addService :: ServiceHandler SimpleRequest SimpleResponse
    , addExpressionService :: ServiceHandler AddExpressionRequest AddExpressionResponse
    }

data AllServiceHandlers
    = SimpleServiceHandler (ServiceHandler SimpleRequest SimpleResponse)
    | AddExpressionServiceHandler (ServiceHandler AddExpressionRequest AddExpressionResponse)

-- instance IsServiceLib AllServices

instance IsInServiceLib AllServices SimpleRequest SimpleResponse where
    callFromServiceLib allServices request =
        case request of
            Add x y -> callService (addService allServices) (Add x y)
            Subtract x y -> callService (addService allServices) (Subtract x y)

-- | Sum type wrapping all possible service responses for AllServices.
data AllResponses
    = SimpleResponseWrapper SimpleResponse
    | AddExpressionResponseWrapper AddExpressionResponse
    deriving (Show, Eq)

handleSimpleRequest :: SimpleRequest -> IO SimpleResponse
handleSimpleRequest req =
    case req of
        Add x y -> pure $ SimpleResult (x + y)
        Subtract x y -> pure $ SimpleResult (x - y)

handleAddExpressionRequest :: AddExpressionRequest -> IO AddExpressionResponse
handleAddExpressionRequest (AddExpressionRequest expr) =
    pure $ AddExpressionResult (expr <> "!") -- Placeholder implementation

-- | Neutral failback value for SimpleResponse, used when a worker encounters an error.
instance HasFailbackValue SimpleResponse where
    failbackValue = SimpleResult 0

-- | Neutral failback value for AddExpressionResponse, used when a worker encounters an error.
instance HasFailbackValue AddExpressionResponse where
    failbackValue = AddExpressionResult ""

-- | Delegates AddExpressionRequest to the addExpressionService and wraps the result.
instance IsInServiceLib AllServices AddExpressionRequest AddExpressionResponse where
    callFromServiceLib allServices = callService (addExpressionService allServices)