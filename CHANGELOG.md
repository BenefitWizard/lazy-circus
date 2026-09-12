# Changelog for `lazy-circus`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added
- **New subpackage `lazy-circus-testing`** (`testing/`): the test layer
  (`LazyCircus.Testing.Performer` / `TgTest` / `Updates`, module names unchanged)
  moved out of the core library, which no longer carries hspec or any test
  dependency. Consumers pin both packages from one git commit via
  `subdirs: [., testing]`.
- `LazyCircus.Testing.Bdd.*`: an executable BDD layer over the mock runtime —
  a pure Gherkin-subset parser (`parseFeature`, line-numbered AST,
  `Scenario Outline` + `Examples` expansion), a quoted-parameter pattern
  matcher (`matchStep`, `matchAll`), an STM observation journal
  (`Observation app`, `ObservationLog`, `awaitObservation` with consumed-set
  semantics and explicit timeouts, `peekLastConsumed`), the `StepDef m c s a`
  contract with first-registered-match-wins registries, a Telegram `Then`
  dictionary, `Given` staging combinators over an empty-by-default
  `AppContext app`, and the `gherkinSpec` hspec runner (coverage meta-test,
  ambiguity probe, `@blocked` → pending). The suite is database-free and
  passes with PostgreSQL stopped.
- `TestConfig` gained an observation-journal slot: `TestConfig app` with
  `tcJournal :: Maybe (ObservationLog app)` plus `tcMailHook` /
  `tcAiHook` app projections; `TgTestConfig` cascades the parameter
  (`ttgPerformerConfig :: TestConfig app`) while `defaultTestConfig` /
  `defaultTgTestConfig` stay polymorphic.
- `runArbitraryIO :: IO a -> ScenarioProgram script serviceLib a`: escape-hatch
  scenario operation that runs an arbitrary `IO` action. Documented as a
  last-resort fallback when no structured effect (DB, Telegram, AI, Mail, HTTP,
  or a registered service) fits. Runs for real in both production and test
  interpreters — it cannot be mocked.
- POML: a `.poml` body may now contain **one or more** top-level elements (e.g.
  `<role>` and `<task>` as siblings). Each top-level element is lowered to one
  entry of the resulting `[POML]` list, so a real prompt no longer needs to be
  wrapped in a single outer tag.
- POML: new `Fragment [POML]` AST node and `fragment :: [POML] -> POML` smart
  constructor (`LazyCircus.AI.POML.Types`). `fragment` collapses a `[POML]`
  fragment into a single `POML` for splicing into a `type="poml"` slot of
  another template: empty → `Text ""`, singleton → the node itself, otherwise
  `Fragment`. It is observationally transparent —
  `renderPOMLtoPrompt [fragment xs] == renderPOMLtoPrompt xs`. The parser never
  produces `Fragment`; it is eDSL/composition-only.
- POML: `<let name="..." src="file"/>` now inlines an external file's entire
  contents verbatim as a **compile-time constant** (no JSON parsing, no
  attribute navigation). `LetDecl` is now a sum type: `LetInput` (a `type`-declared
  runtime field, as before) and `LetFile` (a `src` constant). In `makePoml`:
  the file is read relative to the `.poml` and registered with
  `addDependentFile`; a `src` variable is **not** a record field (it is baked
  into the generated code as a `Text` literal), so a document whose only `<let>`
  is a `src` yields a nullary function. Specifying both `type` and `src` (or
  neither) is a parse error.
- Telegram Stars (XTR) payments in the `TelegramScript` effect: two new
  operations, `sendInvoice :: SendInvoiceRequest -> TelegramScript (Response Message)`
  and `answerPreCheckoutQuery :: AnswerPreCheckoutQueryRequest -> TelegramScript ()`,
  with the matching `TelegramScriptPerformer` methods (`sendInvoice'`,
  `answerPreCheckoutQuery'`). **(Breaking)** for external
  `TelegramScriptPerformer` instances, which must now define the two new
  methods.
- `LazyCircus.Telegram.Stars`: pure builders for the Stars (XTR) invoice loop —
  the `StarsPackage` record (title / description / payload / price in Stars /
  reference fiat amount for dual pricing),
  `mkStarsInvoiceRequest :: ChatId -> StarsPackage -> SendInvoiceRequest`
  (empty `provider_token`, `XTR` currency, a single `LabeledPrice` price line),
  and `mkPreCheckoutApproval :: Text -> AnswerPreCheckoutQueryRequest`
  (`ok = True`, no error message).
- Testing support (`lazy-circus-testing`): the Telegram mock captures the new
  operations — mailbox kinds `OutSendInvoice` / `OutAnswerPreCheckoutQuery`
  (plus `OutSendPoll`) and the journal observations `ObsTgInvoice` /
  `ObsTgPreCheckoutAnswer`; fake-update builders `mkPreCheckoutQueryUpdate` /
  `mkSuccessfulPaymentUpdate` (pure) and `mkPreCheckoutQueryUpdateByUser` /
  `mkSuccessfulPaymentUpdateByUser` (`UpdateFactory`-based, currency fixed to
  `XTR`); `tgTest` DSL senders `sendPreCheckoutQueryByUser` (chat-less, returns
  `UpdateId`) and `sendSuccessfulPaymentByUser` (returns
  `(UpdateId, MessageId)`).
- Demo bot: a `stars_payments` ledger (`telegram_payment_charge_id` UNIQUE),
  the `/topup` command listing Stars packages and sending the invoice, an
  automatic pre-checkout approval routed BEFORE the chat-id gate (outside
  per-chat serialisation — the Bot API answer deadline is 10 seconds), and
  idempotent payment crediting via `ON CONFLICT (telegram_payment_charge_id)
  DO NOTHING` + `RETURNING` with a confirmation message on first credit only.

#### Manual verification checklist — real Stars purchase

Operational post-merge step, NOT part of CI (CI covers the same flow against
mocks; see `StarsFlowSpec` / `StarsTgTestSpec`):

1. Enable Telegram Stars for the bot in BotFather, run the demo bot, send
   `/topup` — the package list is shown and `/topup <payload>` opens an invoice
   with the Pay button.
2. Pay: the pre-checkout is approved automatically by the bot — the payment
   proceeds without a "bot did not respond to pre-checkout query" error.
3. After the payment completes, the confirmation message is delivered to the
   user.
4. `SELECT * FROM stars_payments;` shows exactly one row with the correct
   `telegram_payment_charge_id`, `stars`, and `currency_amount`.
5. Redelivery of the payment update cannot be triggered manually — duplicate-
   charge idempotency (second delivery credits nothing and sends no second
   confirmation) is covered by the automated specs `StarsFlowSpec` and
   `StarsTgTestSpec`.

### Changed
- **(Breaking)** POML public API now returns `[POML]` instead of a single
  `POML`:
  - `parsePomlText` / `toPOML` (`LazyCircus.AI.POML.Parser`) now return
    `Either String [POML]`.
  - `makePoml` (`LazyCircus.AI.POML.TH`) now generates `<base> :: <Base>Input -> [POML]`
    (and a nullary `<base> :: [POML]` when there are no `<let>` declarations).
  Consumers should migrate call sites like `renderPOMLtoPrompt [hello x]` to
  `renderPOMLtoPrompt (hello x)` (the generated function already returns a list).
  An empty `.poml` body is still rejected (`Left` / compile-time `fail`).

## 0.1.0.0 - YYYY-MM-DD
