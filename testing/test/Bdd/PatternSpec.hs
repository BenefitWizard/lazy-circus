{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the step-pattern matcher ('matchStep', 'matchAll').
--
-- Covers both quote styles (@\"...\"@ and @«...»@) with capture, Cyrillic
-- text inside guillemets, literal mismatch rejection, whitespace
-- normalization on both sides, multi-word captures, adjacent quoted
-- parameters, the non-empty capture guarantee, unterminated quotes, and the
-- 'matchAll' ambiguity probe (all matches in registration order).
module Bdd.PatternSpec (spec) where

import LazyCircus.Testing.Bdd.Pattern
import Test.Hspec

spec :: Spec
spec = do
    describe "matchStep" $ do
        describe "literal patterns" $ do
            it "matches a plain literal pattern" $
                matchStep "user logs in" "user logs in" `shouldBe` Just []

            it "returns Nothing when literal text does not match" $
                matchStep "user signs up" "user signs in" `shouldBe` Nothing

            it "returns Nothing when the step has extra trailing text" $
                matchStep "user logs in" "user logs in quickly" `shouldBe` Nothing

            it "matches the empty pattern against the empty step" $
                matchStep "" "" `shouldBe` Just []

            it "rejects a non-empty step for the empty pattern" $
                matchStep "" "x" `shouldBe` Nothing

        describe "quoted parameters" $ do
            it "matches and captures straight double quotes" $
                matchStep "the user \"name\" has role \"role\"" "the user alice has role admin" `shouldBe`
                    Just [("name", "alice"), ("role", "admin")]

            it "captures Cyrillic text inside guillemets «»" $
                matchStep "добавить «товар» в корзину" "добавить молоко в корзину" `shouldBe`
                    Just [("товар", "молоко")]

            it "captures multi-word values with inner whitespace normalized" $
                matchStep "user \"name\" said \"phrase\"" "user maria   tetereva said hello\tworld" `shouldBe`
                    Just [("name", "maria tetereva"), ("phrase", "hello world")]

            it "splits two adjacent quoted parameters" $
                matchStep "\"first\" \"second\"" "one two" `shouldBe`
                    Just [("first", "one"), ("second", "two")]

            it "captures a single character (non-empty minimum)" $
                matchStep "\"x\"" "q" `shouldBe` Just [("x", "q")]

            it "forbids an empty capture" $
                matchStep "a \"x\" b" "a b" `shouldBe` Nothing

            it "returns Nothing when a quoted span has no step text at all" $
                matchStep "user \"name\"" "user " `shouldBe` Nothing

            it "treats an unterminated quoted span as literal text" $
                matchStep "count \"n" "count \"n" `shouldBe` Just []

        describe "whitespace normalization" $ do
            it "normalizes runs of spaces and tabs on both sides" $
                matchStep "add  \"item\"\tto\tcart" "add   milk  to cart" `shouldBe`
                    Just [("item", "milk")]

            it "trims both ends of the step text" $
                matchStep "user logs in" "  user logs in  " `shouldBe` Just []

    describe "matchAll" $ do
        let registered =
                [ ("login", "user \"name\" logs in")
                , ("admin", "admin \"name\" logs in")
                , ("logout", "user logs out")
                ]

        it "returns all matching names in registration order" $
            matchAll
                [("wide", "user \"x\""), ("narrow", "user maria")]
                "user maria"
                `shouldBe` ["wide", "narrow"]

        it "returns a single match for an unambiguous step" $
            matchAll registered "user maria logs in" `shouldBe` ["login"]

        it "returns an empty list when nothing matches" $
            matchAll registered "admin signs off" `shouldBe` []

        it "reports the first registered name as the registry winner" $
            case matchAll registered "admin root logs in" of
                ("admin" : _) -> pure ()
                other -> expectationFailure ("expected 'admin' first, got: " <> show other)
