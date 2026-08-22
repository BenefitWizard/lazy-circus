-- | Pure size gates for Telegram file downloads, plus a SHA-256 utility.
--
-- Note: the Bot API @File@ object carries only id \/ unique_id \/ size \/ path.
-- It has no MIME type and no file name, so format validation is downstream,
-- scenario-level, and decided from the downloaded bytes; this module guards
-- sizes only.
--
-- Two gates are provided. Gate A ('checkFileSize') inspects the
-- server-reported @file_size@ before downloading; gate B
-- ('checkDownloadedBytes') inspects the actual downloaded byte length and is
-- authoritative. 'fileSha256Hex' is an unrelated utility for scenario-level
-- logging and deduplication.
module LazyCircus.Telegram.FileCheck (
    FileValidationError (..),
    telegramMaxDownloadBytes,
    checkFileSize,
    checkDownloadedBytes,
    fileSha256Hex,
) where

import Crypto.Hash (SHA256 (..), hashWith)
import RIO
import RIO.ByteString qualified as BS

-- | Size-gate rejection for a Telegram file that is too large to download.
data FileValidationError
    = FileSizeExceedsLimit Integer Integer -- ^ actual size in bytes, limit in bytes
    deriving (Show, Eq)

-- | Telegram Bot API hard limit for downloading files: 20 MiB.
telegramMaxDownloadBytes :: Integer
telegramMaxDownloadBytes = 20 * 1024 * 1024

{- | Gate A: check the server-reported file size (from the @getFile@ response)
against the limit before downloading.
A missing size (@Nothing@) means unknown, not forbidden: it passes through so
gate B ('checkDownloadedBytes') decides on the actual bytes. Unknown size is
never treated as zero bytes.
PRE-CONTRACT: The limit is non-negative.
POST-CONTRACT: Returns @Just (FileSizeExceedsLimit actual limit)@ only when the
reported size strictly exceeds the limit; a size within or equal to the limit,
or an unknown size, yields @Nothing@.
-}
checkFileSize :: Integer -> Maybe Integer -> Maybe FileValidationError
checkFileSize limit (Just size)
    | size > limit = Just (FileSizeExceedsLimit size limit)
    | otherwise = Nothing
checkFileSize _ Nothing = Nothing

{- | Gate B: check the actual downloaded byte length against the limit.
This gate is authoritative: even if the server under-reported the size, the
real byte length decides.
PRE-CONTRACT: The limit is non-negative.
POST-CONTRACT: @Right bytes@ when the byte length is at most the limit;
@Left (FileSizeExceedsLimit actualLen limit)@ when it strictly exceeds it.
-}
checkDownloadedBytes :: Integer -> ByteString -> Either FileValidationError ByteString
checkDownloadedBytes limit bytes
    | actualLen > limit = Left (FileSizeExceedsLimit actualLen limit)
    | otherwise = Right bytes
  where
    -- | Real byte length of the payload.
    actualLen :: Integer
    actualLen = fromIntegral (BS.length bytes)

{- | SHA-256 digest of the payload rendered as lowercase hex text, for
scenario-level logging and deduplication. Rendering relies on crypton's
@Show (Digest a)@ instance, which prints the digest as lowercase hex.
POST-CONTRACT: Result has exactly 64 lowercase hex characters and is stable for
identical input bytes.
-}
fileSha256Hex :: ByteString -> Text
fileSha256Hex = tshow . hashWith SHA256
