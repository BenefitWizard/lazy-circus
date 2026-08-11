{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the @.poml@ parser entry points ('parsePoml' and 'parsePomlText').
--
-- Covers the structural-document path ('parsePoml' producing a 'PomlDoc' with
-- @<let>@ metadata and body nodes), the error cases (unknown tag, bad <let>
-- type, non-<poml> root, unterminated template), and the single-node lowering
-- path ('parsePomlText' -> 'POML').
module PomlParserSpec (spec) where

import Data.Either (isLeft)
import LazyCircus.AI.POML.Parser
    ( LetDecl (..)
    , PomlDoc (..)
    , PomlNode (..)
    , PomlType (..)
    , TemplateExpr (..)
    , parsePoml
    , parsePomlText
    )
import LazyCircus.AI.POML.Types (POML, p_, var)
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
