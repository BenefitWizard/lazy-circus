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
-- a function that builds a @[POML]@ list from the record's fields.
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
import LazyCircus.AI.POML.Types (POML (..), defaultListParams, fragment, p_)
import RIO
import Test.Hspec

-- | Generates @HelloInput@ and @hello :: HelloInput -> [POML]@ from
-- @app/example/prompts/hello.poml@.
$(makePoml "hello" "app/example/prompts/hello.poml")

-- | Generates @greeting :: [POML]@ (no input record) from
-- @app/example/prompts/greeting.poml@.
$(makePoml "greeting" "app/example/prompts/greeting.poml")

-- | Generates @ContactInput@ and @contact :: ContactInput -> [POML]@ from
-- @app/example/prompts/contact.poml@.
$(makePoml "contact" "app/example/prompts/contact.poml")

-- | Generates @CaptionInput@ and @caption :: CaptionInput -> [POML]@ from
-- @app/example/prompts/caption.poml@ (a templated <cp caption>).
$(makePoml "caption" "app/example/prompts/caption.poml")

-- | Generates @multi :: [POML]@ (no input record) from
-- @app/example/prompts/multi.poml@ — a document with two top-level body
-- elements, exercising the multi-root lowering path.
$(makePoml "multi" "app/example/prompts/multi.poml")

-- | Generates @InnerInput@ and @inner :: InnerInput -> [POML]@ from
-- @app/example/prompts/inner.poml@ — a single-node template meant to be
-- spliced into a @poml@-typed slot of another template.
$(makePoml "inner" "app/example/prompts/inner.poml")

-- | Generates @InnerMultiInput@ and @innerMulti :: InnerMultiInput -> [POML]@
-- from @app/example/prompts/innerMulti.poml@ — a two-node template exercising
-- @fragment@ composition with a multi-root source (the case a plain
-- pattern-match cannot handle).
$(makePoml "innerMulti" "app/example/prompts/innerMulti.poml")

-- | Generates @OuterInput@ and @outer :: OuterInput -> [POML]@ from
-- @app/example/prompts/outer.poml@ — a template that composes a @poml@-typed
-- @greeting@ slot (spliced as a subtree) alongside a @string@-typed @topic@.
$(makePoml "outer" "app/example/prompts/outer.poml")

-- | Generates @ReferInput@ and @refer :: ReferInput -> [POML]@ from
-- @app/example/prompts/refer.poml@ — a @string@-typed @who@ runtime input
-- composed with a @src@-inlined @notice@ constant in one concatenation. The
-- constant comes from @refer-disclaimer.txt@ (read verbatim at compile time).
$(makePoml "refer" "app/example/prompts/refer.poml")

-- | Generates @notice :: [POML]@ (no input record — only a @src@ constant)
-- from @app/example/prompts/notice.poml@ — exercises a document whose sole
-- variable is a compile-time file constant, so no @XInput@ record is produced.
$(makePoml "notice" "app/example/prompts/notice.poml")

-- | Generates @jsonFmt :: [POML]@ (no input record — only a @src@ constant)
-- from @app/example/prompts/jsonFmt.poml@ — inlines a JSON response-format
-- schema (@response-format.json@) verbatim into a @<code>@ block. Guards the
-- primary use case: specifying the expected response shape inside a prompt.
-- Special characters in the JSON (@{@, @}@, @"@, @\\@) survive because the file
-- is read by @readFileUtf8@ (not XML-parsed) and emitted as a 'Text' literal.
$(makePoml "jsonFmt" "app/example/prompts/jsonFmt.poml")

spec :: Spec
spec = describe "makePoml" $ do
    it "substitutes a string <let> variable into the rendered prompt" $
        renderPOMLtoPrompt (hello (HelloInput{name = "World"}))
            `shouldBe` "<p>Hello, World!</p>"

    it "uses the supplied input field rather than a hardcoded value" $
        renderPOMLtoPrompt (hello (HelloInput{name = "Alice"}))
            `shouldBe` "<p>Hello, Alice!</p>"

    it "generates a nullary value when the document has no <let> declarations" $
        renderPOMLtoPrompt greeting `shouldBe` "<p>Welcome to the circus!</p>"

    it "concatenates multiple string <let> variables inside one template" $
        renderPOMLtoPrompt
            (contact (ContactInput{firstName = "Jane", lastName = "Doe"}))
            `shouldBe` "<p>Contact: Jane Doe</p>"

    it "substitutes a templated <cp caption> variable into the rendered caption" $
        renderPOMLtoPrompt (caption (CaptionInput{topic = "Cats"}))
            `shouldBe` "<cp caption=\"Cats\">Describe it.</cp>"

    it "uses the supplied input field to change the rendered caption" $
        renderPOMLtoPrompt (caption (CaptionInput{topic = "Dogs"}))
            `shouldBe` "<cp caption=\"Dogs\">Describe it.</cp>"

    it "lowers a multi-root body to a concatenated [POML] list" $
        renderPOMLtoPrompt multi
            `shouldBe` "<role>Be kind</role><task>Do it</task>"

    it "splices a poml-typed slot with a single POML node built via the eDSL" $
        renderPOMLtoPrompt
            (outer (OuterInput{body = p_ ["Greetings!"], subject = "cats"}))
            `shouldBe`
                "<role>You are a friendly assistant.</role>"
                    <> "<p>Greetings!</p>"
                    <> "<task>Now tell me about cats.</task>"

    it "composes one makePoml template into another's poml-typed slot via fragment" $
        renderPOMLtoPrompt
            (outer (OuterInput{body = fragment (inner (InnerInput{who = "World"})), subject = "cats"}))
            `shouldBe`
                "<role>You are a friendly assistant.</role>"
                    <> "<p>Hello, World!</p>"
                    <> "<task>Now tell me about cats.</task>"

    it "composes a multi-root template (fragment collapses >1 node into one POML)" $
        renderPOMLtoPrompt
            (outer (OuterInput{body = fragment (innerMulti (InnerMultiInput{recipient = "World"})), subject = "cats"}))
            `shouldBe`
                "<role>You are a friendly assistant.</role>"
                    <> "<p>Greeting #1 for World.</p>"
                    <> "<p>Greeting #2 for World.</p>"
                    <> "<task>Now tell me about cats.</task>"

    it "derives Eq on the generated input record" $
        HelloInput{name = "A"} `shouldBe` HelloInput{name = "A"}

    it "derives Show on the generated input record" $
        show (HelloInput{name = "X"})
            `shouldSatisfy` ("HelloInput" `isInfixOf`)

    it "inlines a <let src=\"...\"> file verbatim into the prompt at compile time" $
        renderPOMLtoPrompt (refer (ReferInput{user = "Alice"}))
            `shouldBe` "<p>Hi Alice! See the docs.\n</p>"

    it "lets a <let src=\"...\"> constant participate in a concatenation with a string field" $
        renderPOMLtoPrompt (refer (ReferInput{user = "Bob"}))
            `shouldBe` "<p>Hi Bob! See the docs.\n</p>"

    it "generates a nullary value when the document's only <let> is a src constant" $
        renderPOMLtoPrompt notice `shouldBe` "<p>See the docs.\n</p>"

    it "inlines a JSON schema file verbatim (special chars preserved) into a <code> block" $ do
        schema <- readFileUtf8 "app/example/prompts/response-format.json"
        renderPOMLtoPrompt jsonFmt
            `shouldBe` "<role>You are a structured responder.</role>"
                    <> "<task>Reply with JSON in exactly this shape:</task>"
                    <> "<code>" <> schema <> "</code>"

-- NOTE: A `.poml` with a `poml`-typed variable inside a concatenation
-- (e.g. {{pomlVar + "text"}}) causes `makePoml` to call `fail` at compile
-- time, producing a GHC error. This cannot be tested as a passing hspec
-- example because the module would not compile. Verified manually:
--   <poml><let name="p" type="poml"/><p>{{p + "!"}}</p></poml>
-- → compile error: "poml-typed variable 'p' cannot participate in concatenation".
