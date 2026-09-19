{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the step-pattern matcher ('matchStep', 'matchAll').
--
-- Templates capture STRICTLY quoted values: a quoted span (@\"...\"@ and
-- @«...»@) matches a value wrapped in a pair of matching quote characters in
-- the step text — either style, regardless of the style the span uses — and
-- the captured value excludes the quotes. Covers both quote styles (including
-- cross-style span\/step pairings), Cyrillic values inside guillemets,
-- literal mismatch rejection, whitespace normalization on both sides (quoted
-- boundaries never glue), multi-word values, adjacent quoted parameters, the
-- non-empty capture guarantee, unterminated quotes in the pattern (matched
-- literally), the 'Literal' constructor (quotes verbatim, no captures), and
-- 'matchAll' (all matches in input order).
module Bdd.PatternSpec (spec) where

import LazyCircus.Testing.Bdd.Pattern
import Test.Hspec

spec :: Spec
spec = do
    describe "matchStep" $ do
        describe "templates" $ do
            it "matches a capture-free template" $
                matchStep "user logs in" "user logs in" `shouldBe` Just []

            it "returns Nothing when literal text does not match" $
                matchStep "user signs up" "user signs in" `shouldBe` Nothing

            it "returns Nothing when the step has extra trailing text" $
                matchStep "user logs in" "user logs in quickly" `shouldBe` Nothing

            it "matches the empty pattern against the empty step" $
                matchStep "" "" `shouldBe` Just []

            it "rejects a non-empty step for the empty pattern" $
                matchStep "" "x" `shouldBe` Nothing

        describe "strict quoted captures" $ do
            it "captures values wrapped in straight double quotes" $
                matchStep "the user \"name\" has role \"role\"" "the user \"alice\" has role \"admin\"" `shouldBe`
                    Just [("name", "alice"), ("role", "admin")]

            it "captures the value without its surrounding quotes" $
                matchStep "the user sends \"$m\"" "the user sends \"hello\"" `shouldBe`
                    Just [("$m", "hello")]

            it "rejects a step value without quotes" $
                matchStep "the user sends \"$m\"" "the user sends hello" `shouldBe` Nothing

            it "rejects the unquoted form of a multi-capture step" $
                matchStep "the user \"name\" has role \"role\"" "the user alice has role admin" `shouldBe`
                    Nothing

            it "captures Cyrillic values inside guillemets «»" $
                matchStep "добавить «товар» в корзину" "добавить «молоко» в корзину" `shouldBe`
                    Just [("товар", "молоко")]

            it "accepts a guillemet step value for a straight-quote span (either style)" $
                matchStep "say \"$x\"" "say «hi»" `shouldBe` Just [("$x", "hi")]

            it "accepts a straight-quote step value for a guillemet span (either style)" $
                matchStep "say «x»" "say \"hi\"" `shouldBe` Just [("x", "hi")]

            it "still rejects a value whose quote characters do not pair" $
                matchStep "say \"$x\"" "say \"hi»" `shouldBe` Nothing

            it "captures regex metacharacters inside quoted spans literally" $
                matchStep "bot replies «(.*?)» to \"user\"" "bot replies «(.*?)» to \"maria\"" `shouldBe`
                    Just [("(.*?)", "(.*?)"), ("user", "maria")]

            it "captures multi-word values with internal spaces preserved after normalization" $
                matchStep "user \"$x\" acts" "user \"x  y\"  acts" `shouldBe` Just [("$x", "x y")]

            it "captures multi-word values with inner whitespace normalized" $
                matchStep "user \"name\" said \"phrase\"" "user \"maria   tetereva\" said \"hello\tworld\"" `shouldBe`
                    Just [("name", "maria tetereva"), ("phrase", "hello world")]

            it "splits two adjacent quoted parameters with two quoted values" $
                matchStep "\"$a\" \"$b\"" "\"one\" \"two\"" `shouldBe`
                    Just [("$a", "one"), ("$b", "two")]

            it "captures a single character (non-empty minimum)" $
                matchStep "\"x\"" "\"q\"" `shouldBe` Just [("x", "q")]

            it "forbids an empty capture" $
                matchStep "a \"x\" b" "a \"\" b" `shouldBe` Nothing

            it "returns Nothing when a quoted span has no step text at all" $
                matchStep "user \"name\"" "user " `shouldBe` Nothing

            it "treats an unterminated quoted span in the pattern as literal text" $
                matchStep "count \"n" "count \"n" `shouldBe` Just []

        describe "literal patterns" $ do
            it "matches a Literal containing quotes verbatim, capturing nothing" $
                matchStep (Literal "the message invites you via \"/edit_contacts\"")
                    "the message invites you via \"/edit_contacts\""
                    `shouldBe` Just []

            it "rejects a Literal when the quotes are missing from the step" $
                matchStep (Literal "the message invites you via \"/edit_contacts\"")
                    "the message invites you via /edit_contacts"
                    `shouldBe` Nothing

            it "template and literal of the same text both match, with and without captures" $ do
                matchStep (Template "say \"hi\"") "say \"hi\"" `shouldBe` Just [("hi", "hi")]
                matchStep (Literal "say \"hi\"") "say \"hi\"" `shouldBe` Just []

        describe "whitespace normalization" $ do
            it "normalizes runs of spaces and tabs on both sides" $
                matchStep "add  \"$item\"\tto\tcart" "add   \"milk\"  to cart" `shouldBe`
                    Just [("$item", "milk")]

            it "trims both ends of the step text" $
                matchStep "user logs in" "  user logs in  " `shouldBe` Just []

            it "never glues a quoted span to surrounding text" $
                matchStep "user \"$x\" acts" "user\"x\" acts" `shouldBe` Nothing

    describe "matchAll" $ do
        let registered =
                [ ("login", "user \"name\" logs in")
                , ("admin", "admin \"name\" logs in")
                , ("logout", "user logs out")
                ]

        it "returns all matching names in registration order" $
            matchAll
                [("wide", "user \"$x\""), ("narrow", Literal "user \"maria\"")]
                "user \"maria\""
                `shouldBe` ["wide", "narrow"]

        it "returns a single match for an unambiguous step" $
            matchAll registered "user \"maria\" logs in" `shouldBe` ["login"]

        it "returns an empty list when nothing matches" $
            matchAll registered "user signs off" `shouldBe` []
