{-# LANGUAGE NoImplicitPrelude #-}

{- | Library @Given@-phase context materializers for the BDD runner (plan task
T10) — the generic half of the first phase: staging canned Telegram downloads,
queueing canned AI mock answers, and an application-seed accumulator, all over
the canonical stack of "LazyCircus.Testing.Bdd.Step" (@c@ = 'AppContext',
threaded by 'GivenDef' actions).

The combinators are GivenDef-action producers: each returns an
@'AppContext' app -> IO ('AppContext' app)@ — exactly the action slot of
'LazyCircus.Testing.Bdd.Step.GivenDef' — so an app registry composes them with
its own step patterns, e.g.

> givenDef "file \"doc-1\" is downloadable"
>     (stagedTgDownloads [(FileId "doc-1", pdfBytes)])
> givenDef "assistant answer \"4\" queued" (queuedAiAnswers [completion "4"])
> givenDef "app seeded with user alice" (withAppSeed "alice")

'LazyCircus.Testing.Bdd.Step.GivenDef' actions cannot see the parameters
captured by the pattern, so the fixture values are baked in at registration
time and the pattern is a plain literal.

Staging happens immediately inside the Given action — before any When\/Then
step runs — by delegating to the test performer's mock APIs
('LazyCircus.Testing.Performer.addTgDownloads' and the FIFO append on
'LazyCircus.Testing.Performer.aiMock'); no live DB or bot is involved.

DB seeding is the APP's business and is out of scope: this module only
provides the 'ctxSeeds' accumulator slot, and the application's own steps (or
its buildAction wiring) interpret the accumulated seeds.

The DEFAULT context is EMPTY ('emptyAppContext'): no mock targets are wired,
nothing is staged or queued, no seeds accumulate — wiring mocks alone
('appContextFor') stages and seeds nothing, and a staging step run against the
unwired default context fails loudly instead of silently no-op'ing, so a spec
cannot lie by declaring fixtures it never wired (plan requirement R4).
-}
module LazyCircus.Testing.Bdd.Given
    ( -- * Context
      AppContext (..)
    , emptyAppContext
    , appContextFor
      -- * Given-action producers
    , stagedTgDownloads
    , queuedAiAnswers
    , withAppSeed
    ) where

import LazyCircus.Testing.Performer (AiMock (..), Mocks (..), TgMock, addTgDownloads)
import OpenAI.V1.Chat.Completions qualified as Chat
import RIO
import Telegram.Bot.API.Types (FileId)

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

-- | The canonical BDD context threaded through a scenario's Given steps — the
-- @c@ of 'LazyCircus.Testing.Bdd.Step.GivenDef'. Carries the mock targets the
-- runner wired for staging plus the application-seed accumulator.
data AppContext app = AppContext
    { ctxTgMock :: Maybe TgMock
      -- ^ Telegram mock wired by the runner — the download-staging target;
      -- 'Nothing' is the empty default (no staging possible)
    , ctxAiMock :: Maybe AiMock
      -- ^ AI mock wired by the runner — the canned-answer queue target;
      -- 'Nothing' is the empty default
    , ctxSeeds :: [app]
      -- ^ application-seed accumulator, in seeding order; interpreting the
      -- seeds (e.g. DB rows) is the app's business
    }

-- | The default, EMPTY context (plan requirement R4): no mock targets wired,
-- no staged downloads, no queued AI answers, no seeds.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: 'ctxTgMock' and 'ctxAiMock' are 'Nothing' and 'ctxSeeds' is
-- @[]@; a fixture-free Given phase run against this context (or against
-- 'appContextFor' of fresh mocks) stages and seeds nothing.
emptyAppContext :: AppContext app
emptyAppContext = AppContext{ctxTgMock = Nothing, ctxAiMock = Nothing, ctxSeeds = []}

-- | Wires a runner-allocated 'Mocks' set into an otherwise empty context,
-- making the staging combinators target its Telegram and AI mocks.
--
-- PRE-CONTRACT: Use a fresh per-scenario 'Mocks' set (as the BDD runner
-- allocates); staging into mocks shared across scenarios leaks fixtures
-- between them.
-- POST-CONTRACT: 'ctxSeeds' is empty — wiring alone stages and seeds nothing.
appContextFor :: Mocks serviceLib -> AppContext app
appContextFor mocks =
    AppContext
        { ctxTgMock = Just (tgMock mocks)
        , ctxAiMock = Just (aiMock mocks)
        , ctxSeeds = []
        }

--------------------------------------------------------------------------------
-- Given-action producers
--------------------------------------------------------------------------------

-- | Given action staging canned Telegram file downloads into the wired
-- 'TgMock' (delegates to 'LazyCircus.Testing.Performer.addTgDownloads'): the
-- mocked @getFile@ then reports each staged byte length and @downloadFile@
-- serves the staged bytes for the staged 'FileId's.
--
-- PRE-CONTRACT: The context carries a wired 'TgMock' ('appContextFor'); run
-- before the first When\/Then step (Given phase).
-- POST-CONTRACT: The downloads are immediately visible in the mock's download
-- store; restaging the same 'FileId' overwrites earlier bytes. The context
-- passes through unchanged. Throws when the context is the empty default.
stagedTgDownloads :: [(FileId, ByteString)] -> AppContext app -> IO (AppContext app)
stagedTgDownloads files ctx = do
    tg <- requireTgMock ctx
    addTgDownloads tg files
    pure ctx

-- | Given action queueing canned AI chat-completion answers on the wired
-- 'AiMock'. The mocked transport consumes them FIFO — after any answers
-- already queued — and falls back to
-- 'LazyCircus.Testing.Performer.emptyCompletion' once the queue drains.
--
-- PRE-CONTRACT: The context carries a wired 'AiMock' ('appContextFor'); run
-- before the first When\/Then step (Given phase).
-- POST-CONTRACT: The answers are appended to the end of the mock's response
-- queue (existing queued answers are consumed first). The context passes
-- through unchanged. Throws when the context is the empty default.
queuedAiAnswers :: [Chat.ChatCompletionObject] -> AppContext app -> IO (AppContext app)
queuedAiAnswers answers ctx = do
    aiM <- requireAiMock ctx
    modifySomeRef (aiResponses aiM) (<> answers)
    pure ctx

-- | Given action accumulating one application seed in the 'ctxSeeds' slot.
-- Pure bookkeeping — what a seed MEANS (DB rows, session state, ...) is the
-- app's business.
--
-- PRE-CONTRACT: None.
-- POST-CONTRACT: The seed is appended after the already accumulated ones.
withAppSeed :: app -> AppContext app -> IO (AppContext app)
withAppSeed seed ctx = pure ctx{ctxSeeds = ctxSeeds ctx <> [seed]}

--------------------------------------------------------------------------------
-- Wiring requirements
--------------------------------------------------------------------------------

-- | Extracts the wired Telegram mock; fails loudly on the empty default so a
-- staging step cannot silently no-op (R4: no implicit staging).
requireTgMock :: AppContext app -> IO TgMock
requireTgMock ctx = case ctxTgMock ctx of
    Just tg -> pure tg
    Nothing ->
        throwString
            "LazyCircus.Testing.Bdd.Given: no Telegram mock is wired in the BDD context; \
            \stage downloads only after the runner wires one (appContextFor)"

-- | Extracts the wired AI mock; fails loudly on the empty default so a
-- queueing step cannot silently no-op (R4: no implicit staging).
requireAiMock :: AppContext app -> IO AiMock
requireAiMock ctx = case ctxAiMock ctx of
    Just aiM -> pure aiM
    Nothing ->
        throwString
            "LazyCircus.Testing.Bdd.Given: no AI mock is wired in the BDD context; \
            \queue AI answers only after the runner wires one (appContextFor)"
