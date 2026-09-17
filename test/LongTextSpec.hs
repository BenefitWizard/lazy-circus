{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the pure Telegram long-text chunker in
-- "LazyCircus.Telegram.LongText".
--
-- Covers the split matrix (empty input, exactly-limit input, separator-free
-- overflow, newline and space boundaries, newline-over-space preference,
-- hard multi-chunk cuts, astral-plane content). Every case also asserts the
-- shared invariants via 'shouldChunkTo': losslessness
-- (@mconcat chunks == original@), the per-chunk code-point bound, and a
-- non-empty chunk list.
module LongTextSpec (spec) where

import LazyCircus.Telegram.LongText
    ( splitTelegramText
    , telegramMessageChunkLimit
    )
import RIO
import RIO.Text qualified as T
import Test.Hspec

-- | Asserts the expected chunking AND, on top of it, the invariants that
-- must hold for every input: the split is lossless, the chunk list is
-- non-empty, and every chunk respects the code-point limit.
shouldChunkTo :: Text -> [Text] -> Expectation
shouldChunkTo input expected = do
    let chunks = splitTelegramText input
    chunks `shouldBe` expected
    mconcat chunks `shouldBe` input
    chunks `shouldNotBe` []
    mapM_ (\chunk -> T.length chunk `shouldSatisfy` (<= telegramMessageChunkLimit)) chunks

spec :: Spec
spec = do
    describe "telegramMessageChunkLimit" $
        it "is 4000 code points" $
            telegramMessageChunkLimit `shouldBe` 4000

    describe "splitTelegramText" $ do
        it "chunks the empty input as the single empty chunk" $
            "" `shouldChunkTo` [""]

        it "keeps input of exactly the limit as one chunk" $
            T.replicate telegramMessageChunkLimit "a"
                `shouldChunkTo` [T.replicate telegramMessageChunkLimit "a"]

        it "hard-splits separator-free input one past the limit into 4000 and 1" $
            T.replicate (telegramMessageChunkLimit + 1) "a"
                `shouldChunkTo` [T.replicate telegramMessageChunkLimit "a", "a"]

        it "cuts at the last newline of the window, newline ending the first chunk" $ do
            let input = T.replicate 100 "a" <> "\n" <> T.replicate 5000 "b"
            input `shouldChunkTo`
                [ T.replicate 100 "a" <> "\n"
                , T.replicate 4000 "b"
                , T.replicate 1000 "b"
                ]

        it "cuts at the last of several newlines in the window" $ do
            let input =
                    T.replicate 10 "a" <> "\n"
                        <> T.replicate 10 "b" <> "\n"
                        <> T.replicate 5000 "c"
            input `shouldChunkTo`
                [ T.replicate 10 "a" <> "\n" <> T.replicate 10 "b" <> "\n"
                , T.replicate 4000 "c"
                , T.replicate 1000 "c"
                ]

        it "cuts at the last space of the window, space ending the first chunk" $ do
            let input = T.replicate 100 "a" <> " " <> T.replicate 5000 "b"
            input `shouldChunkTo`
                [ T.replicate 100 "a" <> " "
                , T.replicate 4000 "b"
                , T.replicate 1000 "b"
                ]

        it "prefers a newline over a later space inside the window" $ do
            let input =
                    T.replicate 3980 "a" <> "\n"
                        <> T.replicate 10 "b" <> " "
                        <> T.replicate 200 "c"
            input `shouldChunkTo`
                [ T.replicate 3980 "a" <> "\n"
                , T.replicate 10 "b" <> " " <> T.replicate 200 "c"
                ]

        it "hard-splits long separator-free input into equal 4000 chunks" $
            T.replicate 9001 "a"
                `shouldChunkTo`
                    [ T.replicate 4000 "a"
                    , T.replicate 4000 "a"
                    , T.replicate 1001 "a"
                    ]

        it "keeps astral-plane content lossless within the code-point bound per chunk" $ do
            let emoji = "\x1F600"
                input = T.replicate 5000 emoji
            input `shouldChunkTo` [T.replicate 4000 emoji, T.replicate 1000 emoji]
