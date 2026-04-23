{-# LANGUAGE TemplateHaskell #-}

module SimpleService where

import LazyCircus.App.Service
import LazyCircus.App.Service.TH (makeServiceLib)
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

makeServiceLib "AllServices"
    [ (''SimpleRequest, ''SimpleResponse)
    , (''AddExpressionRequest, ''AddExpressionResponse)
    ]
