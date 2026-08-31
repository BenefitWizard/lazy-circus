{- |
Step-pattern matcher for the BDD runner, used to bind scenario step texts to
registered step patterns. Entirely pure.

A pattern is step text interleaved with quoted parameter spans. Both straight
double quotes @\"...\"@ and guillemets @«...»@ open a parameter span: the text
inside the quotes is the parameter /name/, and the span matches arbitrary
non-empty text in the step, which is captured as the parameter /value/. For
example, the pattern @the user "name" has role "role"@ matches the step text
@the user alice has role admin@ and captures @("name", "alice")@ and
@("role", "admin")@.

Before matching, both the pattern and the step text are whitespace-normalized:
every run of spaces\/tabs collapses to a single space and both ends are
trimmed. All pattern text outside quoted spans must match literally after
normalization. A quoted span never matches an empty fragment: it always
captures at least one character.

An unterminated quoted span in the pattern (an opening @\"@ or @«@ with no
matching closer) is not an error: the opening character and the rest of the
pattern are matched literally.

Determinism across several patterns lives at the registry level, not here:
'matchStep' tests a single pattern, and 'matchAll' reports every registered
pattern that matches so callers (and the meta-test) can detect ambiguity.
-}
module LazyCircus.Testing.Bdd.Pattern
    ( -- * Pattern types
      Pattern
    , ParamName
    , ParamValue
      -- * Matching
    , matchStep
    , matchAll
    ) where

import Data.Text qualified as T
import RIO

--------------------------------------------------------------------------------
-- Pattern types
--------------------------------------------------------------------------------

-- | A step pattern: literal text interleaved with quoted parameter spans
-- (@\"...\"@ or @«...»@).
type Pattern = Text

-- | Name of a captured parameter: the text inside the quoted span of the
-- pattern.
type ParamName = Text

-- | Value of a captured parameter: the step text matched by the quoted span.
type ParamValue = Text

--------------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------------

-- | Matches a step text against a single pattern.
--
-- Quoted spans in the pattern — @\"...\"@ and @«...»@ — capture parameters:
-- the quoted text is the parameter name and matches arbitrary text in the
-- step; all remaining pattern text must match literally. Both the pattern and
-- the step text are whitespace-normalized first (runs of spaces\/tabs
-- collapse to a single space, both ends trimmed).
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On 'Just', parameters are listed in the order their quoted
-- spans appear in the pattern, and every captured value is non-empty. Returns
-- 'Nothing' on any literal mismatch, leftover step text, or empty capture.
-- When captures are ambiguous the split is deterministic: every span captures
-- the shortest text that lets the rest of the pattern match.
matchStep :: Pattern -> Text -> Maybe [(ParamName, ParamValue)]
matchStep pat step = matchSegments (parseSegments (normalize pat)) (normalize step)

-- | Ambiguity probe: returns the names of all registered patterns matching
-- the step text, in registration order. The first element is the pattern a
-- first-match-wins registry would select; two or more elements flag an
-- ambiguous registration.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The result preserves the registration order of the input
-- list, and every returned name satisfies @'matchStep' pattern step /=
-- 'Nothing'@ for its pattern.
matchAll :: [(Text, Pattern)] -> Text -> [Text]
matchAll registered step =
    [ name | (name, pat) <- registered, isJust (matchStep pat step) ]

--------------------------------------------------------------------------------
-- Pattern compilation
--------------------------------------------------------------------------------

-- | One component of a compiled pattern.
data Segment
    = Lit Text          -- ^ literal text to match verbatim
    | Capture ParamName -- ^ quoted span capturing non-empty step text

-- | Collapses runs of spaces\/tabs to a single space and trims both ends.
normalize :: Text -> Text
normalize = T.unwords . T.words

-- | Splits a normalized pattern into literal and capture segments.
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
matchSegments (Capture name : segs) t = tryLengths [1 .. T.length t]
  where
    -- | Tries capture lengths shortest first; the remainder of the step must
    -- be matched by the rest of the pattern.
    tryLengths [] = Nothing
    tryLengths (n : ns)
        | Just params <- matchSegments segs (T.drop n t) = Just ((name, T.take n t) : params)
        | otherwise = tryLengths ns
