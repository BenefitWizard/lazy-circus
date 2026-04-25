{-# LANGUAGE TemplateHaskell #-}

-- | Simple service types, handlers, and TH-generated service library.
--
-- Defines request/response types, their handlers, and the service library
-- generated via 'makeServiceLib'. Tool specs are included to exercise the
-- full TH code generation path.
module SimpleService where

import Data.Aeson (FromJSON (..), ToJSON (..), withObject, (.:), (.=), object)
import Data.Text (unpack)
import LazyCircus.App.Service
import RIO

-- -- Request and response types

data SimpleRequest
    = Add Int Int
    | Subtract Int Int
    deriving (Show, Eq)

data SimpleResponse = SimpleResult Int
    deriving (Show, Eq)

data AddExpressionRequest = AddExpressionRequest Text
    deriving (Show, Eq)

data AddExpressionResponse = AddExpressionResult Text
    deriving (Show, Eq)

-- -- Aeson instances (required by TH-generated FromJSON/ToJSON constraints when tool specs are present)

instance FromJSON SimpleRequest where
    parseJSON = withObject "SimpleRequest" $ \o -> do
        tag <- o .: "tag"
        case tag of
            "add"      -> Add <$> o .: "x" <*> o .: "y"
            "subtract" -> Subtract <$> o .: "x" <*> o .: "y"
            _          -> fail $ "Unknown SimpleRequest tag: " <> unpack tag

instance ToJSON SimpleResponse where
    toJSON (SimpleResult n) = object ["result" .= n]

instance FromJSON AddExpressionRequest where
    parseJSON = withObject "AddExpressionRequest" $ \o ->
        AddExpressionRequest <$> o .: "expression"

instance ToJSON AddExpressionResponse where
    toJSON (AddExpressionResult t) = object ["result" .= t]

-- -- Handlers

handleSimpleRequest :: SimpleRequest -> IO SimpleResponse
handleSimpleRequest req =
    case req of
        Add x y -> pure $ SimpleResult (x + y)
        Subtract x y -> pure $ SimpleResult (x - y)

handleAddExpressionRequest :: AddExpressionRequest -> IO AddExpressionResponse
handleAddExpressionRequest (AddExpressionRequest expr) =
    pure $ AddExpressionResult (expr <> "!")

-- -- Failback values

-- | Neutral failback value for SimpleResponse.
instance HasFailbackValue SimpleResponse where
    failbackValue = SimpleResult 0

-- | Neutral failback value for AddExpressionResponse.
instance HasFailbackValue AddExpressionResponse where
    failbackValue = AddExpressionResult ""
