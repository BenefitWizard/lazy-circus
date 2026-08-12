module LazyCircus.AI.POML where

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
renderPOMLTag (ExampleSet ExampleSetParams{} examples) =
    renderTag "examples" [] (renderItems "example" [] examples)
renderPOMLTag (Example ExampleParams{} content) =
    renderTag "example" [] (concatMap renderPOMLTag content)
renderPOMLTag (Role RoleParams{} content) =
    renderTag "role" [] (concatMap renderPOMLTag content)
renderPOMLTag (Task TaskParams{} content) =
    renderTag "task" [] (concatMap renderPOMLTag content)
renderPOMLTag (Table TableParams{} table) =
    renderTag "table" [("syntax", syntaxFromTable table)] [renderTable table]
renderPOMLTag (Var n) = ["{{" <> n <> "}}"]
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

renderTag :: Text -> [(Text, Text)] -> [Text] -> [Text]
renderTag tag attrs content = openTag tag attrs <> content <> closeTag tag

renderAttribute :: (Text, Text) -> Text
renderAttribute (k, v) = " " <> k <> "=\"" <> v <> "\""

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
