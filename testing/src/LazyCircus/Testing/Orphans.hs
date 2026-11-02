{-# LANGUAGE NoImplicitPrelude #-}

-- | Orphan instances for external Telegram types the testing toolkit needs.
--
-- Dedicated module per the project's orphan-placement rule: the instance
-- lives in its own file that is guaranteed to be imported —
-- "LazyCircus.Testing.Bdd.Journal" imports it explicitly, so everything
-- downstream of the journal (the test performer, the BDD steps, the specs)
-- sees the instance transitively.
module LazyCircus.Testing.Orphans () where

import RIO

import Telegram.Bot.API.Types (ReactionType (..))

-- | ORPHAN: ReactionType is from telegram-bot-api (which ships 'Show' but no
-- 'Eq'), Eq is from base.
-- LAW: reflexivity / symmetry / transitivity: hold — constructor-wise record
-- equality over the 'Text' fields; different constructors are never equal.
instance Eq ReactionType where
    a == b = case (a, b) of
        ( ReactionTypeEmoji{reactionTypeEmojiType = type1, reactionTypeEmojiEmoji = emoji1}
            , ReactionTypeEmoji{reactionTypeEmojiType = type2, reactionTypeEmojiEmoji = emoji2}
            ) -> type1 == type2 && emoji1 == emoji2
        ( ReactionTypeCustomEmoji{reactionTypeCustomEmojiType = type1, reactionTypeCustomEmojiCustomEmojiId = customId1}
            , ReactionTypeCustomEmoji{reactionTypeCustomEmojiType = type2, reactionTypeCustomEmojiCustomEmojiId = customId2}
            ) -> type1 == type2 && customId1 == customId2
        _ -> False
