-- | Pure chunking of long texts into Telegram-message-sized pieces.
--
-- The Bot API rejects a message whose text exceeds 4096 UTF-16 code units, so
-- texts that may run longer must be cut before being sent one chunk per
-- message. Cutting here is lossless and prefers natural boundaries: the last
-- newline of each window, then the last space, and only then a hard cut.
--
-- Lengths are counted in code points ('T.length'), not UTF-16 code units; see
-- 'splitTelegramText' for the caveat.
module LazyCircus.Telegram.LongText (
    telegramMessageChunkLimit,
    splitTelegramText,
) where

import Data.Text qualified as T
import RIO

-- | Chunk length limit for a single Telegram text message: 4000 code points
--   ('T.length'), safely under the Bot API's 4096-unit wire limit so a chunk
--   never needs further trimming.
telegramMessageChunkLimit :: Int
telegramMessageChunkLimit = 4000

{- | Split a text into chunks of at most 'telegramMessageChunkLimit' code
points each, cutting at a natural boundary inside every limit-sized window:
the LAST newline of the window (kept at the end of the chunk), falling back
to the LAST space (also kept at the chunk end), and only hard-cutting at
exactly 'telegramMessageChunkLimit' code points when the window has neither.
Each remainder is split the same way until nothing is left.

PRE-CONTRACT: None.
POST-CONTRACT: Lossless — @mconcat ('splitTelegramText' t) == t@ for every
input; the empty input yields the single chunk @[""]@, and non-empty input
never yields @[]@. Every chunk is at most 'telegramMessageChunkLimit' code
points long. Caveat: lengths are code points ('T.length'), not UTF-16 code
units, so text heavy in astral-plane characters (e.g. emoji) may still exceed
Telegram's wire limit even when every chunk respects this bound; no UTF-16
logic is performed.
-}
splitTelegramText :: Text -> [Text]
splitTelegramText txt
    | T.length txt <= telegramMessageChunkLimit = [txt]
    | otherwise =
        let (chunk, rest) = splitAtBoundary txt
         in chunk : splitTelegramText rest

-- | Cut a longer-than-limit text into @(chunk, rest)@ at a natural boundary
--   inside the limit-sized window: the LAST newline in the window (kept at
--   the end of the chunk), falling back to the LAST space (also kept at the
--   chunk end), and only hard-cutting at exactly
--   'telegramMessageChunkLimit' when the window has neither.
-- PRE-CONTRACT: The input is longer than 'telegramMessageChunkLimit' code
-- points.
-- POST-CONTRACT: Lossless — @chunk <> rest == input@; the chunk is non-empty
-- and at most 'telegramMessageChunkLimit' code points long; the rest is
-- strictly shorter than the input.
splitAtBoundary :: Text -> (Text, Text)
splitAtBoundary txt
    | not (T.null nlCut) = (nlCut, nlRest <> rest)
    | not (T.null spCut) = (spCut, spRest <> rest)
    | otherwise = (window, rest)
  where
    -- | The first at-most-limit window of the input and everything after it.
    (window, rest) = T.splitAt telegramMessageChunkLimit txt
    -- | Cut at the last newline of the window, newline kept in the chunk.
    (nlCut, nlRest) = T.breakOnEnd "\n" window
    -- | Cut at the last space of the window, space kept in the chunk.
    (spCut, spRest) = T.breakOnEnd " " window
