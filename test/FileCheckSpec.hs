{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the pure Telegram file size gates and the SHA-256 utility in
-- "LazyCircus.Telegram.FileCheck".
--
-- Covers the gate A matrix ('checkFileSize' on server-reported sizes), the
-- gate B matrix ('checkDownloadedBytes' on actual byte lengths, including the
-- boundary and pass-through of the original bytes), the size-spoofing
-- scenario where gate A passes on an under-reported size but gate B catches
-- the real payload, and 'fileSha256Hex' stability, output length, and known
-- SHA-256 vectors.
module FileCheckSpec (spec) where

import LazyCircus.Telegram.FileCheck
    ( FileValidationError (..)
    , checkDownloadedBytes
    , checkFileSize
    , fileSha256Hex
    , telegramMaxDownloadBytes
    )
import RIO.ByteString qualified as BS
import RIO.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
    describe "telegramMaxDownloadBytes" $
        it "is the Bot API hard limit of 20 MiB" $
            telegramMaxDownloadBytes `shouldBe` (20 * 1024 * 1024)

    describe "checkFileSize (gate A)" $ do
        it "rejects a reported size strictly above the limit with Just" $
            checkFileSize 10 (Just 11)
                `shouldBe` Just (FileSizeExceedsLimit 11 10)

        it "accepts a reported size below the limit with Nothing" $
            checkFileSize 10 (Just 9) `shouldBe` Nothing

        it "accepts a reported size exactly equal to the limit with Nothing" $
            checkFileSize 10 (Just 10) `shouldBe` Nothing

        it "accepts an unknown reported size (Nothing) with Nothing" $
            checkFileSize 10 Nothing `shouldBe` Nothing

        it "rejects a size one byte above the real Telegram limit" $
            checkFileSize
                telegramMaxDownloadBytes
                (Just (telegramMaxDownloadBytes + 1))
                `shouldBe` Just
                    (FileSizeExceedsLimit (telegramMaxDownloadBytes + 1) telegramMaxDownloadBytes)

    describe "checkDownloadedBytes (gate B)" $ do
        it "rejects a payload longer than the limit with Left of the actual length" $
            checkDownloadedBytes 10 (BS.replicate 11 0x41)
                `shouldBe` Left (FileSizeExceedsLimit 11 10)

        it "accepts a payload shorter than the limit and returns the same bytes" $ do
            let bytes = BS.replicate 9 0x42
            checkDownloadedBytes 10 bytes `shouldBe` Right bytes

        it "accepts a payload exactly equal to the limit and returns the same bytes" $ do
            let bytes = BS.replicate 10 0x43
            checkDownloadedBytes 10 bytes `shouldBe` Right bytes

    describe "size spoofing" $
        it "gate B catches an oversized payload that passed gate A on an under-reported size" $ do
            let limit = telegramMaxDownloadBytes
                spoofedBytes = BS.replicate (fromIntegral (limit + 1)) 0x64
            checkFileSize limit (Just 3) `shouldBe` Nothing
            checkDownloadedBytes limit spoofedBytes
                `shouldBe` Left (FileSizeExceedsLimit (limit + 1) limit)

    describe "fileSha256Hex" $ do
        it "is stable for identical input bytes" $
            fileSha256Hex "pay" `shouldBe` fileSha256Hex (BS.pack [0x70, 0x61, 0x79])

        it "produces exactly 64 hex characters" $
            T.length (fileSha256Hex "abc") `shouldBe` 64

        it "hashes the empty input to the known SHA-256 vector" $
            fileSha256Hex ""
                `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        it "hashes \"abc\" to the known SHA-256 vector" $
            fileSha256Hex "abc"
                `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
