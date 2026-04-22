{-# LANGUAGE DataKinds #-}

module LazyCircus.Base64 where

import Data.Base64.Types
import Data.ByteString.Base64
import Data.ByteString.Base64.URL qualified as B64U

-- import Data.Text.Encoding qualified as T
import RIO

-- | Typed standard padded Base64 text used by backend domain values.
type B64 = Base64 'StdPadded Text

{- | Decode validated standard padded Base64 text into raw bytes.
PRE-CONTRACT: Accepts a typed Base64 payload that is already known to satisfy the standard padded Base64 format.
POST-CONTRACT: Returns the decoded bytes without additional validation failures.
-}
decodeBase64' :: B64 -> ByteString
decodeBase64' = decodeBase64 . fmap encodeUtf8

{- | Decode untyped standard padded Base64 text into raw bytes.
PRE-CONTRACT: Accepts arbitrary text that is expected to contain standard padded Base64 data.
POST-CONTRACT: Returns either the decoded bytes or the decoder error rendered as text.
-}
decodeBase64Untyped' :: Text -> Either Text ByteString
decodeBase64Untyped' = decodeBase64Untyped . encodeUtf8

{- | Decode untyped URL-safe unpadded Base64 text into raw bytes.
PRE-CONTRACT: Accepts arbitrary text that is expected to contain URL-safe unpadded Base64 data.
POST-CONTRACT: Returns either the decoded bytes or the decoder error rendered as text.
-}
decodeBase64UUntyped' :: Text -> Either Text ByteString
decodeBase64UUntyped' = B64U.decodeBase64UnpaddedUntyped . encodeUtf8
