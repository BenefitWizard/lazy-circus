{-# LANGUAGE OverloadedStrings #-}

-- | Equivalence tests: hand-built 'POML' AST (via smart constructors) must be
-- indistinguishable from what the @.poml@ parser produces for the same document.
-- Covers only basic tags (no templates/@<let>@, no tables — those are out of
-- scope for 'parsePomlText': templates can introduce concatenations that the
-- AST cannot represent, and tables use an existential row type). 'parsePomlText'
-- returns a @[POML]@ list (one entry per top-level body node), so every
-- expected value is a singleton list here.
module PomlEquivalenceSpec (spec) where

import LazyCircus.AI.POML.Parser (parsePomlText)
import LazyCircus.AI.POML.Types
    ( b_
    , br
    , code_
    , i_
    , list_
    , p_
    , s_
    , span_
    , u_
    )
import Test.Hspec

spec :: Spec
spec = describe "hand-built POML ≡ parsePomlText" $ do
    it "<p> with static text" $
        parsePomlText "<poml><p>Hello</p></poml>"
            `shouldBe` Right [p_ ["Hello"]]

    it "<b> nested inside <p>" $
        parsePomlText "<poml><p><b>bold</b></p></poml>"
            `shouldBe` Right [p_ [b_ ["bold"]]]

    it "mixed inline content in <p>" $
        parsePomlText "<poml><p>a <b>b</b> <i>c</i></p></poml>"
            `shouldBe` Right [p_ ["a ", b_ ["b"], " ", i_ ["c"]]]

    it "standalone <br/> lowers to the Br constant" $
        parsePomlText "<poml><br/></poml>" `shouldBe` Right [br]

    it "<span> wrapping <u>" $
        parsePomlText "<poml><span><u>under</u></span></poml>"
            `shouldBe` Right [span_ [u_ ["under"]]]

    it "<list> with two <item>s" $
        parsePomlText "<poml><list><item>a</item><item>b</item></list></poml>"
            `shouldBe` Right [list_ [["a"], ["b"]]]

    it "<s> and <code> as standalone nodes" $ do
        parsePomlText "<poml><s>struck</s></poml>" `shouldBe` Right [s_ ["struck"]]
        parsePomlText "<poml><code>x</code></poml>" `shouldBe` Right [code_ ["x"]]
