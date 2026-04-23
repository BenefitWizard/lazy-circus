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

data AddExpressionResponse = AddExpressionResult Int
    deriving (Show, Eq)

data AllServices = AllServices
    { addService :: ServiceHandler SimpleRequest SimpleResponse
    , addExpressionService :: ServiceHandler AddExpressionRequest AddExpressionResponse
    }

data AllServiceHandlers
    = SimpleServiceHandler (ServiceHandler SimpleRequest SimpleResponse)
    | AddExpressionServiceHandler (ServiceHandler AddExpressionRequest AddExpressionResponse)

instance IsServiceLib AllServices where
    type ServiceResponse AllServices = AllResponses

instance IsInServiceLib AllServices SimpleRequest where
    callFromServiceLib allServices request =
        case request of
            Add x y -> SimpleResponseWrapper <$> callService (addService allServices) (Add x y)
            Subtract x y -> SimpleResponseWrapper <$> callService (addService allServices) (Subtract x y)

data AllResponses
    = SimpleResponseWrapper SimpleResponse
    | AddExpressionResponseWrapper AddExpressionResponse
