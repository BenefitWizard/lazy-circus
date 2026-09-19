{- |
Step-pattern matcher for the BDD runner, used to bind scenario step texts to
registered step patterns. Entirely pure.

A 'Pattern' is either a 'Template' — step text interleaved with quoted
parameter spans — or a 'Literal' that must equal the step text exactly. In a
template both straight double quotes @\"...\"@ and guillemets @«...»@ open a
parameter span: the text inside the quotes is the parameter /name/, and the
span matches a value wrapped in a pair of matching quote characters in the
step text — either style, regardless of the style the span itself uses.
The captured value is the text strictly between the quotes — non-empty and
itself free of quote characters (the first closer ends the capture). For
example, the template @the user "name" has role "role"@ matches the step text
@the user "alice" has role "admin"@ and captures @("name", "alice")@ and
@("role", "admin")@, while the unquoted step @the user alice has role admin@
does not match. A 'Literal' captures nothing and treats quote characters as
ordinary characters — use it for step texts that contain quotes verbatim.

Before matching, both the pattern and the step text are whitespace-normalized:
every run of spaces\/tabs collapses to a single space and both ends are
trimmed. All template text outside quoted spans must match literally after
normalization; quoted boundaries do not glue — quote characters survive
normalization, so whitespace collapsing never merges text across a quoted
span.

An unterminated quoted span in the template (an opening @\"@ or @«@ with no
matching closer) is not an error: the opening character and the rest of the
template are matched literally, quote character included.

Determinism across several patterns lives at the registry level, not here:
'matchStep' tests a single pattern, and 'matchAll' reports every registered
pattern that matches so callers can inspect which patterns match a step.
-}
module LazyCircus.Testing.Bdd.Pattern
    ( -- * Pattern types
      Pattern (..)
    , patternSource
    , duplicateParamNames
    , ParamName
    , ParamValue
      -- * Captured parameters
    , StepParams
    , lookupParam
      -- * Matching
    , matchStep
    , matchAll
    ) where

import Data.Text qualified as T
import RIO

--------------------------------------------------------------------------------
-- Pattern types
--------------------------------------------------------------------------------

-- | A step pattern: a 'Template' whose quoted parameter spans capture values
-- quoted in the step text, or a 'Literal' matched exactly.
data Pattern
    = Template Text -- ^ pattern source text; quoted spans (@\"name\"@, @«name»@) name captured parameters
    | Literal Text  -- ^ exact step text; quote characters are ordinary characters, nothing is captured
    deriving (Show, Eq)

-- | String literals denote 'Template' patterns, so @OverloadedStrings@
-- pattern literals keep compiling unchanged.
instance IsString Pattern where
    fromString = Template . T.pack

-- | Name of a captured parameter: the text inside the quoted span of a
-- template.
type ParamName = Text

-- | Value of a captured parameter: the step text matched by the quoted span,
-- without the surrounding quotes.
type ParamValue = Text

-- | Captured step parameters of one matched pattern: name\/value pairs in the
-- order the quoted spans appear in the pattern (as produced by 'matchStep').
type StepParams = [(ParamName, ParamValue)]

--------------------------------------------------------------------------------
-- Pattern inspection
--------------------------------------------------------------------------------

-- | Renders the pattern back to its source text: a 'Template' reproduces its
-- quoted spans as written, a 'Literal' renders verbatim.
-- POST-CONTRACT: For a pattern built from a string literal via 'fromString',
-- the result equals that literal.
patternSource :: Pattern -> Text
patternSource (Template t) = t
patternSource (Literal t) = t

-- | Names of the parameters occurring more than once in the pattern, in the
-- order of their second occurrence. A 'Literal' captures nothing and always
-- yields the empty list.
-- POST-CONTRACT: Each duplicated name is listed exactly once.
duplicateParamNames :: Pattern -> [ParamName]
duplicateParamNames (Literal _) = []
duplicateParamNames (Template t) = collect [] [] (parseSegments t)
  where
    -- | Folds the template's capture names into the duplicate list in scan
    -- order.
    collect _ dups [] = reverse dups
    collect seen dups (Capture name : segs)
        | name `elem` seen, name `notElem` dups = collect seen (name : dups) segs
        | name `notElem` seen = collect (name : seen) dups segs
        | otherwise = collect seen dups segs
    collect seen dups (Lit _ : segs) = collect seen dups segs

--------------------------------------------------------------------------------
-- Captured parameters
--------------------------------------------------------------------------------

-- | Looks up one captured parameter of a matched pattern.
--
-- PRE-CONTRACT: Called only for a step whose pattern matched, so the name is
-- present in params.
-- POST-CONTRACT: 'Nothing' only for a name the pattern does not contain.
lookupParam :: ParamName -> StepParams -> Maybe ParamValue
lookupParam name params = lookup name params

--------------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------------

-- | Matches a step text against a single pattern.
--
-- A 'Template' matches when its literal text matches the normalized step
-- verbatim and every quoted span (@\"...\"@, @«...»@) matches a step value
-- wrapped in a pair of matching quote characters — either straight double
-- quotes or guillemets, regardless of the style the span uses; the captured
-- value is the non-empty text between the quotes, without the quotes. A
-- 'Literal' matches when the normalized step equals the literal exactly and
-- captures nothing. Both the pattern and the step text are
-- whitespace-normalized first (runs of spaces\/tabs collapse to a single
-- space, both ends trimmed).
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On 'Just', parameters are listed in the order their quoted
-- spans appear in the pattern, and every captured value is non-empty. Returns
-- 'Nothing' on any literal mismatch, leftover step text, or a step value that
-- is missing, unterminated, or empty.
matchStep :: Pattern -> Text -> Maybe [(ParamName, ParamValue)]
matchStep (Literal text) step
    | normalize text == normalize step = Just []
    | otherwise = Nothing
matchStep (Template text) step =
    matchSegments (parseSegments (normalize text)) (normalize step)

-- | Returns the names of all patterns in the list that match the step text.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The result preserves the input order, and every returned
-- name satisfies 'matchStep'. Note that registry-level selection is NOT
-- first-match-wins: 'LazyCircus.Testing.Bdd.Step.matchingDefs' orders
-- 'Literal' matches ahead of 'Template' matches, so a non-empty 'matchAll'
-- result alone does not tell which definition a run executes.
matchAll :: [(Text, Pattern)] -> Text -> [Text]
matchAll registered step =
    [ name | (name, pat) <- registered, isJust (matchStep pat step) ]

--------------------------------------------------------------------------------
-- Pattern compilation
--------------------------------------------------------------------------------

-- | One component of a compiled pattern.
data Segment
    = Lit Text          -- ^ literal text to match verbatim
    | Capture ParamName -- ^ quoted span capturing a value quoted in the step text

-- | Collapses runs of spaces\/tabs to a single space and trims both ends.
normalize :: Text -> Text
normalize = T.unwords . T.words

-- | Splits a normalized template into literal and capture segments.
parseSegments :: Text -> [Segment]
parseSegments = go
  where
    -- | Scans for the next quoted-span opener.
    go t = case T.uncons t of
        Nothing -> []
        Just (c, rest)
            | c == '"' -> quoted '"' "\"" rest
            | c == '«' -> quoted '«' "»" rest
            | otherwise -> literal t

    -- | Splits a quoted span opened by @opener@ and closed by @close@; an
    -- unterminated opening quote, quote character included, matches literally.
    quoted opener close rest = case T.breakOn close rest of
        (name, after)
            | Just remainder <- T.stripPrefix close after -> Capture name : go remainder
            | otherwise -> [Lit (T.cons opener rest)]

    -- | Collects the literal run up to the next quote opener.
    literal t = Lit lit : go rest
      where
        (lit, rest) = T.break (\ch -> ch == '"' || ch == '«') t

-- | Matches compiled pattern segments against the normalized step text.
matchSegments :: [Segment] -> Text -> Maybe [(ParamName, ParamValue)]
matchSegments [] t
    | T.null t = Just []
    | otherwise = Nothing
matchSegments (Lit l : segs) t = do
    t' <- T.stripPrefix l t
    matchSegments segs t'
matchSegments (Capture name : segs) t = do
    (opener, body) <- T.uncons t
    (value, rest) <- splitCapture opener body
    params <- matchSegments segs rest
    pure ((name, value) : params)

-- | Splits a quoted capture opened by @opener@ off the front of a step text:
-- the value is the text up to the matching closer (never containing the
-- closer), the closer is consumed.
-- POST-CONTRACT: 'Nothing' when @opener@ is not a quote character (@\"@ or
-- @«@), the step text has no matching closer, or the captured value would be
-- empty.
splitCapture :: Char -> Text -> Maybe (ParamValue, Text)
splitCapture opener body = do
    close <- closerFor opener
    let (value, after) = T.break (== close) body
    rest <- T.stripPrefix (T.singleton close) after
    if T.null value then Nothing else Just (value, rest)
  where
    -- | The step-side closer of a quoted capture, per pattern-side opener.
    closerFor '"' = Just '"'
    closerFor '«' = Just '»'
    closerFor _ = Nothing
