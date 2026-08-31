{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE StrictData #-}

{- | Observation journal for Lazy Circus scenario tests.

An 'ObservationLog' is an append-only, STM-transactional record of the side
effects a scenario produced, written by the test performer
("LazyCircus.Testing.Performer") while the scenario runs. Unlike the
performer's drainable capture buffers (owned by 'LazyCircus.Testing.Performer.Mocks'),
the journal is caller-owned: it travels in the 'LazyCircus.Testing.Performer.TestConfig'
via @tcJournal@, and every Telegram observation is appended in the /same/ STM
transaction that publishes the corresponding outgoing-mailbox message, so the
journal snapshot and the mailbox can never disagree.
--
-- On top of the raw journal, 'ScenarioState' carries a caller-owned consumed
-- set that BDD steps grow via 'awaitObservation': waits are selective,
-- unconsumed entries stay available to later waits regardless of what earlier
-- waits skipped, and the timeout is the only source of non-determinism.
-}
module LazyCircus.Testing.Bdd.Journal
    ( Observation (..)
    , Sequenced (..)
    , ObservationLog (..)
    , newObservationLog
    , appendObservation
    , readObservations
    , AwaitTimeout (..)
    , defaultAwaitBudgetUs
    , DialogState (..)
    , emptyDialogState
    , ScenarioState (..)
    , newScenarioState
    , freshScenarioState
    , ssLastConsumed
    , awaitObservation
    , peekLastConsumed
    ) where

import RIO
import RIO.Set (Set)
import RIO.Set qualified as Set

import Control.Concurrent.STM (retry)
import Data.List (find)

import Telegram.Bot.API (ChatId, SomeReplyMarkup)
import Telegram.Bot.API.Types (FileId, MessageId)

-- | One observed side effect of a scenario run, expressed in the testing
-- library's shared vocabulary.
--
-- THE BLESSING RULE: a new library constructor is added to this type only when
-- an observation shape has survived at least two different scenarios through
-- the app hooks (@tcMailHook@ / @tcAiHook@ in
-- "LazyCircus.Testing.Performer"). App-specific observations that have not yet
-- earned a library constructor stay in 'ObsApp', keeping the shared vocabulary
-- small and stable across projects.
data Observation app
    = ObsTgMessage
        { obsChatId :: Maybe ChatId
        -- ^ target chat id ('Nothing' for username-targeted sends)
        , obsText :: Text
        -- ^ message text as sent
        , obsMsgId :: MessageId
        -- ^ incremental mock id assigned to the sent message (matches the id
        -- published to the outgoing mailbox for the same effect)
        , obsMarkup :: Maybe SomeReplyMarkup
        -- ^ reply markup attached to the message, when the send carried one.
        -- The markup type is opaque: equality sees only its presence (see the
        -- 'Eq' instance) and 'Show' renders a placeholder
        }
    | ObsTgDocument
        { obsChatId :: Maybe ChatId
        -- ^ target chat id ('Nothing' for username-targeted sends)
        , obsFileId :: Maybe FileId
        -- ^ file id when the document was uploaded by id ('Nothing' for URL or
        -- raw-content uploads, which carry no id)
        }
    | ObsTgReaction
        { obsTargetMsgId :: Maybe MessageId
        -- ^ message the reaction was set on ('Nothing' when the request does
        -- not carry a concrete target message id)
        }
    | ObsTgEdit
        { obsTargetMsgId :: Maybe MessageId
        -- ^ message being edited ('Nothing' when the request targets an inline
        -- message by inline id alone)
        , obsNewText :: Text
        -- ^ replacement text of the edit
        }
    | ObsTgDelete
        { obsTargetMsgId :: Maybe MessageId
        -- ^ message being deleted
        }
    | ObsAsyncScheduled
        { obsScenarioDesc :: Text
        -- ^ human-readable description of the captured async scenario
        }
    | ObsApp app
      -- ^ an app-specific observation produced by a caller-supplied hook

-- | Field-wise equality. The opaque 'SomeReplyMarkup' is compared by presence
-- only (the type exposes no 'Eq'), mirroring how the outgoing mailbox treats
-- markup; all other fields compare exactly.
instance Eq app => Eq (Observation app) where
    a == b = case (a, b) of
        (ObsTgMessage{obsChatId = chat1, obsText = text1, obsMsgId = msg1, obsMarkup = markup1}, ObsTgMessage{obsChatId = chat2, obsText = text2, obsMsgId = msg2, obsMarkup = markup2}) ->
            chat1 == chat2
                && text1 == text2
                && msg1 == msg2
                && isJust markup1 == isJust markup2
        (ObsTgDocument{obsChatId = chat1, obsFileId = file1}, ObsTgDocument{obsChatId = chat2, obsFileId = file2}) ->
            chat1 == chat2 && file1 == file2
        (ObsTgReaction reaction1, ObsTgReaction reaction2) -> reaction1 == reaction2
        (ObsTgEdit{obsTargetMsgId = target1, obsNewText = text1}, ObsTgEdit{obsTargetMsgId = target2, obsNewText = text2}) ->
            target1 == target2 && text1 == text2
        (ObsTgDelete delete1, ObsTgDelete delete2) -> delete1 == delete2
        (ObsAsyncScheduled desc1, ObsAsyncScheduled desc2) -> desc1 == desc2
        (ObsApp x, ObsApp y) -> x == y
        _ -> False

-- | Manual 'Show' because 'SomeReplyMarkup' has no 'Show' instance; the
-- opaque markup is rendered as a placeholder (mirrors the manual 'Show' of
-- the performer's 'OutgoingMessage').
instance Show app => Show (Observation app) where
    show obs = case obs of
        ObsTgMessage{obsChatId = chat, obsText = text, obsMsgId = msg, obsMarkup = markup} ->
            "ObsTgMessage{obsChatId = " <> show chat
                <> ", obsText = " <> show text
                <> ", obsMsgId = " <> show msg
                <> ", obsMarkup = " <> maybe "Nothing" (const "(markup)") markup
                <> "}"
        ObsTgDocument{obsChatId = chat, obsFileId = file} ->
            "ObsTgDocument{obsChatId = " <> show chat <> ", obsFileId = " <> show file <> "}"
        ObsTgReaction{obsTargetMsgId = target} ->
            "ObsTgReaction{obsTargetMsgId = " <> show target <> "}"
        ObsTgEdit{obsTargetMsgId = target, obsNewText = newText} ->
            "ObsTgEdit{obsTargetMsgId = " <> show target <> ", obsNewText = " <> show newText <> "}"
        ObsTgDelete{obsTargetMsgId = target} ->
            "ObsTgDelete{obsTargetMsgId = " <> show target <> "}"
        ObsAsyncScheduled{obsScenarioDesc = desc} ->
            "ObsAsyncScheduled{obsScenarioDesc = " <> show desc <> "}"
        ObsApp x -> "ObsApp " <> show x

-- | A journal entry stamped with the position (0-based) it was committed at.
data Sequenced a = Sequenced
    { sqNumber :: !Int
    -- ^ 0-based commit-order sequence number, unique within one 'ObservationLog'
    , sqValue :: a
    -- ^ the observed value
    }
    deriving (Eq, Show)

-- | Append-only observation journal, safe to share across threads.
-- Entries are stored newest-first behind the scenes so appends are O(1);
-- 'readObservations' restores commit order.
data ObservationLog app = ObservationLog
    { observationLogNextSeq :: !(TVar Int)
    -- ^ next sequence number to hand out
    , observationLogEntries :: !(TVar [Sequenced (Observation app)])
    -- ^ entries in reverse commit order (newest first)
    }

-- | Allocate an empty journal.
-- POST-CONTRACT: The returned journal contains no entries and its next sequence number is 0.
newObservationLog :: IO (ObservationLog app)
newObservationLog = ObservationLog <$> newTVarIO 0 <*> newTVarIO []

-- | Append one observation to the journal, assigning it the next sequence number.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The entry's 'sqNumber' is strictly greater than every earlier
-- entry's; the append is atomic with respect to other STM activity and is safe
-- to compose into a larger transaction (e.g. alongside an outgoing-mailbox
-- publish in the test performer).
appendObservation :: ObservationLog app -> Observation app -> STM ()
appendObservation logRef obs = do
    n <- readTVar (observationLogNextSeq logRef)
    writeTVar (observationLogNextSeq logRef) (n + 1)
    modifyTVar' (observationLogEntries logRef) (Sequenced n obs :)

-- | Take a snapshot of the journal in commit order (earliest first).
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The journal is not modified (non-destructive); the result is
-- ordered by 'sqNumber' ascending.
readObservations :: ObservationLog app -> IO [Observation app]
readObservations logRef = map sqValue . reverse <$> readTVarIO (observationLogEntries logRef)

--------------------------------------------------------------------------------
-- Scenario state and consumed-set-based observation waits
--------------------------------------------------------------------------------

-- | Why 'awaitObservation' returned 'Left': the wait budget expired before any
-- pending journal entry matched the predicate.
data AwaitTimeout = AwaitTimeout
    { awaitTimeoutAwaited :: !Text
    -- ^ human-readable description of what was awaited (the description
    -- argument passed to 'awaitObservation')
    , awaitTimeoutBudgetUs :: !Int
    -- ^ the expired wait budget in microseconds
    }
    deriving (Eq, Show)

-- | Conventional 'awaitObservation' wait budget: 2 seconds, mirroring TgTest's
-- @ttgTimeout@ default. Generous enough to absorb CI jitter — it is only a
-- safety net, since matching wake-ups are deterministic STM commits.
defaultAwaitBudgetUs :: Int
defaultAwaitBudgetUs = 2_000_000

-- | Minimal derived view of the Telegram dialog so far, folded from the
-- observations consumed by 'awaitObservation'. Kept deliberately small —
-- T9 extends this record.
data DialogState = DialogState
    { dsLastReply :: !(Maybe Text)
    -- ^ text of the last consumed 'ObsTgMessage' ('Nothing' before the first)
    , dsLastKeyboard :: !(Maybe SomeReplyMarkup)
    -- ^ keyboard attached to the last consumed 'ObsTgMessage' ('Nothing'
    -- before the first, or when the message carried no reply markup)
    }

-- | Dialog state before anything has been consumed.
emptyDialogState :: DialogState
emptyDialogState = DialogState Nothing Nothing

-- | Caller-owned consumption state threaded through BDD steps: which journal
-- entries have already been observed plus a derived view of the dialog. The
-- state is an immutable snapshot — 'awaitObservation' returns a NEW state
-- instead of mutating, so steps (and And-continuations) can fork from any
-- point without interference.
data ScenarioState app = ScenarioState
    { ssConsumed :: !(Set Int)
    -- ^ 'sqNumber's already consumed by 'awaitObservation' waits; the source
    -- of truth for consumption ('ssLastConsumed' is only a derived view)
    , ssLog :: !(ObservationLog app)
    -- ^ the journal this state observes (shared with the producing threads)
    , ssDialog :: !DialogState
    -- ^ dialog view folded from the consumed observations
    }

-- | 'sqNumber' of the highest journal entry consumed so far ('Nothing' when
-- nothing has been consumed yet). Convenience view DERIVED from 'ssConsumed'
-- — the set is the source of truth, so this can never drift from
-- 'awaitObservation''s consumption.
ssLastConsumed :: ScenarioState app -> Maybe Int
ssLastConsumed = Set.lookupMax . ssConsumed

-- | Allocate a fresh journal together with a fresh scenario state observing it.
-- POST-CONTRACT: The state's 'ssConsumed' is empty (nothing consumed), its
-- journal is empty, and its dialog state is 'emptyDialogState'.
newScenarioState :: IO (ScenarioState app)
newScenarioState = freshScenarioState <$> newObservationLog

-- | Wrap an existing journal in a fresh scenario state — use this when the
-- journal is shared (e.g. configured via @tcJournal@) or appended to from
-- other threads.
-- POST-CONTRACT: The state's 'ssConsumed' is empty (nothing consumed) and its
-- dialog state is 'emptyDialogState'; the journal is not touched.
freshScenarioState :: ObservationLog app -> ScenarioState app
freshScenarioState logRef =
    ScenarioState
        { ssConsumed = Set.empty
        , ssLog = logRef
        , ssDialog = emptyDialogState
        }

{- | Wait for the next UNCONSUMED journal entry that satisfies the predicate,
blocking until it is appended or the budget expires.

Semantics:

* /Scan/: the WHOLE journal is examined in 'sqNumber' order — i.e. journal
  commit order (every 'appendObservation' commits in a single STM
  transaction, and STM wake-ups preserve that order) — SKIPPING entries whose
  'sqNumber' is already in 'ssConsumed'. The FIRST unconsumed matching entry
  wins.
* /Consumption/: on 'Right' the matched entry's number is added to the
  returned state's 'ssConsumed'. Unconsumed observations remain available to
  subsequent steps REGARDLESS of earlier selective waits: an entry skipped
  over (non-matching) is not consumed, and because states are immutable
  snapshots, every state whose 'ssConsumed' still lacks a number keeps that
  entry available to its subsequent 'awaitObservation' calls. One
  'awaitObservation' on 'ObsTgMessage' consumes exactly one message — two
  identical awaits consume two DIFFERENT messages (the first matched message
  is already in 'ssConsumed', so the second wait scans past it).
* /Blocking/: the wait blocks in STM ('retry') while no unconsumed entry
  matches, so the appending thread wakes it the instant its transaction
  commits — there is no polling. A 'registerDelay' timer is read in the same
  transaction; when the budget expires the wait fails with 'Left' carrying an
  'AwaitTimeout'. The timeout is the ONLY source of non-determinism.
* /Dialog/: a matched 'ObsTgMessage' folds into the derived dialog state
  ('dsLastReply' from the message text, 'dsLastKeyboard' from its
  'obsMarkup'). Other observations leave the dialog untouched. Convention: one
  'awaitObservation' on 'ObsTgMessage' corresponds to exactly one bot message.

PRE-CONTRACT: None. (The state may be freshly allocated; the budget is
conventionally 'defaultAwaitBudgetUs' — 2 seconds, like TgTest's
@ttgTimeout@.)
POST-CONTRACT: The journal itself is never mutated by the scan (the scan is
read-only; consumption lives only in the returned 'ScenarioState'). On 'Left'
the input state is implicitly unchanged.
-}
awaitObservation ::
    -- | wait budget in microseconds
    Int ->
    -- | current scenario state (already-consumed 'sqNumber's are skipped)
    ScenarioState app ->
    -- | predicate the awaited observation must satisfy
    (Observation app -> Bool) ->
    -- | human-readable description of what is awaited (carried in 'AwaitTimeout')
    Text ->
    IO (Either AwaitTimeout (Observation app, ScenarioState app))
awaitObservation budgetUs st predicate awaitDesc = do
    delay <- registerDelay budgetUs
    outcome <- atomically (awaitTx delay)
    pure $ case outcome of
        Nothing ->
            Left
                AwaitTimeout
                    { awaitTimeoutAwaited = awaitDesc
                    , awaitTimeoutBudgetUs = budgetUs
                    }
        Just (match, st') -> Right (sqValue match, st')
  where
    -- | One STM round of the wait: match, or time out, or 'retry'.
    awaitTx delay = do
        expired <- readTVar delay
        if expired
            then pure Nothing
            else do
                entries <- readTVar (observationLogEntries (ssLog st))
                let consumed = ssConsumed st
                    unconsumed = reverse (filter ((`Set.notMember` consumed) . sqNumber) entries)
                case find (predicate . sqValue) unconsumed of
                    Just match ->
                        pure $
                            Just
                                ( match
                                , st
                                    { ssConsumed = Set.insert (sqNumber match) consumed
                                    , ssDialog = updateDialog (ssDialog st) (sqValue match)
                                    }
                                )
                    Nothing -> retry

-- | Read the last consumed observation (the entry at 'ssLastConsumed') WITHOUT
-- waiting and WITHOUT consuming anything new — the And-continuation building
-- block: a step can re-inspect what the previous step consumed (e.g. to
-- assert on the reply text) without consuming anything new.
--
-- The view is derived from 'ssConsumed', so it can never drift from
-- 'awaitObservation''s consumption.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns 'Nothing' when nothing has been consumed yet
-- ('ssConsumed' empty); otherwise the entry whose 'sqNumber' equals
-- 'ssLastConsumed'. The journal and the state are not modified.
peekLastConsumed :: ScenarioState app -> IO (Maybe (Sequenced (Observation app)))
peekLastConsumed st = case ssLastConsumed st of
    Nothing -> pure Nothing
    Just lastN -> do
        entries <- readTVarIO (observationLogEntries (ssLog st))
        pure (find ((== lastN) . sqNumber) entries)

-- | Fold one matched observation into the derived dialog state. Only
-- 'ObsTgMessage' is interpreted: it sets 'dsLastReply' from the message text
-- and 'dsLastKeyboard' from its 'obsMarkup'. Everything else leaves the
-- dialog untouched.
updateDialog :: DialogState -> Observation app -> DialogState
updateDialog _ ObsTgMessage{obsText = txt, obsMarkup = markup} =
    DialogState{dsLastReply = Just txt, dsLastKeyboard = markup}
updateDialog ds _ = ds
