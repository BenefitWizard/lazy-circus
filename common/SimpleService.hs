{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- ^ Suppressed intentionally: SimpleRequest uses partial record fields
-- to enable Generic/ToSchema derivation for openapi3 schema generation.
-- All consumers use pattern matching, not record selectors.

-- | Simple service types, handlers, and TH-generated service library.
--
-- Defines request/response types, their handlers, and the service library
-- generated via 'makeServiceLib'. Tool specs are included to exercise the
-- full TH code generation path.
module SimpleService where

import Data.Aeson (FromJSON (..), ToJSON (..), withObject, (.:), (.=), object)
import Data.Char (toLower)
import Data.List (stripPrefix)
import Data.OpenApi.Internal.Schema (genericDeclareNamedSchema)
import Data.OpenApi.SchemaOptions (SchemaOptions (..), defaultSchemaOptions)
import Data.OpenApi.Schema (ToSchema (..))
import Data.Text (unpack)
import LazyCircus.App.Service
import RIO

-- -- Request and response types

-- | Simple arithmetic operations: addition and subtraction.
data SimpleRequest
    = Add { addX :: Int -- ^ left operand for addition
          , addY :: Int -- ^ right operand for addition
          }
    | Subtract { subX :: Int -- ^ left operand for subtraction
               , subY :: Int -- ^ right operand for subtraction
               }
    deriving (Show, Eq, Generic)

-- | Result of a simple arithmetic operation.
data SimpleResponse = SimpleResult
    { simpleResultValue :: Int -- ^ the computed integer result
    }
    deriving (Show, Eq, Generic)

-- | Request to process a text expression.
data AddExpressionRequest = AddExpressionRequest
    { addExpressionRequestExpression :: Text -- ^ the expression text to process
    }
    deriving (Show, Eq, Generic)

-- | Result of expression processing.
data AddExpressionResponse = AddExpressionResult
    { addExpressionResultValue :: Text -- ^ the processed expression text
    }
    deriving (Show, Eq, Generic)

-- -- ToSchema instances

-- | Strips constructor-specific prefix and lowercases the first character.
-- Maps "addX" → "x", "addY" → "y", "subX" → "x", "subY" → "y".
-- PRE-CONTRACT: Input must start with "add" or "sub" followed by an uppercase letter.
stripCtorPrefix :: String -> String
stripCtorPrefix s = case s of
    'a':'d':'d':c:cs -> toLower c : cs
    's':'u':'b':c:cs -> toLower c : cs
    _ -> error $ "stripCtorPrefix: unexpected field name " <> show s
                 <> ". Add a case for the new constructor prefix."

-- | Strips a type-name prefix from a record field label and lowercases the next character.
dropTypePrefix :: String -> String -> String
dropTypePrefix prefix s = case stripPrefix prefix s of
    Just (c:cs) -> toLower c : cs
    Just [] -> []
    Nothing -> s

-- | Uses generic derivation with custom field label modifier to match 'FromJSON' field names
-- and lowercase constructor tags to match the discriminator values.
instance ToSchema SimpleRequest where
    declareNamedSchema = genericDeclareNamedSchema defaultSchemaOptions
        { fieldLabelModifier = stripCtorPrefix
        , constructorTagModifier = map toLower
        }

-- | Default generic ToSchema for SimpleResponse.
instance ToSchema SimpleResponse

-- | Uses generic derivation with custom field label modifier to strip the type name prefix.
instance ToSchema AddExpressionRequest where
    declareNamedSchema = genericDeclareNamedSchema defaultSchemaOptions
        { fieldLabelModifier = dropTypePrefix "addExpressionRequest"
        }

-- | Default generic ToSchema for AddExpressionResponse.
instance ToSchema AddExpressionResponse

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

-- | Processes a simple arithmetic request.
handleSimpleRequest :: SimpleRequest -> IO SimpleResponse
handleSimpleRequest req =
    case req of
        Add{addX, addY} -> pure $ SimpleResult (addX + addY)
        Subtract{subX, subY} -> pure $ SimpleResult (subX - subY)

-- | Processes an expression request by appending "!".
handleAddExpressionRequest :: AddExpressionRequest -> IO AddExpressionResponse
handleAddExpressionRequest AddExpressionRequest{addExpressionRequestExpression} =
    pure $ AddExpressionResult (addExpressionRequestExpression <> "!")

-- -- Failback values

-- | Neutral failback value for SimpleResponse.
instance HasFailbackValue SimpleResponse where
    failbackValue = SimpleResult 0

-- | Neutral failback value for AddExpressionResponse.
instance HasFailbackValue AddExpressionResponse where
    failbackValue = AddExpressionResult ""
