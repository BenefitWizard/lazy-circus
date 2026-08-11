{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the @.poml@ parser entry points ('parsePoml' and 'parsePomlText').
--
-- Covers the structural-document path ('parsePoml' producing a 'PomlDoc' with
-- @<let>@ metadata and body nodes), the error cases (unknown tag, bad <let>
-- type, non-<poml> root, unterminated template), and the single-node lowering
-- path ('parsePomlText' -> 'POML').
module PomlParserSpec (spec) where

import Data.Either (isLeft)
import Data.List (isInfixOf)
import LazyCircus.AI.POML.Parser
    ( LetDecl (..)
    , PomlDoc (..)
    , PomlNode (..)
    , PomlType (..)
    , TemplateExpr (..)
    , parsePoml
    , parsePomlText
    )
import LazyCircus.AI.POML.Types
    ( POML
    , cp_
    , exampleInput_
    , exampleOutput_
    , examples_
    , p_
    , role_
    , task_
    , var
    )
import Test.Hspec

spec :: Spec
spec = do
    describe "parsePoml" $ do
        it "parses a valid hello-style doc with <let> and <p>" $ do
            let input = "<poml><let name=\"name\" type=\"string\"/><p>Hello, {{name}}!</p></poml>"
            case parsePoml input of
                Left err -> expectationFailure ("expected Right, got Left: " <> err)
                Right PomlDoc{pdLets, pdBody} -> do
                    length pdLets `shouldBe` 1
                    case pdLets of
                        [LetDecl{letName, letType}] -> do
                            letName `shouldBe` "name"
                            letType `shouldBe` PTString
                        _ -> expectationFailure ("expected exactly one <let>, got: " <> show pdLets)
                    pdBody
                        `shouldBe` [ NodeElement "p" []
                                        [NodeText [TLit "Hello, ", TVar "name", TLit "!"]]
                                   ]

        it "rejects an unknown tag with Left" $
            parsePoml "<poml><foo/></poml>" `shouldSatisfy` isLeft

        it "rejects an invalid <let> type with Left" $
            parsePoml "<poml><let name=\"x\" type=\"integer\"/></poml>" `shouldSatisfy` isLeft

        it "rejects a non-<poml> root element with Left" $
            parsePoml "<doc/>" `shouldSatisfy` isLeft

        it "rejects an unterminated {{...}} template with Left" $
            parsePoml "<poml><p>{{name</p></poml>" `shouldSatisfy` isLeft

    describe "parsePomlText" $ do
        it "lowers a single static text node to a Paragraph POML" $
            parsePomlText "<poml><p>Hi</p></poml>"
                `shouldBe` Right (p_ ["Hi" :: POML])

        it "lowers a single variable placeholder to a Var POML" $
            parsePomlText "<poml><p>{{x}}</p></poml>"
                `shouldBe` Right (p_ [var "x"])

        it "rejects template concatenation with Left" $
            parsePomlText "<poml><p>{{a + b}}</p></poml>" `shouldSatisfy` isLeft

        it "rejects multiple top-level elements with Left" $
            parsePomlText "<poml><p>A</p><p>B</p></poml>" `shouldSatisfy` isLeft

    describe "semantic tags" $ do
        it "parses <role> into a Role node" $
            parsePomlText "<poml><role>Be kind</role></poml>"
                `shouldBe` Right (role_ ["Be kind" :: POML])

        it "parses <task> into a Task node" $
            parsePomlText "<poml><task>T</task></poml>"
                `shouldBe` Right (task_ ["T" :: POML])

        it "parses <cp caption=\"C\"> into a CP node" $
            parsePomlText "<poml><cp caption=\"C\">x</cp></poml>"
                `shouldBe` Right (cp_ "C" ["x" :: POML])

        it "parses <input> into an ExampleInput node" $
            parsePomlText "<poml><input>q</input></poml>"
                `shouldBe` Right (exampleInput_ ["q" :: POML])

        it "parses <output> into an ExampleOutput node" $
            parsePomlText "<poml><output>a</output></poml>"
                `shouldBe` Right (exampleOutput_ ["a" :: POML])

        it "parses <examples><example> into an ExampleSet node" $
            parsePomlText
                "<poml><examples><example><input>q</input><output>a</output></example></examples></poml>"
                `shouldBe` Right
                    ( examples_
                        [ [ exampleInput_ ["q" :: POML]
                          , exampleOutput_ ["a" :: POML]
                          ]
                        ]
                    )

        it "parses a standalone <example> into an Example node" $
            parsePomlText "<poml><example><input>i</input></example></poml>"
                `shouldSatisfy` \r -> case r of
                    Right p -> "Example" `isInfixOf` show p
                    Left _ -> False

        it "rejects <cp> without a caption attribute with Left" $
            parsePomlText "<poml><cp>x</cp></poml>" `shouldSatisfy` isLeft

        it "rejects a templated <cp caption=\"{{v}}\"> with Left on the static path" $
            parsePomlText "<poml><cp caption=\"{{v}}\">x</cp></poml>"
                `shouldSatisfy` isLeft

        it "rejects a non-<example> child of <examples> with Left" $
            parsePomlText "<poml><examples><p>not an example</p></examples></poml>"
                `shouldSatisfy` isLeft

        it "rejects direct text inside <examples> with Left" $
            parsePomlText "<poml><examples>direct text</examples></poml>"
                `shouldSatisfy` isLeft

        it "lowers <cp caption=\"C\"> to a NodeElement with a TLit caption in the intermediate PomlDoc" $
            case parsePoml "<poml><cp caption=\"C\">x</cp></poml>" of
                Left err -> expectationFailure ("expected Right, got Left: " <> err)
                Right PomlDoc{pdBody} ->
                    pdBody
                        `shouldBe` [ NodeElement "cp"
                                        [("caption", Just (TLit "C"))]
                                        [NodeText [TLit "x"]]
                                   ]
