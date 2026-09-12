module LazyCircus.AI.POML where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.Text qualified as T
import LazyCircus.AI.POML.Table (renderTable, syntaxFromTable)
import LazyCircus.AI.POML.Types
import RIO

-- | Render a list of POML nodes into the prompt text sent to the AI client.
renderPOMLtoPrompt :: [POML] -> Text
renderPOMLtoPrompt poml = mconcat $ concatMap renderPOMLTag poml

-- | Render a single POML node into one or more prompt-text fragments.
-- Handles every 'POML' constructor. Most block and inline nodes are emitted
-- as an open\/content\/close triple via 'renderTag'. The exceptions are:
--
--   * 'Text' — raw text, emitted as-is;
--   * 'Var' — a @{{name}}@ placeholder that preserves the variable name;
--   * 'Untrusted' — the payload isolated inside a protective markdown fence
--     (see 'renderUntrustedFence');
--   * 'Br' — the self-closing @<br\/>@ tag (no closing tag; it cannot use
--     'renderTag', which always emits a close);
--   * 'Fragment' — a transparent group, rendered as the concatenation of its
--     children (no wrapper tag).
renderPOMLTag :: POML -> [Text]
renderPOMLTag (Text t) = [t]
renderPOMLTag (CP CPParams{cpCaption = caption} children) =
    renderTag "cp" [("caption", caption)] (concatMap renderPOMLTag children)
renderPOMLTag (List ListParams{} children) =
    renderTag "list" [] (renderItems "item" [] children)
renderPOMLTag (ExampleInput ExampleInputParams{} content) =
    renderTag "input" [] (concatMap renderPOMLTag content)
renderPOMLTag (ExampleOutput ExampleOutputParams{} content) =
    renderTag "output" [] (concatMap renderPOMLTag content)
-- | Grouped example block (@<examples>@). The set-level caption is always
-- emitted as an attribute (per the spec it defaults to a visible
-- \"Examples\" header); an 'exampleSetIntroducer' is emitted only when
-- present. Each entry renders as its own @<example>@ tag, carrying a
-- @caption@ attribute when its caption differs from the default.
renderPOMLTag (ExampleSet ExampleSetParams{exampleSetCaption = setCaption, exampleSetIntroducer = mIntro} exampleEntries) =
    renderTag
        "examples"
        ( [("caption", setCaption)]
            <> maybe [] (\t -> [("introducer", t)]) mIntro
        )
        (concatMap renderExampleEntry exampleEntries)
  where
    -- | Renders one @(params, children)@ entry of an example set.
    renderExampleEntry (exampleParams, children) =
        renderTag "example" (exampleCaptionAttrs exampleParams) (concatMap renderPOMLTag children)
renderPOMLTag (Example params content) =
    renderTag "example" (exampleCaptionAttrs params) (concatMap renderPOMLTag content)
renderPOMLTag (Role RoleParams{} content) =
    renderTag "role" [] (concatMap renderPOMLTag content)
renderPOMLTag (Task TaskParams{} content) =
    renderTag "task" [] (concatMap renderPOMLTag content)
renderPOMLTag (Table TableParams{} table) =
    renderTag "table" [("syntax", syntaxFromTable table)] [renderTable table]
renderPOMLTag (Var n) = ["{{" <> n <> "}}"]
-- | Renders @type="untrusted"@ payload inside a protective markdown fence;
-- see the normative specification in
-- @docs\/plans\/2026-08-27-untrusted-fence.md@ (section 4).
renderPOMLTag (Untrusted t) = [renderUntrustedFence t]
-- Paragraph block (@<p>@).
renderPOMLTag (Paragraph children) =
    renderTag "p" [] (concatMap renderPOMLTag children)
-- Heading block (@<h level="n">@); 'Nothing' defaults the level to @"1"@.
renderPOMLTag (Heading mLevel children) =
    renderTag "h" [("level", maybe "1" tshow mLevel)] (concatMap renderPOMLTag children)
-- Code block without an explicit syntax (@<code>@).
renderPOMLTag (Code Nothing children) =
    renderTag "code" [] (concatMap renderPOMLTag children)
-- Code block with an explicit syntax attribute (@<code syntax="…">@).
renderPOMLTag (Code (Just syntax) children) =
    renderTag "code" [("syntax", syntax)] (concatMap renderPOMLTag children)
-- Strong (bold) inline node (@<b>@).
renderPOMLTag (Strong children) =
    renderTag "b" [] (concatMap renderPOMLTag children)
-- Italic inline node (@<i>@).
renderPOMLTag (Italic children) =
    renderTag "i" [] (concatMap renderPOMLTag children)
-- Underline inline node (@<u>@).
renderPOMLTag (Underline children) =
    renderTag "u" [] (concatMap renderPOMLTag children)
-- Strikethrough inline node (@<s>@).
renderPOMLTag (Strikethrough children) =
    renderTag "s" [] (concatMap renderPOMLTag children)
-- Generic inline span (@<span>@).
renderPOMLTag (Span children) =
    renderTag "span" [] (concatMap renderPOMLTag children)
-- Self-closing line break; emitted directly because 'renderTag' always adds a closing tag.
renderPOMLTag Br = ["<br/>"]
-- Transparent group: rendered as the concatenation of its children (no wrapper).
renderPOMLTag (Fragment xs) = concatMap renderPOMLTag xs

{- | Render untrusted text inside a protective CommonMark fence whose length
exceeds every backtick run in the content, with a deterministic SHA-256 hash
marker (first 8 lowercase-hex characters) in the opening fence's info-string.
Implements the normative fence specification of
@docs\/plans\/2026-08-27-untrusted-fence.md@ (section 4).
POST-CONTRACT: No line of @t@ can close the fence — every interior backtick run
is strictly shorter than the fence length, and the @\"\\n\"@ before the closing
fence separates it from trailing content backticks. Deterministic: identical
input yields identical output.
-}
renderUntrustedFence :: Text -> Text
renderUntrustedFence t = fence <> marker <> "\n" <> T.stripEnd t <> "\n" <> fence
  where
    -- | Fence length: one more than any backtick run in the content, but at
    -- least CommonMark's minimum of 3.
    fenceLen = max 3 (longestBacktickRun t + 1)
    -- | Attention anchor: first 8 characters of the SHA-256 digest hex.
    marker = T.take 8 (sha256Hex t)
    -- | Backtick fence; CommonMark forbids an info-string on the closer.
    fence = T.replicate fenceLen "`"

-- | Length of the longest run of consecutive backticks anywhere in the text,
-- computed in a single linear pass ('T.foldl'' over current and maximal run).
-- Runs are measured anywhere in the text, which is more conservative than
-- CommonMark (which only needs runs at line starts).
-- POST-CONTRACT: Empty text yields 0.
longestBacktickRun :: Text -> Int
longestBacktickRun = snd . T.foldl' step (0 :: Int, 0 :: Int)
  where
    -- | Extend ('`') or reset (any other character) the current run,
    -- carrying the maximum seen so far.
    step (currentRun, maxRun) '`' =
        let currentRun' = currentRun + 1 in (currentRun', max currentRun' maxRun)
    step (_, maxRun) _ = (0, maxRun)

-- | SHA-256 digest of the UTF-8 encoded text rendered as 64 lowercase hex
-- characters; the lowercasing comes for free from crypton's
-- @Show (Digest a)@ instance.
-- POST-CONTRACT: Result is stable for identical input text.
sha256Hex :: Text -> Text
sha256Hex = tshow . hashWith SHA256 . encodeUtf8

-- | Caption attribute of an @<example>@ tag. Per the spec an example's
-- caption is hidden by default, so the attribute is emitted only when the
-- caption differs from the default @\"Example\"@.
-- POST-CONTRACT: For 'defaultExampleParams' the result is empty.
exampleCaptionAttrs :: ExampleParams -> [(Text, Text)]
exampleCaptionAttrs ExampleParams{exampleCaption = cap}
    | cap /= "Example" = [("caption", cap)]
    | otherwise = []

renderTag :: Text -> [(Text, Text)] -> [Text] -> [Text]
renderTag tag attrs content = openTag tag attrs <> content <> closeTag tag

-- | Renders one key-value pair as a quoted XML-style attribute.
-- POST-CONTRACT: The value is escaped ('escapeAttrValue'), so any 'Text'
-- value yields well-formed attribute output.
renderAttribute :: (Text, Text) -> Text
renderAttribute (k, v) = " " <> k <> "=\"" <> escapeAttrValue v <> "\""

-- | Escapes the XML special characters of an attribute value: @&@, @<@,
-- @>@ and @\"@. @&@ is replaced first, so replacement entities are never
-- re-escaped.
-- POST-CONTRACT: Idempotent input yields well-formed output; escaping is
-- deterministic and injective on 'Text'.
escapeAttrValue :: Text -> Text
escapeAttrValue =
    T.replace "\"" "&quot;"
        . T.replace ">" "&gt;"
        . T.replace "<" "&lt;"
        . T.replace "&" "&amp;"

openTag :: Text -> [(Text, Text)] -> [Text]
openTag tag attrs =
    let
        attrsT = map renderAttribute attrs
     in
        ["<", tag] <> attrsT <> [">"]

closeTag :: Text -> [Text]
closeTag tag = ["</" <> tag <> ">"]

renderItems :: Text -> [(Text, Text)] -> [[POML]] -> [Text]
renderItems tag attrs = concatMap (renderTag tag attrs . concatMap renderPOMLTag)
