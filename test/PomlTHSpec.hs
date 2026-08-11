{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- The 'LazyCircus.AI.POML.Types' import is flagged as redundant because the
-- @makePoml@ splice uses fully-qualified 'Name's. We keep the import anyway to
-- honour the documented consumer-side contract of "LazyCircus.AI.POML.TH"
-- (its Haddock lists @POML(..)@ and @defaultListParams@ as required in scope).
{-# OPTIONS_GHC -Wno-unused-imports #-}

-- | Tests for the @makePoml@ Template Haskell macro defined in
-- "LazyCircus.AI.POML.TH". The macro reads @.poml@ files at compile time and
-- generates a record type (when the document declares @<let>@ variables) plus
-- a function that builds a 'POML' AST node from the record's fields.
--
-- These tests splice four documents — string substitution (@hello@), a
-- no-input static value (@greeting@), string concatenation (@contact@), and a
-- templated @<cp caption>@ (@caption@) — and assert that the generated
-- functions render to the expected prompt text via 'renderPOMLtoPrompt'. They
-- also confirm that the generated input records carry the documented 'Eq' and
-- 'Show' derivations.
module PomlTHSpec (spec) where

import Data.List (isInfixOf)
import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.TH (makePoml)
import LazyCircus.AI.POML.Types (POML (..), defaultListParams)
import RIO
import Test.Hspec

-- | Generates @HelloInput@ and @hello :: HelloInput -> POML@ from
-- @app/example/prompts/hello.poml@.
$(makePoml "hello" "app/example/prompts/hello.poml")

-- | Generates @greeting :: POML@ (no input record) from
-- @app/example/prompts/greeting.poml@.
$(makePoml "greeting" "app/example/prompts/greeting.poml")

-- | Generates @ContactInput@ and @contact :: ContactInput -> POML@ from
-- @app/example/prompts/contact.poml@.
$(makePoml "contact" "app/example/prompts/contact.poml")

-- | Generates @CaptionInput@ and @caption :: CaptionInput -> POML@ from
-- @app/example/prompts/caption.poml@ (a templated <cp caption>).
$(makePoml "caption" "app/example/prompts/caption.poml")

spec :: Spec
spec = describe "makePoml" $ do
    it "substitutes a string <let> variable into the rendered prompt" $
        renderPOMLtoPrompt [hello (HelloInput{name = "World"})]
            `shouldBe` "<p>Hello, World!</p>"

    it "uses the supplied input field rather than a hardcoded value" $
        renderPOMLtoPrompt [hello (HelloInput{name = "Alice"})]
            `shouldBe` "<p>Hello, Alice!</p>"

    it "generates a nullary value when the document has no <let> declarations" $
        renderPOMLtoPrompt [greeting] `shouldBe` "<p>Welcome to the circus!</p>"

    it "concatenates multiple string <let> variables inside one template" $
        renderPOMLtoPrompt
            [contact (ContactInput{firstName = "Jane", lastName = "Doe"})]
            `shouldBe` "<p>Contact: Jane Doe</p>"

    it "substitutes a templated <cp caption> variable into the rendered caption" $
        renderPOMLtoPrompt [caption (CaptionInput{topic = "Cats"})]
            `shouldBe` "<cp caption=\"Cats\">Describe it.</cp>"

    it "uses the supplied input field to change the rendered caption" $
        renderPOMLtoPrompt [caption (CaptionInput{topic = "Dogs"})]
            `shouldBe` "<cp caption=\"Dogs\">Describe it.</cp>"

    it "derives Eq on the generated input record" $
        HelloInput{name = "A"} `shouldBe` HelloInput{name = "A"}

    it "derives Show on the generated input record" $
        show (HelloInput{name = "X"})
            `shouldSatisfy` ("HelloInput" `isInfixOf`)

-- NOTE: A `.poml` with a `poml`-typed variable inside a concatenation
-- (e.g. {{pomlVar + "text"}}) causes `makePoml` to call `fail` at compile
-- time, producing a GHC error. This cannot be tested as a passing hspec
-- example because the module would not compile. Verified manually:
--   <poml><let name="p" type="poml"/><p>{{p + "!"}}</p></poml>
-- → compile error: "poml-typed variable 'p' cannot participate in concatenation".
