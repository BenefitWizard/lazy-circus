module LazyCircus.AI.POML.Table (
    Table (CSV),
    CSVTableConstraint,
    renderTable,
    renderCSV,
    syntaxFromTable,
) where

--   PURPOSE: Render prompt-oriented table values into textual formats that can be embedded into POML documents.
--   SCOPE: Table format type, CSV row constraint alias, and helpers that render table payloads or expose their syntax labels.
--   DEPENDS: none

-- \| Table rendering helpers for prompt-oriented markup documents.

import Data.Csv
import Data.Text.Encoding (decodeUtf8)
import RIO
import RIO.Text qualified as Text

-- | Constraint alias for row types that can be rendered as named CSV tables.
type CSVTableConstraint a = (ToNamedRecord a, DefaultOrdered a)

-- | Table payload rendered either as CSV text or Markdown text.
data Table where
    CSV :: (CSVTableConstraint a) => [a] -> Table
    Markdown :: (CSVTableConstraint a) => [a] -> Table

-- | Render a table payload using the concrete text format selected by its constructor.
renderTable :: Table -> Text
renderTable (CSV rows) = renderCSV rows
renderTable (Markdown rows) = renderMarkdown rows

renderCSV :: (CSVTableConstraint a) => [a] -> Text
renderCSV rows =
    encodeDefaultOrderedByName rows
        & toStrictBytes
        & decodeUtf8

-- | Return the syntax label used to serialize a table payload inside POML tags.
syntaxFromTable :: Table -> Text
syntaxFromTable (CSV _) = "csv"
syntaxFromTable (Markdown _) = "markdown"

renderMarkdown :: forall a. (CSVTableConstraint a) => [a] -> Text
renderMarkdown _rows =
    Text.unlines [header, separator, "<markdown table body not yet implemented>"]
  where
    rawHeader = headerOrder (undefined :: a)
    headerSize = length rawHeader
    header =
        Text.unwords $
            ["| "]
                <> (fmap (\h -> h <> " | " & decodeUtf8) rawHeader & toList)
                <> ["|"]
    separator = ["|"] <> replicate headerSize "--- |" & Text.unwords
