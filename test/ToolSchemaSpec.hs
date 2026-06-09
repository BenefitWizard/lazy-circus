{-# LANGUAGE OverloadedStrings #-}

-- | Structural tests for toolSchema-generated JSON Schemas.
--
-- Validates that 'toolSchema' returns 'Just' for every tool and that
-- the resulting schemas contain the expected field names derived from
-- the custom 'ToSchema' instances in "SimpleService".
module ToolSchemaSpec (spec) where

import Data.Aeson.Text (encodeToLazyText)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import qualified Data.Text.Lazy as TL
import SimpleServiceLib
    ( AllServicesTool (..)
    , toolSchema
    )
import Test.Hspec

-- | Extracts the JSON string from a 'toolSchema' result, or fails with the given label.
schemaJson :: HasCallStack => String -> AllServicesTool -> String
schemaJson label tool = case toolSchema tool of
    Nothing -> error $ label <> ": toolSchema returned Nothing"
    Just schema -> TL.unpack (encodeToLazyText schema)

spec :: Spec
spec = describe "toolSchema" $ do
    it "AddTool returns Just (not Nothing)" $ do
        toolSchema AddTool `shouldSatisfy` isJust

    it "SubtractTool returns Just (not Nothing)" $ do
        toolSchema SubtractTool `shouldSatisfy` isJust

    it "AddExpressionRequestTool returns Just (not Nothing)" $ do
        toolSchema AddExpressionRequestTool `shouldSatisfy` isJust

    it "AddTool and SubtractTool return identical schemas (same request type)" $ do
        toolSchema AddTool `shouldBe` toolSchema SubtractTool

    it "AddTool schema contains field 'x'" $ do
        let jsonStr = schemaJson "AddTool" AddTool
        jsonStr `shouldSatisfy` ("\"x\"" `isInfixOf`)

    it "AddTool schema contains field 'y'" $ do
        let jsonStr = schemaJson "AddTool" AddTool
        jsonStr `shouldSatisfy` ("\"y\"" `isInfixOf`)

    it "AddExpressionRequestTool schema contains field 'expression'" $ do
        let jsonStr = schemaJson "AddExpressionRequestTool" AddExpressionRequestTool
        jsonStr `shouldSatisfy` ("\"expression\"" `isInfixOf`)
