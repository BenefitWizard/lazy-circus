{-# LANGUAGE OverloadedStrings #-}

-- | Tests for tool-argument enrichment and schema parameter hiding.
--
-- Covers the pure 'ToolEnrichment' semantics (layered per-tool Object merge
-- with the programmatic side winning), 'withToolEnrichment' accumulation on
-- 'AgentRequest', 'hideSchemaParams' / 'hideToolParams', and the TH-generated
-- parameter schema of the secure_query demo tool (the user-identifying field
-- must be hidden from the schema and injected programmatically instead).
module ToolEnrichmentSpec (spec) where

import Control.Concurrent.Async (cancel)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import LazyCircus.AI
    ( AgentRequest (agentToolEnrichment)
    , IsTool (..)
    , applyToolEnrichment
    , enrichTool
    , mkAgentRequest
    , withToolEnrichment
    )
import LazyCircus.App.Service (ToolCallExec (..), ToolDescription (..), hideSchemaParams, hideToolParams, runAllWorkers)
import RIO.Vector qualified as V
import SimpleService (SecureCtx (..), handleAddExpressionRequest, handleSecureRequest, handleSimpleRequest)
import SimpleServiceLib
    ( AllServices,
      AllServicesConfig (..),
      AllServicesTool (..),
      mkAllServices,
      mkToolCallExec,
      toolInfo
    )
import Test.Hspec

-- | A hand-written tool used as the 'IsTool' subject of the semantics tests.
demoTool :: ToolDescription
demoTool = ToolDescription "demo_tool" "A demo tool" Nothing

-- | Asserts that a 'Value' is a JSON object with exactly the given fields
-- (extra or missing fields fail; key order is irrelevant).
expectObjectFields :: HasCallStack => Value -> [(KM.Key, Value)] -> IO ()
expectObjectFields (Object km) fields = do
    KM.size km `shouldBe` length fields
    forM_ fields $ \(name, val) -> KM.lookup name km `shouldBe` Just val
expectObjectFields other _ = expectationFailure $ "expected a JSON object, got " ++ show other

-- | Runs an action with the generated service library built from real
-- handlers (no database) and its workers forked.
-- POST-CONTRACT: Worker threads are cancelled after the action completes.
withSecureServiceLib :: (AllServices -> IO a) -> IO a
withSecureServiceLib action =
    bracket
        ( do
            let config = AllServicesConfig
                    { simpleRequest = handleSimpleRequest
                    , addExpressionRequest = handleAddExpressionRequest
                    , secureRequest = handleSecureRequest
                    }
            (allServices, workers) <- mkAllServices config
            handles <- runAllWorkers workers
            pure (allServices, handles)
        )
        (\(_, handles) -> mapM_ cancel handles)
        (\(allServices, _) -> action allServices)

spec :: Spec
spec =
    describe "ToolEnrichment" $ do
        describe "applyToolEnrichment" $ do
            it "layers programmatic fields over model args per-field with the programmatic side winning" $ do
                let enrichment = enrichTool demoTool (object ["a" .= (1 :: Int)])
                    modelArgs = object ["a" .= (2 :: Int), "b" .= True]
                expectObjectFields
                    (applyToolEnrichment enrichment (toolName demoTool) modelArgs)
                    [("a", toJSON (1 :: Int)), ("b", toJSON True)]

            it "leaves model args unchanged when the tool is absent from the enrichment map" $ do
                let enrichment = enrichTool demoTool (object ["a" .= (1 :: Int)])
                    modelArgs = object ["b" .= True]
                applyToolEnrichment enrichment "other_tool" modelArgs `shouldBe` modelArgs

            it "leaves model args unchanged when they are not a JSON object" $ do
                let enrichment = enrichTool demoTool (object ["a" .= (1 :: Int)])
                    argsArray = Array (V.fromList [toJSON (1 :: Int)])
                applyToolEnrichment enrichment (toolName demoTool) (String "raw") `shouldBe` String "raw"
                applyToolEnrichment enrichment (toolName demoTool) argsArray `shouldBe` argsArray

            it "replaces model args entirely when the enrichment value is not a JSON object" $ do
                let enrichment = enrichTool demoTool ("scalar" :: Text)
                applyToolEnrichment enrichment (toolName demoTool) (object ["a" .= (1 :: Int)])
                    `shouldBe` String "scalar"

        describe "withToolEnrichment" $
            it "adds an enrichment fragment via <> without discarding existing fields; the new fragment wins conflicts" $ do
                let base =
                        withToolEnrichment
                            (enrichTool demoTool (object ["user" .= ("u1" :: Text)]))
                            (mkAgentRequest ["p"] ["s"] 3 :: AgentRequest Value)
                    layered =
                        withToolEnrichment
                            (enrichTool demoTool (object ["sql" .= ("SELECT 1" :: Text), "user" .= ("u2" :: Text)]))
                            base
                expectObjectFields
                    (applyToolEnrichment (agentToolEnrichment layered) (toolName demoTool) (object []))
                    [("user", toJSON ("u2" :: Text)), ("sql", toJSON ("SELECT 1" :: Text))]

        describe "hideSchemaParams / hideToolParams" $ do
            it "removes hidden keys from both properties and required" $ do
                let schema = object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= object
                            [ "a" .= object ["type" .= ("string" :: Text)]
                            , "b" .= object ["type" .= ("string" :: Text)]
                            ]
                        , "required" .= ["a" :: Text, "b" :: Text]
                        ]
                    expected = object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= object ["b" .= object ["type" .= ("string" :: Text)]]
                        , "required" .= ["b" :: Text]
                        ]
                hideSchemaParams ["a"] schema `shouldBe` expected

            it "returns the schema unchanged when it does not contain the hidden key" $ do
                let schema = object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= object ["b" .= object ["type" .= ("string" :: Text)]]
                        ]
                hideSchemaParams ["zzz"] schema `shouldBe` schema

            it "keeps a parameter-less tool description unchanged" $
                hideToolParams ["a"] (ToolDescription "t" "d" Nothing)
                    `shouldBe` ToolDescription "t" "d" Nothing

            it "leaves required untouched when it is absent or not an array" $ do
                let props = object
                        [ "a" .= object ["type" .= ("string" :: Text)]
                        , "b" .= object ["type" .= ("string" :: Text)]
                        ]
                    propsHidden = object ["b" .= object ["type" .= ("string" :: Text)]]
                    -- required absent: properties still filtered, no required key appears
                    noRequired = object ["type" .= ("object" :: Text), "properties" .= props]
                    noRequiredExpected = object ["type" .= ("object" :: Text), "properties" .= propsHidden]
                    -- required not an array: kept verbatim while properties are filtered
                    nonArrayRequired = object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= props
                        , "required" .= ("all" :: Text)
                        ]
                    nonArrayExpected = object
                        [ "type" .= ("object" :: Text)
                        , "properties" .= propsHidden
                        , "required" .= ("all" :: Text)
                        ]
                hideSchemaParams ["a"] noRequired `shouldBe` noRequiredExpected
                hideSchemaParams ["a"] nonArrayRequired `shouldBe` nonArrayExpected

        describe "generated secure_query tool schema" $
            it "omits secureRequestUserId from properties and required but keeps secureRequestSql" $ do
                let desc = toolInfo SecureRequestTool
                toolDescName desc `shouldBe` "secure_query"
                case toolDescParameters desc of
                    Nothing -> expectationFailure "expected the generated parameter schema to be present"
                    Just (Object km) -> do
                        case KM.lookup "properties" km of
                            Just (Object props) -> do
                                KM.member "secureRequestUserId" props `shouldBe` False
                                KM.member "secureRequestSql" props `shouldBe` True
                            _ -> expectationFailure "expected a properties object in the generated schema"
                        case KM.lookup "required" km of
                            Just (Array reqs) -> do
                                V.toList reqs `shouldNotContain` [String "secureRequestUserId"]
                                V.toList reqs `shouldContain` [String "secureRequestSql"]
                            _ -> expectationFailure "expected a required array in the generated schema"
                    Just other -> expectationFailure $ "expected the schema to be a JSON object, got " ++ show other

        describe "enriched secure_query through the generated dispatch" $
            it "decodes enriched arguments via the generated FromJSON and echoes the injected user id" $
                withSecureServiceLib $ \services -> do
                    let enrichedArgs =
                            applyToolEnrichment
                                (enrichTool SecureRequestTool (SecureCtx "u42"))
                                (toolName SecureRequestTool)
                                (object ["secureRequestSql" .= ("SELECT 1" :: Text)])
                    response <-
                        runToolCallExec (mkToolCallExec services) (toolName SecureRequestTool) enrichedArgs
                    response `shouldBe` object
                        [ "tool_name" .= ("secure_query" :: Text)
                        , "result" .= object ["result" .= ("u42: SELECT 1" :: Text)]
                        ]
