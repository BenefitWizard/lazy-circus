{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the POML renderer ('renderPOMLtoPrompt') covering the
-- standardized tag names, heading/code attributes, the self-closing <br/> tag,
-- variable-name preservation, and nested inline content.
module PomlRendererSpec (spec) where

import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.Types
    ( POML (..)
    , b_
    , br
    , code_
    , cp_
    , example_
    , exampleInput_
    , exampleOutput_
    , examples_
    , h_
    , hLvl_
    , i_
    , p_
    , role_
    , s_
    , span_
    , task_
    , u_
    , var
    )
import Test.Hspec

spec :: Spec
spec = describe "renderPOMLtoPrompt" $ do
    it "renders <p> with content" $
        renderPOMLtoPrompt [p_ ["hi"]] `shouldBe` "<p>hi</p>"

    it "renders the <b> (strong) tag" $
        renderPOMLtoPrompt [b_ ["bold"]] `shouldBe` "<b>bold</b>"

    it "renders the <i> (italic) tag" $
        renderPOMLtoPrompt [i_ ["it"]] `shouldBe` "<i>it</i>"

    it "renders the <u> (underline) tag" $
        renderPOMLtoPrompt [u_ ["un"]] `shouldBe` "<u>un</u>"

    it "renders the <s> (strikethrough) tag" $
        renderPOMLtoPrompt [s_ ["sk"]] `shouldBe` "<s>sk</s>"

    it "renders the <span> tag" $
        renderPOMLtoPrompt [span_ ["sp"]] `shouldBe` "<span>sp</span>"

    it "renders <br/> as a self-closing tag, alone and alongside <p>" $ do
        renderPOMLtoPrompt [br] `shouldBe` "<br/>"
        renderPOMLtoPrompt [p_ ["hi"], br] `shouldBe` "<p>hi</p><br/>"

    it "renders <h> with an explicit level attribute" $
        renderPOMLtoPrompt [hLvl_ 2 ["Title"]] `shouldBe` "<h level=\"2\">Title</h>"

    it "renders <h> with default level 1 when level is Nothing" $
        renderPOMLtoPrompt [h_ ["Default"]] `shouldBe` "<h level=\"1\">Default</h>"

    it "renders <code> without a syntax attribute" $
        renderPOMLtoPrompt [code_ ["x = 1"]] `shouldBe` "<code>x = 1</code>"

    it "renders <code> with an explicit syntax attribute" $
        renderPOMLtoPrompt [Code (Just "haskell") ["x"]]
            `shouldBe` "<code syntax=\"haskell\">x</code>"

    it "preserves the variable name in {{name}} (not the legacy {{var}} form)" $
        renderPOMLtoPrompt [var "username"] `shouldBe` "{{username}}"

    it "uses standardized tag names <input>/<output> for example blocks" $ do
        renderPOMLtoPrompt [exampleInput_ ["q"]] `shouldBe` "<input>q</input>"
        renderPOMLtoPrompt [exampleOutput_ ["a"]] `shouldBe` "<output>a</output>"

    it "renders the standalone <example> node (Example constructor)" $
        renderPOMLtoPrompt [example_ ["x"]] `shouldBe` "<example>x</example>"

    it "renders the <role> tag" $
        renderPOMLtoPrompt [role_ ["kind"]] `shouldBe` "<role>kind</role>"

    it "renders the <task> tag" $
        renderPOMLtoPrompt [task_ ["do it"]] `shouldBe` "<task>do it</task>"

    it "renders <cp> with its caption attribute" $
        renderPOMLtoPrompt [cp_ "C" ["x"]] `shouldBe` "<cp caption=\"C\">x</cp>"

    it "renders <examples> wrapping each example in <example>" $
        renderPOMLtoPrompt
            [examples_ [[exampleInput_ ["q"], exampleOutput_ ["a"]]]]
            `shouldBe` "<examples><example><input>q</input><output>a</output></example></examples>"

    it "renders nested inline content" $
        renderPOMLtoPrompt [p_ [b_ ["bold"], " and ", i_ ["italic"]]]
            `shouldBe` "<p><b>bold</b> and <i>italic</i></p>"
