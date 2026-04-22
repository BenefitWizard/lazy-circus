module LazyCircus.LangCode where

import Data.Aeson
import RIO

data LangCode
    = RU
    | EN
    | Default
    deriving (Eq, Show, Generic)

instance Hashable LangCode

-- | Payload wrapper that carries an explicit language code alongside a value.
data WithLangCode a = WithLangCode
    { langCode :: LangCode
    , value :: a
    }
    deriving (Show, Eq, Generic)

-- | Capability class for values that can reveal their effective language code.
class HasLangCode a where
    langCodeOf :: a -> LangCode

instance Semigroup LangCode where
    Default <> right = right
    left <> _ = left

instance Monoid LangCode where
    mempty = Default

instance ToJSON LangCode where
    toJSON RU = String "ru"
    toJSON EN = String "en"
    toJSON Default = Null

instance FromJSON LangCode where
    parseJSON (String "ru") = pure RU
    parseJSON (String "RU") = pure RU
    parseJSON (String "en") = pure EN
    parseJSON (String "EN") = pure EN
    parseJSON _ = pure Default

instance Display LangCode where
    display RU = "🇷🇺"
    display EN = "🇬🇧"
    display Default = "🏁"

instance HasLangCode LangCode where
    langCodeOf = id

instance HasLangCode (WithLangCode a) where
    langCodeOf = langCode

{- | Decode an optional textual language code into the backend domain value.
PRE-CONTRACT: Accepts optional Telegram- and persistence-style lowercase language tags; unsupported inputs are treated as 'Default'.
POST-CONTRACT: Returns 'RU' for "ru", 'EN' for "en", and 'Default' for missing or unknown values.
-}
fromMaybeText :: Maybe Text -> LangCode
fromMaybeText Nothing = Default
fromMaybeText (Just "ru") = RU
fromMaybeText (Just "en") = EN
fromMaybeText (Just _) = Default

{- | Render a language code into the optional lowercase text form used by integrations.
PRE-CONTRACT: None.
POST-CONTRACT: Returns 'Nothing' for 'Default' and lowercase ISO-like tags for concrete language choices.
-}
toMaybeText :: LangCode -> Maybe Text
toMaybeText Default = Nothing
toMaybeText RU = Just "ru"
toMaybeText EN = Just "en"

{- | Attach the language code of an existing value to a new payload.
PRE-CONTRACT: The source value must implement 'HasLangCode'.
POST-CONTRACT: Produces a 'WithLangCode' wrapper whose 'langCode' matches 'langCodeOf' for the source value.
-}
withLangCodeOf :: (HasLangCode a) => a -> b -> WithLangCode b
withLangCodeOf a = WithLangCode (langCodeOf a)
