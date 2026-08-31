{- |
Parser for a small Gherkin subset of @.feature@ documents, used by the BDD
runner. The parser is hand-written and string-oriented, and entirely pure:
'parseFeature' never touches 'IO'.

Supported grammar:

  * a single @Feature:@ header with a name, followed by an optional
    multi-line description; the description runs until the first tag line or
    @Scenario:@ \/ @Scenario Outline:@ header (or step, which is an error);
  * tag lines (whitespace-separated words starting with @\@@) directly above
    the @Feature:@ header and above @Scenario:@ \/ @Scenario Outline:@
    headers; tags are carried verbatim (including the leading @\@@) in the AST;
  * @Scenario:@ with a name and a list of steps;
  * @Scenario Outline:@ with exactly one @Examples:@ block. The first
    @| ... |@ row of the block names the parameters, every following row
    expands into its own 'GherkinScenario' with @\<param\>@ placeholders
    substituted into the scenario name and into all step texts. Expanded
    scenarios keep the outline's tags and the source line of the outline
    header. Placeholders without a matching header column are left untouched;
  * steps starting with @Given@, @When@, @Then@, @And@, @But@. @And@ and
    @But@ inherit the previous resolved keyword, and the AST stores only
    resolved keywords ('GherkinKeyword');
  * full-line comments (first non-space character @#@) and empty lines are
    ignored everywhere, including inside @Examples:@ blocks.

Not supported: step argument tables and doc strings, multiple @Examples:@
blocks per outline, @Background:@ \/ @Rule:@ sections, localized keywords,
trailing comments after step text.

All line numbers in the AST and in errors are 1-based. 'GherkinParseError'
is file-independent: the caller supplies the file name when rendering it.
-}
module LazyCircus.Testing.Bdd.Gherkin
    ( -- * Feature AST
      GherkinFeature (..)
    , GherkinScenario (..)
    , GherkinStep (..)
    , GherkinKeyword (..)
      -- * Parsing
    , parseFeature
    , GherkinParseError (..)
    , gherkinParseErrorLine
    , renderGherkinParseError
    ) where

import Data.Text qualified as T
import RIO

--------------------------------------------------------------------------------
-- AST
--------------------------------------------------------------------------------

-- | A resolved step keyword of the Gherkin subset. @And@\/@But@ never appear
-- here: during parsing they are resolved to the previous
-- @Given@\/@When@\/@Then@ they inherit from.
data GherkinKeyword
    = GivenKeyword  -- ^ a @Given@ step
    | WhenKeyword   -- ^ a @When@ step
    | ThenKeyword   -- ^ a @Then@ step
    deriving (Eq, Show)

-- | A single step of a scenario.
data GherkinStep = GherkinStep
    { gherkinStepKeyword :: GherkinKeyword -- ^ resolved keyword; @And@\/@But@ inherit the previous @Given@\/@When@\/@Then@
    , gherkinStepText    :: Text           -- ^ step text with the keyword stripped, trimmed
    , gherkinStepLine    :: Int            -- ^ 1-based source line of the step
    }
    deriving (Eq, Show)

-- | A scenario. A @Scenario Outline:@ with an @Examples:@ block expands into
-- one 'GherkinScenario' per data row: @\<param\>@ placeholders are substituted
-- into the name and into all step texts, and every expanded scenario keeps the
-- tags of the outline and the source line of its header.
data GherkinScenario = GherkinScenario
    { gherkinScenarioName  :: Text          -- ^ scenario name, after outline substitution
    , gherkinScenarioTags  :: [Text]        -- ^ tags as written, including the leading @\@@
    , gherkinScenarioSteps :: [GherkinStep] -- ^ steps in document order
    , gherkinScenarioLine  :: Int           -- ^ 1-based source line of the @Scenario:@\/@Scenario Outline:@ header
    }
    deriving (Eq, Show)

-- | A complete parsed feature document.
data GherkinFeature = GherkinFeature
    { gherkinFeatureName        :: Text             -- ^ text after @Feature:@, trimmed
    , gherkinFeatureTags        :: [Text]           -- ^ tags as written, including the leading @\@@
    , gherkinFeatureDescription :: [Text]           -- ^ free-form description lines (trimmed) between the @Feature:@ line and the first scenario
    , gherkinFeatureScenarios   :: [GherkinScenario] -- ^ scenarios in document order; @Scenario Outline:@ rows appear expanded
    }
    deriving (Eq, Show)

-- | Everything that can go wrong while parsing. Carries the 1-based line the
-- parser failed at plus an expectation message; the file name is supplied by
-- the caller (e.g. combined with 'renderGherkinParseError').
data GherkinParseError
    = GherkinStepOutsideScenario Int
      -- ^ a @Given@\/@When@\/@Then@\/@And@\/@But@ line appeared outside any scenario; carries its line
    | GherkinAndButBeforeStep Int
      -- ^ an @And@\/@But@ line appeared before any @Given@\/@When@\/@Then@ inside its scenario; carries its line
    | GherkinMissingScenarioName Int
      -- ^ a @Scenario:@\/@Scenario Outline:@ line with an empty name; carries the header line
    | GherkinMissingFeatureName Int
      -- ^ a @Feature:@ line with an empty name; carries the header line
    | GherkinExamplesWithoutHeader Int
      -- ^ an @Examples:@ block without a header row; carries the line of the @Examples:@ keyword
    | GherkinRowWidthMismatch Int
      -- ^ an @Examples:@ data row with a cell count different from the header row; carries the row line
    | GherkinUnexpected Int Text
      -- ^ any other malformed input; carries the source line and an expectation message
    deriving (Eq, Show)

--------------------------------------------------------------------------------
-- Parsing entry points
--------------------------------------------------------------------------------

-- | Parses a Gherkin-subset feature document into a 'GherkinFeature'.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns 'Left' with the first error encountered (scanning top
-- to bottom); on 'Right', every @Scenario Outline:@ appears expanded into one
-- 'GherkinScenario' per @Examples:@ data row, in document order. For an empty
-- document the reported line is 1.
parseFeature :: Text -> Either GherkinParseError GherkinFeature
parseFeature input = go emptyState (zip [1 ..] (T.lines input))
  where
    go st [] = finish st
    go st ((n, raw) : rest) = either Left (`go` rest) $ case classifyLine (T.strip raw) of
        LineBlank              -> Right st
        LineTags tagWords      -> handleTags n tagWords st
        LineFeature name       -> handleFeature n name st
        LineScenario rkg name  -> handleScenario n rkg name st
        LineExamples           -> handleExamples n st
        LineRow cells          -> handleRow n cells st
        LineStep rkw stepText  -> handleStep n rkw stepText st
        LineText other         -> handleText n other st

    -- | Finalizes the document at end of input.
    finish :: PState -> Either GherkinParseError GherkinFeature
    finish st0 = do
        st <- closeScenario st0
        case reverse (stTags st) of
            [] -> Right ()
            ((n, _) : _) -> Left (GherkinUnexpected n "Expected a tag attached to a Feature or Scenario")
        fa <- maybe (Left (GherkinUnexpected 1 "Expected a 'Feature:' line")) Right (stFeature st)
        Right
            GherkinFeature
                { gherkinFeatureName = faName fa
                , gherkinFeatureTags = faTags fa
                , gherkinFeatureDescription = reverse (faDescription fa)
                , gherkinFeatureScenarios = reverse (faScenarios fa)
                }

    -- | Registers tag words for the next @Feature:@\/@Scenario:@ header; a tag
    -- line also closes the previous scenario.
    handleTags :: Int -> [Text] -> PState -> Either GherkinParseError PState
    handleTags n tagWords st
        | any (not . T.isPrefixOf "@") tagWords = Left (GherkinUnexpected n "Expected a tag starting with '@'")
        | otherwise = do
            st' <- closeScenario st
            Right st' { stTags = foldl' (\acc w -> (n, w) : acc) (stTags st') tagWords }

    -- | Opens a feature; the description starts empty right after it.
    handleFeature :: Int -> Text -> PState -> Either GherkinParseError PState
    handleFeature n name st
        | T.null name = Left (GherkinMissingFeatureName n)
        | otherwise = do
            st' <- closeScenario st
            case stFeature st' of
                Just _ -> Left (GherkinUnexpected n "Expected a single 'Feature:' per document")
                Nothing -> Right st' { stFeature = Just (FeatureAcc name (map snd (reverse (stTags st'))) [] []), stTags = [] }

    -- | Opens a scenario or scenario outline.
    handleScenario :: Int -> Bool -> Text -> PState -> Either GherkinParseError PState
    handleScenario n outline name st
        | T.null name = Left (GherkinMissingScenarioName n)
        | otherwise = do
            st' <- closeScenario st
            _ <- requireFeature n st'
            Right
                st'
                    { stScenario = Just (ScenarioAcc name (map snd (reverse (stTags st'))) n outline [] Nothing)
                    , stLastKeyword = Nothing
                    , stTags = []
                    }

    -- | Opens the @Examples:@ block of the current scenario outline.
    handleExamples :: Int -> PState -> Either GherkinParseError PState
    handleExamples n st = case stScenario st of
        Nothing -> Left (GherkinUnexpected n "Expected a Scenario Outline, found 'Examples:'")
        Just sa
            | not (saOutline sa) -> Left (GherkinUnexpected n "'Examples:' is only valid inside a Scenario Outline")
            | Just _ <- saExamples sa -> Left (GherkinUnexpected n "Expected a single 'Examples:' block per Scenario Outline")
            | otherwise -> Right st { stScenario = Just sa { saExamples = Just (ExamplesAcc n Nothing []) } }

    -- | Ingests one @| ... |@ row: the first row is the header, the rest are
    -- data rows checked against the header width.
    handleRow :: Int -> [Text] -> PState -> Either GherkinParseError PState
    handleRow n cells st = case stScenario st of
        Nothing -> Left (GherkinUnexpected n "Expected an 'Examples:' block, found a table row")
        Just sa -> case saExamples sa of
            Nothing -> Left (GherkinUnexpected n "Expected an 'Examples:' block, found a table row")
            Just ea -> case eaHeader ea of
                Nothing -> Right st { stScenario = Just sa { saExamples = Just ea { eaHeader = Just cells } } }
                Just header
                    | length cells /= length header -> Left (GherkinRowWidthMismatch n)
                    | otherwise -> Right st { stScenario = Just sa { saExamples = Just ea { eaRows = cells : eaRows ea } } }

    -- | Appends one step, resolving @And@\/@But@ against the previous keyword.
    handleStep :: Int -> RawKeyword -> Text -> PState -> Either GherkinParseError PState
    handleStep n rkw stepText st = case stScenario st of
        Nothing -> Left (GherkinStepOutsideScenario n)
        Just sa
            | Just _ <- saExamples sa -> Left (GherkinUnexpected n "Expected a new Scenario, found a Step after an 'Examples:' block")
            | otherwise -> do
                kw <- resolveStep n rkw (stLastKeyword st)
                Right
                    st
                        { stScenario = Just sa { saSteps = GherkinStep kw stepText n : saSteps sa }
                        , stLastKeyword = Just kw
                        }

    -- | Collects a description line before the first scenario, or rejects it.
    handleText :: Int -> Text -> PState -> Either GherkinParseError PState
    handleText n txt st = case stScenario st of
        Just sa
            | Just _ <- saExamples sa -> Left (GherkinUnexpected n ("Expected a new Scenario, found: " <> txt))
            | otherwise -> Left (GherkinUnexpected n ("Expected a Step, found: " <> txt))
        Nothing -> case stFeature st of
            Nothing -> Left (GherkinUnexpected n ("Expected a 'Feature:' line, found: " <> txt))
            Just fa
                | null (faScenarios fa) -> Right st { stFeature = Just fa { faDescription = txt : faDescription fa } }
                | otherwise -> Left (GherkinUnexpected n ("Expected a Scenario or a tag, found: " <> txt))

    -- | Closes the currently open scenario, if any: a plain scenario is
    -- appended as a single 'GherkinScenario', a Scenario Outline is expanded
    -- into one scenario per @Examples:@ data row.
    closeScenario :: PState -> Either GherkinParseError PState
    closeScenario st = case stScenario st of
        Nothing -> Right st
        Just sa -> case saExamples sa of
            Nothing
                | saOutline sa -> Left (GherkinUnexpected (saLine sa) "Expected an 'Examples:' block in the Scenario Outline")
                | otherwise -> appendScenarios [GherkinScenario (saName sa) (saTags sa) (reverse (saSteps sa)) (saLine sa)] st
            Just ea -> case eaHeader ea of
                Nothing -> Left (GherkinExamplesWithoutHeader (eaLine ea))
                Just header -> appendScenarios (expandOutline sa header ea) st

    -- | Closes the scenario slot, resetting the last-keyword memory, and
    -- prepends the given scenarios (in document order) to the feature.
    appendScenarios :: [GherkinScenario] -> PState -> Either GherkinParseError PState
    appendScenarios scenarios st = case stFeature st of
        Nothing -> Right st
        Just fa ->
            Right
                st
                    { stScenario = Nothing
                    , stLastKeyword = Nothing
                    , stFeature = Just fa { faScenarios = reverse scenarios ++ faScenarios fa }
                    }

    -- | Fails unless a @Feature:@ header has been seen.
    requireFeature :: Int -> PState -> Either GherkinParseError FeatureAcc
    requireFeature n st = maybe (Left (GherkinUnexpected n "Expected a 'Feature:' line before any Scenario")) Right (stFeature st)

    -- | Resolves the written step keyword; @And@\/@But@ inherit the previous
    -- resolved keyword of their scenario.
    resolveStep :: Int -> RawKeyword -> Maybe GherkinKeyword -> Either GherkinParseError GherkinKeyword
    resolveStep _ RKGiven _ = Right GivenKeyword
    resolveStep _ RKWhen _ = Right WhenKeyword
    resolveStep _ RKThen _ = Right ThenKeyword
    resolveStep n RKAnd prev = maybe (Left (GherkinAndButBeforeStep n)) Right prev
    resolveStep n RKBut prev = maybe (Left (GherkinAndButBeforeStep n)) Right prev

    -- | Expands an outline scenario into one scenario per @Examples:@ data
    -- row, substituting @\<param\>@ placeholders in the name and step texts.
    -- Returns the scenarios in document order.
    expandOutline :: ScenarioAcc -> [Text] -> ExamplesAcc -> [GherkinScenario]
    expandOutline sa header ea =
        [ GherkinScenario
            { gherkinScenarioName = substituteParams (zip header cells) (saName sa)
            , gherkinScenarioTags = saTags sa
            , gherkinScenarioSteps =
                [ step { gherkinStepText = substituteParams (zip header cells) (gherkinStepText step) }
                | step <- reverse (saSteps sa)
                ]
            , gherkinScenarioLine = saLine sa
            }
        | cells <- reverse (eaRows ea)
        ]

    -- | Replaces every @\<param\>@ placeholder with its row value;
    -- placeholders without a matching parameter are left untouched.
    substituteParams :: [(Text, Text)] -> Text -> Text
    substituteParams params text = foldr (\(p, v) acc -> T.replace ("<" <> p <> ">") v acc) text params

--------------------------------------------------------------------------------
-- Parser state
--------------------------------------------------------------------------------

-- | Accumulated @Examples:@ block of the scenario currently being parsed.
data ExamplesAcc = ExamplesAcc
    { eaLine   :: Int        -- ^ line of the @Examples:@ keyword
    , eaHeader :: Maybe [Text] -- ^ header row = parameter names
    , eaRows   :: [[Text]]   -- ^ data rows in reverse order
    }

-- | Accumulated scenario (plain or outline).
data ScenarioAcc = ScenarioAcc
    { saName        :: Text               -- ^ header name, trimmed
    , saTags        :: [Text]             -- ^ tags preceding the header
    , saLine        :: Int                -- ^ line of the header
    , saOutline     :: Bool               -- ^ whether the header was @Scenario Outline:@
    , saSteps       :: [GherkinStep]      -- ^ steps in reverse order
    , saExamples    :: Maybe ExamplesAcc  -- ^ open or completed @Examples:@ block
    }

-- | Accumulated feature.
data FeatureAcc = FeatureAcc
    { faName        :: Text             -- ^ feature name, trimmed
    , faTags        :: [Text]           -- ^ tags preceding the header
    , faDescription :: [Text]           -- ^ description lines in reverse order
    , faScenarios   :: [GherkinScenario] -- ^ closed scenarios in reverse order
    }

-- | Parser state threaded over the source lines.
data PState = PState
    { stFeature     :: Maybe FeatureAcc     -- ^ feature opened by @Feature:@
    , stScenario    :: Maybe ScenarioAcc    -- ^ scenario currently open
    , stTags        :: [(Int, Text)]        -- ^ pending tags in reverse order, with their line
    , stLastKeyword :: Maybe GherkinKeyword -- ^ last resolved @Given@\/@When@\/@Then@ of the open scenario
    }

-- | Initial parser state.
emptyState :: PState
emptyState = PState Nothing Nothing [] Nothing

--------------------------------------------------------------------------------
-- Line classification
--------------------------------------------------------------------------------

-- | Step keyword exactly as written in the source; @And@\/@But@ are resolved
-- against the previous keyword later.
data RawKeyword
    = RKGiven
    | RKWhen
    | RKThen
    | RKAnd
    | RKBut

-- | Classification of a single (trimmed) source line.
data LineKind
    = LineBlank                 -- ^ empty line or full-line comment
    | LineTags [Text]           -- ^ whitespace-separated @\@@ tags
    | LineFeature Text          -- ^ @Feature:@ + name
    | LineScenario Bool Text    -- ^ @Scenario:@ (False) or @Scenario Outline:@ (True) + name
    | LineExamples              -- ^ @Examples:@
    | LineRow [Text]            -- ^ @| a | b |@ table row
    | LineStep RawKeyword Text  -- ^ step keyword + step text
    | LineText Text             -- ^ anything else: description or junk

-- | Classifies one trimmed source line.
classifyLine :: Text -> LineKind
classifyLine line
    | T.null line = LineBlank
    | "#" `T.isPrefixOf` line = LineBlank
    | "@" `T.isPrefixOf` line = LineTags (T.words line)
    | Just rest <- T.stripPrefix "Feature:" line = LineFeature (T.strip rest)
    | Just rest <- T.stripPrefix "Scenario Outline:" line = LineScenario True (T.strip rest)
    | Just rest <- T.stripPrefix "Scenario:" line = LineScenario False (T.strip rest)
    | Just _ <- T.stripPrefix "Examples:" line = LineExamples
    | Just (rkw, stepText) <- stepOf line = LineStep rkw stepText
    | "|" `T.isPrefixOf` line = LineRow (rowCells line)
    | otherwise = LineText line

-- | Recognizes a step line: one of the five keywords followed by whitespace
-- or end of line. Returns the written keyword and the trimmed step text.
stepOf :: Text -> Maybe (RawKeyword, Text)
stepOf line = foldr ((<|>) . match) Nothing keywords
  where
    -- | Matches one written keyword at the start of the line.
    match (written, rkw) = case T.stripPrefix written line of
        Just rest | T.null rest || T.isPrefixOf " " rest || T.isPrefixOf "\t" rest -> Just (rkw, T.strip rest)
        _ -> Nothing
    keywords =
        [ ("Given", RKGiven)
        , ("When", RKWhen)
        , ("Then", RKThen)
        , ("And", RKAnd)
        , ("But", RKBut)
        ]

-- | Splits a @| a | b |@ row into trimmed cells.
rowCells :: Text -> [Text]
rowCells row = map T.strip (dropLastEmpty (drop 1 (T.splitOn "|" row)))
  where
    -- | Drops the empty piece after the trailing @|@, when present.
    dropLastEmpty xs = case reverse xs of
        (y : ys) | T.null y -> reverse ys
        _ -> xs

--------------------------------------------------------------------------------
-- Error rendering
--------------------------------------------------------------------------------

-- | The 1-based source line the error refers to.
gherkinParseErrorLine :: GherkinParseError -> Int
gherkinParseErrorLine err = case err of
    GherkinStepOutsideScenario n -> n
    GherkinAndButBeforeStep n -> n
    GherkinMissingScenarioName n -> n
    GherkinMissingFeatureName n -> n
    GherkinExamplesWithoutHeader n -> n
    GherkinRowWidthMismatch n -> n
    GherkinUnexpected n _ -> n

-- | Renders the expectation message of an error, without file or line info;
-- the caller prefixes both.
renderGherkinParseError :: GherkinParseError -> Text
renderGherkinParseError err = case err of
    GherkinStepOutsideScenario _ -> "Expected a Step inside a Scenario, found a Step outside of any Scenario"
    GherkinAndButBeforeStep _ -> "Expected 'Given', 'When' or 'Then', found 'And'/'But' before any Step"
    GherkinMissingScenarioName _ -> "Expected a Scenario name after 'Scenario:'"
    GherkinMissingFeatureName _ -> "Expected a Feature name after 'Feature:'"
    GherkinExamplesWithoutHeader _ -> "Expected an 'Examples:' header row ('| param |'), found none"
    GherkinRowWidthMismatch _ -> "Expected an 'Examples:' row with as many cells as the header row"
    GherkinUnexpected _ msg -> msg
