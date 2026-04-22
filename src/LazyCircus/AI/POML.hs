module LazyCircus.AI.POML where

import LazyCircus.AI.POML.Table (renderTable, syntaxFromTable)
import LazyCircus.AI.POML.Types
import RIO

-- | Render a list of POML nodes into the prompt text sent to the AI client.
renderPOMLtoPrompt :: [POML] -> Text
renderPOMLtoPrompt poml = mconcat $ concatMap renderPOMLTag poml

renderPOMLTag :: POML -> [Text]
renderPOMLTag (Text t) = [t]
renderPOMLTag (CP CPParams{cpCaption = caption} children) =
    renderTag "cp" [("caption", caption)] (concatMap renderPOMLTag children)
renderPOMLTag (List ListParams{} children) =
    renderTag "list" [] (renderItems "item" [] children)
renderPOMLTag (ExampleInput ExampleInputParams{} content) =
    renderTag "example_input" [] (concatMap renderPOMLTag content)
renderPOMLTag (ExampleOutput ExampleOutputParams{} content) =
    renderTag "example_output" [] (concatMap renderPOMLTag content)
renderPOMLTag (ExampleSet ExampleSetParams{} examples) =
    renderTag "examples" [] (renderItems "example" [] examples)
renderPOMLTag (Role RoleParams{} content) =
    renderTag "role" [] (concatMap renderPOMLTag content)
renderPOMLTag (Task TaskParams{} content) =
    renderTag "task" [] (concatMap renderPOMLTag content)
renderPOMLTag (Table TableParams{} table) =
    renderTag "table" [("syntax", syntaxFromTable table)] [renderTable table]
renderPOMLTag (Var _) = ["{{var}}"]

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
