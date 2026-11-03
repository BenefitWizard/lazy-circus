# Lazy Circus Reference: BDD Feature Specs (`lazy-circus-testing`)

Read this when:

- writing or reviewing Gherkin `.feature` specs executed as hspec scenarios
- registering step definitions (`givenDef` / `whenDef` / `thenDef`) in a registry
- observing side effects through the journal (`tcJournal`, `awaitObservation`)
- wiring `gherkinSpec` for an application

Everything here lives in the `lazy-circus-testing` subpackage (`testing/`), NOT in the
core library — consumers add it as a second package pinned from the same git commit
(see "Using the `lazy-circus-testing` subpackage" in the repository README). hspec is a
library dependency of this subpackage only; the core stays hspec-free.

## Contents

- Module Map
- The Pipeline
- Feature File Subset
- Step Definitions And The Registry
- Journal: Observations And Cursor Waits
- The Runner (`gherkinSpec`)
- Given Combinators
- Worked Example (Echo Bot)
- Review Checklist

## Module Map

| Module | Responsibility |
|---|---|
| `LazyCircus.Testing.Bdd.Gherkin` | pure `parseFeature :: Text -> Either GherkinParseError GherkinFeature`; AST carries line numbers; Outline rows expand at parse time |
| `LazyCircus.Testing.Bdd.Pattern` | the `Pattern` ADT (`Template` / `Literal`, `IsString`), `matchStep :: Pattern -> Text -> Maybe [(ParamName, ParamValue)]`; quoted spans `"..."` and `«...»` capture strictly quoted values; `StepParams` (captures + the step's argument table), `lookupParam`, `patternSource`, `duplicateParamNames`, `matchAll` (every matching name, input order) |
| `LazyCircus.Testing.Bdd.Step` | `StepDef m c s a` (actions receive the matched captures plus the step's table, as one `StepParams`), `StepRegistry` with deterministic `matchingDefs` selection (`Literal` first, then `Template` in registration order), `runScenarioSteps`, structural `StepError` values |
| `LazyCircus.Testing.Bdd.Journal` | `Observation app`, append-only `ObservationLog`, `awaitObservation`, `peekLastConsumed`, `ScenarioState` with the `dsLastPoll` digest and the acting user (`ssActingUser` / `actingUserId`) |
| `LazyCircus.Testing.Bdd.Tg` | ready-made Telegram `When`/`Then` dictionary over the journal (expected values read from captures and step tables via `lookupParam` / `stepParamsTable`; includes the poll and vote steps — the default-user pair and the per-member pair) and the canonical `tgTestBootstrap` |
| `LazyCircus.Testing.Bdd.Given` | `AppContext app` and Given-phase staging combinators |
| `LazyCircus.Testing.Bdd.Runner` | `gherkinSpec`: hspec tree, coverage meta-test, ambiguity probe, `@blocked` |

## The Pipeline

1. **Parse + meta-test, before any scenario runs.** `gherkinSpec` parses the feature and
   emits one hspec example requiring EVERY step of EVERY scenario to match a registry entry
   by resolved keyword and pattern. Failures are collected into a single red listing
   `feature / scenario / line / step text`. An unmatched step is a spec-build error, never a
   hanging run.
2. **Given** actions materialize context (`AppContext app`): staged downloads, queued AI
   answers, app seeds. The default context is empty — a spec must declare what it uses.
3. **When/Then** dialog steps execute in document order inside `TelegramTestScript`.
   Effects go to the test performer, which appends an `Observation` to the journal in the
   SAME STM transaction that publishes to the outgoing mailbox (order between the two
   channels is stable by construction).
4. **Then** consumes journal entries via `awaitObservation`: scan past consumed entries,
   first match wins, explicit `AwaitTimeout` on budget expiry. Observations skipped by a
   selective wait stay available to later waits (consumed-set semantics, not a cursor).
5. **And-continuations** read the last consumed observation via `peekLastConsumed` — they
   never wait and never consume.
6. **After the scenario** the runner hands the full journal snapshot to the verifier for
   negative checks ("nothing else was sent").

## Feature File Subset

Supported: `Feature:` with description lines, tags above features and scenarios (carried
in the AST; the runner acts on `@blocked`), `Scenario:`, `Scenario Outline:` + `Examples:`
(placeholders `<param>` substitute into steps, their tables AND the scenario name; each
row becomes its own scenario), `And`/`But` (stored in the AST with the RESOLVED keyword),
wrapped steps (a plain non-keyword line inside a scenario continues the previous step's
text — the two trimmed texts join with a single space, and the step keeps the line of its
first line), step argument tables (`| ... |` rows directly after a step attach to it as
`gherkinStepTable`; rows are consumed greedily, so a plain text line AFTER a table row is
an error — the table ends the step; no width check for step tables), `#` comments, empty
lines.
Errors carry 1-based line numbers (step outside a scenario, `Examples` without a header
row, `And`/`But` before any `Given`/`When`/`Then`, table row with no preceding step,
plain line after a step table).

Not supported: docstrings (`"""`).

Patterns are the `Pattern` ADT: a string literal denotes a `Template`, and a `Literal`
matches exactly (quotes are ordinary characters there — use it for step texts that
contain quotes verbatim). In a template, quoted spans `"name"` and `«name»` hold the
parameter NAME; the captured step text is the VALUE. Matching is STRICT about quote
boundaries: a value must appear in the step text wrapped in a PAIR of matching quote
characters — either style, regardless of the style the span uses (`"alice"`, `«alice»`,
or a guillemet value under a straight-quote span all match the span `"name"`), the
capture is the non-empty text strictly between the quotes, and the first closer ends it.
Unquoted pattern text must match literally; both sides are whitespace-normalized first
(runs of spaces/tabs collapse to one space, ends trimmed), but quote characters survive
normalization — collapsing never merges text across a quoted span. An unterminated
quoted span in the pattern is not an error: it and the rest of the pattern match
literally.

## Step Definitions And The Registry

```haskell
data StepDef m c s a
    = GivenDef Pattern (StepParams -> c -> IO c)                           -- pure accumulation, captures delivered
    | DialogDef GherkinKeyword Pattern (StepParams -> s -> m (s, Maybe a)) -- keyword participates in matching
```

- All `Given` steps of a scenario must precede its first `When`/`Then` — violations are
  structural `StepError` values with the line number, not runtime exceptions.
- Matching uses the step's RESOLVED keyword: a `Then` step never fires a When-registered
  pattern.
- Registries are `Semigroup`/`Monoid`; `mkRegistry` builds one. Selection is
  deterministic via `matchingDefs`: `Literal` patterns match FIRST, then `Template`
  patterns, each class in registration order — a fully spelled-out step text always wins
  over competing templates, so no registration-order discipline is required.
- Captured parameters are delivered to the action as a `StepParams` record: the captures
  (`stepParamsCaptures`, name/value pairs in the order the quoted spans appear in the
  pattern) plus the step's argument table (`stepParamsTable :: Maybe [[Text]]`, rows in
  document order, `Nothing` when the step carries no table); read a capture with
  `lookupParam :: ParamName -> StepParams -> Maybe ParamValue` — `Nothing` only for a
  name the pattern does not contain. A pattern binding the same name twice fails the
  step at execution with `StepDuplicateParam`, before the action runs.
- The interpreter is generic over `m` (needs `MonadIO` only); the canonical instantiation
  is `m = TelegramTestScript`, `c = AppContext app`, `s = ScenarioState app` — that is,
  `ScenarioRegistry serviceLib app m = StepRegistry m (AppContext app) (ScenarioState app) ()`.

```haskell
registry :: ScenarioRegistry NoServiceLib () TelegramTestScript
registry = mkRegistry
    [ givenDef "the echo bot is awake" (\_params -> pure . id)
    , whenDef "the user sends \"$msg\"" $ \params st -> do
        _ <- sendMessage (fromMaybe "" (lookupParam "$msg" params))  -- plain TelegramTestScript effect
        pure (st, Nothing)
    , botReplyContains                      -- library Then-dictionary values: the expected
    , botRepliesWithMessage                 -- texts are read from their own captures
    ]
```

## Journal: Observations And Cursor Waits

```haskell
data Observation app
    = ObsTgMessage  { obsChatId :: Maybe ChatId, obsText :: Text
                    , obsMsgId :: MessageId, obsMarkup :: Maybe SomeReplyMarkup }
    | ObsTgDocument { obsChatId :: Maybe ChatId, obsFileId :: Maybe FileId }
    | ObsTgPoll     { obsChatId :: Maybe ChatId, obsMsgId :: MessageId
                    , obsPollId :: PollId, obsQuestion :: Text, obsOptions :: [Text]
                    , obsThreadId :: Maybe MessageThreadId
                    , obsIsAnonymous :: Maybe Bool, obsCloseDate :: Maybe Int }
    | ObsTgInvoice  { obsChatId :: Maybe ChatId, obsTitle :: Text }
    | ObsTgReaction { obsTargetMsgId :: Maybe MessageId
                    , obsReaction :: Maybe [ReactionType], obsIsBig :: Maybe Bool }
    | ObsTgEdit     { obsTargetMsgId :: Maybe MessageId, obsNewText :: Text }
    | ObsTgDelete   { obsTargetMsgId :: Maybe MessageId }
    | ObsTgPreCheckoutAnswer { obsQueryId :: Text, obsOk :: Bool }
    | ObsAsyncScheduled { obsScenarioDesc :: Text }   -- runAsync capture
    | ObsTimerScheduled { obsScenarioDesc :: Text }   -- timer-service capture
    | ObsApp app                    -- your facts, via tcMailHook / tcAiHook / direct append

newObservationLog  :: IO (ObservationLog app)
appendObservation  :: ObservationLog app -> Observation app -> STM ()
readObservations   :: ObservationLog app -> IO [Observation app]   -- commit-order snapshot

awaitObservation   :: Int -> ScenarioState app -> (Observation app -> Bool) -> Text
                   -> IO (Either AwaitTimeout (Observation app, ScenarioState app))
peekLastConsumed   :: ScenarioState app -> IO (Maybe (Sequenced (Observation app)))
defaultAwaitBudgetUs :: Int   -- 2s, mirroring TgTest's default
```

Conventions (all enforced by Haddock contracts and tests):

- one `awaitObservation` on `ObsTgMessage` consumes exactly ONE message; two identical
  messages require two awaits
- consumption is recorded in the returned `ScenarioState` (`ssConsumed :: Set Int`); the
  journal itself is never mutated by waits
- unconsumed observations stay matchable for later waits even when an earlier selective
  wait scanned past them
- the journal and the outgoing mailbox are written in one `atomically` per Telegram effect,
  so mailbox order and journal order always agree
- non-Telegram effects reach the journal as `ObsApp` through the hooks (`tcMailHook`,
  `tcAiHook`) — or via direct `appendObservation` from any layer that holds the log
- scheduled async scenarios and timers are journaled by the test performer as
  `ObsAsyncScheduled` / `ObsTimerScheduled`, described by `obsScenarioDesc`
- the blessing rule: a new library `Observation` constructor is added only after an
  observation shape has survived at least two scenarios through app hooks

## Telegram Step Dictionary (Polls)

The mocked performer assigns every sent poll the deterministic id
`PollId "poll-<messageId>"` and journals the full shape — chat, message id, poll id,
question, option texts (projected from the request) and the request's
`message_thread_id` / `is_anonymous` / `allows_multiple_answers` /
`allows_revoting` / `shuffle_options` / `close_date` — as `ObsTgPoll`. The dialog
state folds a consumed poll into `dsLastPoll :: Maybe PollDigest`
(`pdPollId` / `pdMsgId` / `pdQuestion` / `pdOptions` plus `pdThreadId` / `pdIsAnonymous` /
`pdAllowsMultipleAnswers` / `pdAllowsRevoting` / `pdShuffleOptions` /
`pdCloseDate`); messages do NOT invalidate the digest. `pdMsgId` is the
announcement message's id — the value a consumer's reply-to-the-announcement step
feeds to `sendReplyByUser` (see [tg-test.md](tg-test.md)) to simulate a member
replying to the announcement (e.g. an attendance correction). Each digest `Maybe` mirrors
the matching send-request field: `Nothing` honestly means "left unset in the
request". `pdCloseDate` is RAW Unix seconds — timezone interpretation stays with
project steps of the consumer. Note the Telegram server defaults `is_anonymous` to
`True`, `allows_multiple_answers` to `False` and `shuffle_options` to "keep the
sent order" when the request leaves them unset, and defaults `allows_revoting` BY
POLL TYPE (`False` for quizzes, `True` for regular polls) — unset ≠ unpinned.

Library steps (in `LazyCircus.Testing.Bdd.Tg`, registry-ready):

```gherkin
When the user sends "/poll"
Then the bot sends a poll "Кого позвать в шапито?"
    | Жонглёры    |    # the options table pins the FULL option list,
    | Акробаты    |    # one single-cell row per option, in order
    | Дрессировщик |
And the poll is public                         # And-continuation on the digest:
                                               # is_anonymous was set to Just False
And the poll options are shuffled              # shuffle_options was set to Just True
And the poll allows re-voting                  # allows_revoting was set to Just True
And the poll allows multiple answers           # allows_multiple_answers was set to Just True
When the user votes for "Акробаты" in the poll      # single vote via the quoted capture
Then the bot replies with "🗳 голос учтён: [1] от 1001"
When the member "@alice" votes for "Акробаты" in the poll   # a named cast member,
Then the bot replies with "🗳 голос учтён: [1] от 2000000123"   # NOT the default user
```

- `botSendsPoll` (`Then`) consumes exactly one `ObsTgPoll` with the expected question;
  with a table attached it also pins the expected options. Malformed tables (a row that
  is not exactly one non-empty cell) fail the step BEFORE any waiting.
- `pollIsPublic` (`Then`/And, `the poll is public`) — And-continuation asserting the
  last consumed poll's `pdIsAnonymous == Just False`; never waits, never consumes.
  Aborts with the no-poll-yet reason when no poll was consumed, and with the
  server-default explanation when the flag is `Nothing` or `Just True` (only public
  polls deliver `poll_answer`).
- `pollIsAnonymous` (`Then`/And, `the poll is anonymous`) — the strict sibling of
  `pollIsPublic`: requires `Just True` explicitly (an unset flag aborts even though
  the server would treat the poll as anonymous by default).
- The poll choice-flag sextet (`Then`/And) — same And-continuation shape as the
  publicness pair, each demanding its flag was set EXPLICITLY in the send request
  (an unset flag aborts with the server-default explanation):
  - `pollAllowsMultipleAnswers` (`the poll allows multiple answers`) requires
    `pdAllowsMultipleAnswers == Just True`; `pollIsSingleChoice`
    (`the poll is single choice`) requires `Just False` (the server defaults an
    unset flag to single-choice).
  - `pollAllowsRevote` (`the poll allows re-voting`) requires
    `pdAllowsRevoting == Just True`; `pollForbidsRevote`
    (`the poll does not allow re-voting`) requires `Just False` (an unset flag
    lets the server decide by poll type: no re-voting for quizzes, re-voting for
    regular polls).
  - `pollOptionsAreShuffled` (`the poll options are shuffled`) requires
    `pdShuffleOptions == Just True`; `pollOptionsAreNotShuffled`
    (`the poll options are not shuffled`) requires `Just False`. Shuffling is
    SERVER-side — the mock (and the journaled `pdOptions`) keep the request
    order, Telegram randomises the order shown to each viewer; the step observes
    the request's flag, while the order-sensitive pin of the option texts stays
    with `botSendsPoll`'s table.
- `userVotesFor` (`When`, `the user votes for "$option" in the poll`) resolves the
  captured option text against the consumed poll's `pdOptions` and feeds one chat-less
  `poll_answer` update via the `sendPollAnswer` DSL op; a table attached to this step is
  a misuse (use `userVotesIn`).
- `userVotesIn` (`When`, `the user votes in the poll`) votes the TABLE rows — the
  multi-answer form (all rows' indexes in one `poll_answer`).
- `memberVotesFor` (`When`, `the member "$login" votes for "$option" in the poll`) and
  `memberVotesIn` (`When`, `the member "$login" votes in the poll` + options table) are
  the multi-actor siblings: the vote update arrives from
  `userIdForLogin login` (`LazyCircus.Testing.Updates` — a pure FNV-1a derivation into an
  id band disjoint from `defaultTestUserId`), so scenarios with several participants are
  distinguishable bot-side via `poll_answer.user`. The function is exported so apps can
  seed users whose ids the member steps produce for the same logins.
- All four vote steps require a poll to have been CONSUMED first (`botSendsPoll` or any
  await over an `ObsTgPoll`), since they vote against `dsLastPoll`; an option text not
  among the poll's options fails the step with the actual option list.

A working end-to-end example (bot sends a non-anonymous poll on `/poll`, registers the
poll id in a poll→chat registry, acknowledges votes with the voted indexes AND the
voter's user id — the voter-aware ack is what makes the member-vote scenarios
meaningful) lives in `testing/test/Bdd/PollSpec.hs` — mirror it for your own poll flows.
The observability example is there too: the `/poll` scenario pins `Just`-valued digest
fields via `the poll is public` and spec-local digest-pin steps, the `/anonpoll`
scenario pins the explicit `Just True` and the honest `Nothing`s, the `/fancypoll`
and `/plainpoll` scenarios pin the explicit `Just True` / `Just False` choice flags
(shuffle, re-voting, multiple answers) through the sextet steps and digest pins, and
the refusal feature proves the publicness steps abort before a poll is consumed.

## Telegram Step Dictionary (Reactions)

The mocked performer journals every `setMessageReaction` with its full shape —
the target message id plus the request's `reaction` list and `is_big` flag — as
`ObsTgReaction`. The dialog state folds a consumed reaction into
`dsLastReaction :: Maybe ReactionDigest` (`rdTargetMsgId` / `rdEmojis` /
`rdIsBig`); messages do NOT invalidate the digest. `rdEmojis` holds the PAYLOAD
TEXTS projected through `reactionEmojiTexts` (the emoji of an emoji reaction,
the custom emoji id of a custom-emoji one) so Gherkin steps match the text they
captured without knowing the reaction kind; `rdIsBig`'s `Maybe` mirrors the
request field: `Nothing` honestly means "left unset".

`ReactionType` (from telegram-bot-api) has no `Eq`, so the testing toolkit
defines an orphan `Eq` instance in `LazyCircus.Testing.Orphans` (constructor-wise
record equality; imported via the journal) — `ObsTgReaction`'s `Eq` is therefore
full structural equality. `Show` comes from the library.

Library steps (in `LazyCircus.Testing.Bdd.Tg`, registry-ready):

```gherkin
When the user sends "/react"
Then the bot reacts to a message        # any reaction (target-agnostic)
Then the bot reacts with "👍"           # payload-matching: consumes a reaction
                                       # whose emoji projection contains "👍"
And the reaction is big                 # And-continuation on the digest:
                                       # is_big was set to Just True
```

- `botReactsTo` (`Then`, `the bot reacts to a message`) consumes exactly one
  `ObsTgReaction` on any message — the presence-only form.
- `botReactsWith` (`Then`, `the bot reacts with "$emoji"`) consumes exactly one
  `ObsTgReaction` whose emoji projection contains the capture; folds the digest
  into `dsLastReaction`. Times out with nothing consumed when no reaction
  carries the emoji.
- `reactionIsBig` (`Then`/And, `the reaction is big`) — And-continuation asserting
  the last consumed reaction's `rdIsBig == Just True`; never waits, never
  consumes. Aborts with the no-consumed-reaction reason when nothing was
  consumed, and with the unset/small explanation when the flag is `Nothing` or
  `Just False`.
- The `tgTest` DSL mirrors the pair: `waitForReaction :: MessageId -> _`
  (target-only) and `waitForReactionWith :: MessageId -> Text -> _` (target +
  emoji membership in the payload projection).

A working end-to-end example (bot reacts with 👍 on `/react` leaving `is_big`
unset, with 🔥 and `is_big = Just True` on `/reactbig`; digest pins for the
deterministic target — the factory's first user message is always `MessageId 1`
— plus the is-big refusal feature) lives in `testing/test/Bdd/ReactionSpec.hs` —
mirror it for your own reaction flows.

## Telegram Step Dictionary (Named Messages)

A scenario cannot compute a user message's id itself: `message_id` mirrors the
update factory's `update_id`, and the counter depends on how many updates the
scenario has already fed the bot. So the state carries a name map —
`ssNamedMessages :: Map Text MessageId`, a non-derived `ScenarioState` field
like `ssActingUser`: bound only by an explicit naming step, survives every
`awaitObservation`, resets per scenario. The mocked performer journals every
`deleteMessage` as `ObsTgDelete` with its target (`obsTargetMsgId`), so a
deletion can be checked against a NAME, not just observed.

Library steps (in `LazyCircus.Testing.Bdd.Tg`, registry-ready):

```gherkin
When the user sends "/tick" as "message 1"   # send from the acting user AND
                                              # bind "message 1" -> the sent
                                              # message's assigned MessageId
Then the bot deletes the "message 1"         # strict: consumes a deletion
                                              # targeting EXACTLY that message
Then the bot deletes a message               # target-agnostic sibling: any
                                              # deletion passes
```

- `userSendsAs` (`When`, `the user sends "$msg" as "$name"`) — `userSends`
  plus a name: feeds the text-message update from `actingUserId` in
  `defaultTestChatId` and records name → assigned `MessageId` in
  `ssNamedMessages`. A name binds ONCE per scenario: a rebind aborts with a
  guard failure listing the bound names (in a BDD document a name is written
  once, and a collision is almost always a copy-paste typo that silent
  shadowing would hide). The plain `the user sends "$msg"` pattern requires
  the step text to END after the message, so the two patterns never collide.
- `botDeletesNamedMessage` (`Then`, `the bot deletes the "$name"`) consumes
  exactly one `ObsTgDelete` whose `obsTargetMsgId` equals the named id —
  deletions of other targets scanned past stay available to later waits
  (consumed-set semantics). An unknown name aborts IMMEDIATELY (no waiting)
  with the known names; a wrong target (or nothing) times out with a reason
  carrying the expected name, its id and the bound names. The strict sibling
  `botDeletesMessage` (`Then`, `the bot deletes a message`) accepts any
  deletion — keep it for flows that genuinely do not care about the target.

Caveats worth knowing:

- Selective waiting cannot catch EXTRA deletions: if the bot deleted both the
  named message and (wrongly) a neighbour, the named step finds its match and
  passes. Full strictness is a post-scenario verifier concern — assert the
  journal holds no unconsumed `ObsTgDelete` entries beyond the expected ones
  (the `ScenarioVerifier` receives the full journal snapshot).
- The named check matches the numeric id only. User messages get ids from the
  update factory (1, 2, ...), bot messages from the mock's own counter — the
  two id spaces overlap numerically, so a name pins a number, not an origin.

A working end-to-end example (a `/tick` bot deleting the named command, two
names distinguished in one scenario, plus the wrong-target refusal feature
where the bot deletes `MessageId 2` instead of the named command and the step
times out) lives in `testing/test/Bdd/NamedMessagesSpec.hs` — mirror it for
your own deletion flows.

## The Acting User

Every user-named input step acts as the state's CURRENT actor
(`actingUserId :: ScenarioState app -> UserId`, `LazyCircus.Testing.Bdd.Journal`):
`defaultTestUserId` until a takes-the-stage step selects a cast member. The
switches (library `When` steps):

```gherkin
When the member "@carol" takes the stage    # every "the user ..." acts as id(@carol)
And the user sends "привет"                 # fed from carol's id
And the user votes for "Да" in the poll
When the default user takes the stage       # back to defaultTestUserId (1001)
```

- `memberTakesStage` / `defaultUserTakesStage` only change WHO "the user" is —
  input verbs stay single-form instead of sprouting `member<Verb>` variants. The
  actor rides in `ssActingUser :: Maybe UserId`, the only non-derived field of
  `ScenarioState`: it survives every `awaitObservation` (record update) and
  resets per scenario (`freshScenarioState` seeds `Nothing`).
- The member-named vote steps (`memberVotesFor` / `memberVotesIn`) are explicit
  shorthands: they act as the login in their own capture regardless of the
  current actor. Prefer the switch when several actions follow as the same
  member; prefer the shorthand for a one-off vote.
- Spec-local input steps should honor the actor too: read `actingUserId st` and
  call the `*ByUser` DSL ops (`sendMessageByUser`, `sendDocumentByUser`,
  `sendKeypressByUser`, ...). The library `userSends` ("the user sends "$msg"")
  already does.

## The Runner (`gherkinSpec`)

```haskell
gherkinSpec :: MonadIO m
    => FeatureSource                                          -- FeatureFile path | FeatureInline
    -> (GherkinScenario -> IO (ScenarioRegistry serviceLib app m))  -- registry per scenario
    -> ScenarioBootstrap serviceLib app m                     -- builds the executor from the runner-allocated fresh journal + mocks
    -> ScenarioVerifier app                                   -- post-scenario: outcome + journal snapshot
    -> Spec
```

- the tree is `describe <feature label>` → one `it` per scenario (each Outline row is its
  own `it` with the substituted name), preceded by the meta-test and the ambiguity probe
- `@blocked` scenarios become `pendingWith` skips (their steps still must be registered)
- the ambiguity probe is a visible, NON-blocking example listing same-phase registry
  templates that both match a probe text (a `Literal` match shadows templates by rule
  and is never reported as ambiguous)
- isolation mirrors `tgTest`: a fresh `ObservationLog` and fresh `Mocks` per scenario
- the CANONICAL bootstrap is `tgTestBootstrap` (`LazyCircus.Testing.Bdd.Tg`): pass it
  your run config and `buildAction` — `tgTestBootstrap defaultTgTestConfig (buildAction
  app)` — and the library wires each scenario's fresh journal via `tcJournal` and runs
  the step program as a `tgTestWithMocks` dialog over the runner-owned mocks (a
  `gherkinSpec` scenario IS a `tgTest` run)
- the runner never touches PostgreSQL; `testing/test/Bdd/RunnerSpec.hs` shows a
  database-free `DefaultApp` construction for the test-performer path
- known limitation: attribution of a failed step is runner-granular (the `StepError`
  surfaces after the pilot run); pinpoint the step via `renderStepError`

## Given Combinators

```haskell
data AppContext app = AppContext               -- wiring for mock targets + the seed accumulator
emptyAppContext :: AppContext app              -- the DEFAULT: nothing wired
appContextFor   :: Mocks serviceLib -> AppContext app   -- wire mock targets

-- Given-action producers: each returns `AppContext app -> IO (AppContext app)` —
-- exactly the action slot of `GivenDef` once the captured params are fixed
-- (`\_params -> stagedTgDownloads ...`); fixture values are NOT baked in at
-- registration — a staging step keys them off its own captures:
stagedTgDownloads :: [(FileId, ByteString)]
                  -> AppContext app -> IO (AppContext app)  -- stage canned downloads (addTgDownloads)
queuedAiAnswers   :: [Chat.ChatCompletionObject]
                  -> AppContext app -> IO (AppContext app)  -- FIFO AI mock answers
withAppSeed       :: app
                  -> AppContext app -> IO (AppContext app)  -- accumulate an app-specific seed

-- > givenDef "file \"$name\" is downloadable" $ \params ->
-- >     stagedTgDownloads [(FileId (fromMaybe "doc-1" (lookupParam "$name" params)), pdfBytes)]
```

The default context is empty by design: a spec cannot silently rely on fixtures it never
declared — staging into an unwired context fails loudly.

## Worked Example (Echo Bot)

`testing/test/Bdd/EchoSmokeSpec.hs` runs an inline feature through `gherkinSpec` against a
database-free echo app. The registry is a STATIC value shared by every scenario
(`\_ -> pure echoRegistry`) — nothing is baked in at registration: the text-message When
is the LIBRARY `userSends`, the Given staging def keys the canned bytes off its own
`"$name"` capture, the one spec-local When (the document upload) reads its target via
`lookupParam "$file"` and acts as `actingUserId st`, and the library Then-constructors
read their expected texts from their own captures. The bootstrap is the canonical
`tgTestBootstrap defaultTgTestConfig (buildEchoAction app)`.

Covered flows: When `the user sends "$msg"` (library `userSends`) feeds the text from the
acting user; Then `the bot replies
with "$text"` consumes the journaled reply; And `the bot replies with a message
containing "$frag"` re-inspects the last consumed message without waiting; the scenario
`echoes twice with different words` runs the same When/Then patterns at two values (the
static-registry regression); the scenario `replies with the staged file size` stages a
download via `file "doc-1" is downloadable`, uploads it via `the user uploads document
"$file"`, and asserts the byte-length reply. The suite passes with PostgreSQL stopped —
DB and HTTP are the only always-real sub-languages and the echo never touches them.

## Review Checklist

- Does every feature step match a registry entry (meta-test green) and does the ambiguity
  probe report no unintended collisions?
- Do step tables follow the consuming step's contract (e.g. the library poll steps
  require exactly one non-empty cell per row)?
- Does every pattern bind each parameter name at most once (`StepDuplicateParam` fails
  the step at execution)?
- Do feature steps quote every parameter value (`"value"` / `«value»`)? An unquoted
  value does not match.
- Is deterministic selection used consciously (`Literal` beats competing templates;
  within a class, registration order decides)?
- Are `Given` steps before the first `When`/`Then`, and is the default context empty unless
  fixtures are explicitly staged?
- Is each `Then` consuming exactly one observation, with `And`-continuations reading via
  `peekLastConsumed` (never waiting, never consuming)?
- Are app-specific facts journaled as `ObsApp` (hooks or direct append) instead of
  overloading Telegram constructors?
- Is a new blessed `Observation` constructor justified by two surviving scenarios?
- Was `hpack` AND `hpack testing` run before building?
