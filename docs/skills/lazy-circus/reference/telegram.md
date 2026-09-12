# Lazy Circus Reference: Telegram Effect

Read this when:

- using or reviewing `TelegramScript` (module `LazyCircus.Scene.Telegram.Lang`)
- downloading files (`downloadFile`, `downloadFileById`, `downloadCheckedFile`)
- wrapping scripts with `tgScript`

## Contents

- Operations
- File Downloads
- Telegram Stars (XTR) Loop
- Periodic Chat-Action Refresh
- Review Checklist

## Operations

Program type:

```haskell
type TelegramScript = F TelegramScriptF
```

Main operations:

| Function | Result |
|---|---|
| `getFile` | `Response File` |
| `downloadFile` | `ByteString` — raw transport, takes the `File` object from `getFile` |
| `downloadFileById` | `(Response File, ByteString)` — raw `getFile` response + bytes, no checks |
| `downloadCheckedFile` | `Either FileValidationError (Response File, ByteString)` — two size gates |
| `getBotName` | `Text` |
| `sendMessage` | `Response Message` |
| `sendDocument` | `Response Message` |
| `sendInvoice` | `Response Message` — Stars (XTR) invoice |
| `answerPreCheckoutQuery` | `()` — pre-checkout answer (10 s Bot API deadline) |
| `sendImportantMessage` | `Response Message` |
| `scheduleMessage` / `scheduleMessages` | `()` |
| `setBotCommands` | `()` |
| `setMessageReaction` | `()` |
| `answerCallbackQuery` | `()` |
| `editMessageText` | `Maybe EditMessageResponse` |
| `deleteMessage` | `()` — fire-and-forget chat hygiene |

Signatures (module `LazyCircus.Scene.Telegram.Lang`; request/response types come from `Telegram.Bot.API`):

```haskell
getBotName           :: TelegramScript Text
sendMessage          :: SendMessageRequest -> TelegramScript (Response Message)
sendDocument         :: SendDocumentRequest -> TelegramScript (Response Message)
sendInvoice          :: SendInvoiceRequest -> TelegramScript (Response Message)
answerPreCheckoutQuery :: AnswerPreCheckoutQueryRequest -> TelegramScript ()
sendImportantMessage :: SendMessageRequest -> TelegramScript (Response Message)
scheduleMessage      :: SendMessageRequest -> TelegramScript ()
scheduleMessages     :: [SendMessageRequest] -> TelegramScript ()
setBotCommands       :: HashMap LangCode [(Text, Text)] -> TelegramScript ()
setMessageReaction   :: SetMessageReactionRequest -> TelegramScript ()
answerCallbackQuery  :: AnswerCallbackQueryRequest -> TelegramScript ()
editMessageText      :: EditMessageTextRequest -> TelegramScript (Maybe EditMessageResponse)
deleteMessage        :: ChatId -> MessageId -> TelegramScript ()

getFile              :: FileId -> TelegramScript (Response File)
downloadFile         :: File -> TelegramScript ByteString
downloadFileById     :: FileId -> TelegramScript (Response File, ByteString)
downloadCheckedFile  :: Integer -> FileId -> TelegramScript (Either FileValidationError (Response File, ByteString))
```

Example:

```haskell
notifyUser :: ChatId -> TelegramScript ()
notifyUser chatId = do
    botName <- getBotName
    slogInfo $ "Sending from bot: " <> botName
    _ <- sendMessage $ defSendMessage (SomeChatId chatId) "Hello"
    pure ()
```

Behavior details from the production interpreter:

- `sendImportantMessage` can schedule the message when Telegram returns HTTP 429
- scheduled messages go into the bot queue
- `editMessageText` returns `Nothing` on client error instead of throwing
- `deleteMessage` is fire-and-forget `()`; transport failures throw the typed `TelegramClientError`

## File Downloads

`downloadFileById` / `downloadCheckedFile` take a `FileId` (e.g. `documentFileId`
from an uploaded `Document`), call `getFile`, and download via the server-issued
`file_path`. They return the **raw** `Response File` plus the downloaded
`ByteString` — no domain wrapper types; the Bot API `File` carries only
id / unique_id / size / path (no MIME, no file name), so format checks are
scenario-level, decided from the bytes.

`downloadCheckedFile` gates the size twice (pure logic in
`LazyCircus.Telegram.FileCheck`, re-exported by `LazyCircus.Scene.Telegram`):

- **Gate A** — server-reported `fileFileSize` vs the limit, checked before any
  bytes are transferred (an unknown size passes through, "unknown ≠ forbidden")
- **Gate B** — the actual downloaded byte length, authoritative even when the
  server under-reported

`Left FileValidationError` (`FileSizeExceedsLimit actual limit`) is returned
**only** for size rejects; transport errors throw (guard with `runSafely`).
`telegramMaxDownloadBytes` (20 MiB) is the Telegram download ceiling; bytes are
held in memory (safe under that protocol limit). `fileSha256Hex` renders a
lowercase-hex SHA-256 of the bytes for logging/dedup.

```haskell
handleUpload :: Integer -> FileId -> TelegramScript (Either FileValidationError (Response File, ByteString))
handleUpload maxBytes fileId = downloadCheckedFile maxBytes fileId
```

Wrap Telegram scripts with `tgScript`:

```haskell
evalScript $ tgScript "demo-bot" $ sendMessage req
```

## Telegram Stars (XTR) Loop

Module `LazyCircus.Telegram.Stars` holds the pure builders that switch a Bot API
invoice into Stars mode: the Bot API does that with two request fields — an
**empty `provider_token`** and the **`XTR` currency**; the price itself is a
plain `LabeledPrice` in whole Stars.

| Function | Purpose |
|---|---|
| `mkStarsInvoiceRequest` | builds the invoice request for a chat: `providerToken = ""`, `currency = "XTR"`, payload from `starsPackagePayload`, single price line `[LabelPrice title stars]`, all optional fields unset |
| `mkPreCheckoutApproval` | approves a received pre-checkout query: `ok = True`, no error message |

```haskell
mkStarsInvoiceRequest :: ChatId -> StarsPackage -> SendInvoiceRequest
mkPreCheckoutApproval :: Text -> AnswerPreCheckoutQueryRequest   -- queryId -> ok = True
```

`StarsPackage` describes one product sold for Stars (no denomination is
hardcoded; the fiat field is for dual pricing only):

```haskell
data StarsPackage = StarsPackage
    { starsPackageTitle          :: Text -- ^ product name shown on the invoice (1-32 characters)
    , starsPackageDescription    :: Text -- ^ product description on the invoice (1-255 characters)
    , starsPackagePayload        :: Text -- ^ bot-defined payload echoed back in the successful payment (1-128 bytes)
    , starsPackageStars          :: Int  -- ^ price in whole Stars (XTR); the single price line's amount
    , starsPackageCurrencyAmount :: Int  -- ^ reference price in fiat minor units; NOT sent in the Stars invoice
    }
```

Short scenario loop (mirrors `common/StarsScenarios.hs` in the demo bot) —
invoice → approve → credit:

```haskell
-- 1. Invoice: send the Stars invoice for the package (e.g. from "/topup <payload>").
topUpInvoice botName chatId pkg =
    void $ evalScript $ tgScript botName $
        Tg.sendInvoice (mkStarsInvoiceRequest chatId pkg)

-- 2. Approve: always answer the pre-checkout query with ok = True; validation
--    happens later, idempotently, on the successful_payment update.
handlePreCheckout botName query =
    evalScript $ tgScript botName $
        Tg.answerPreCheckoutQuery (mkPreCheckoutApproval (preCheckoutQueryId query))

-- 3. Credit: insert the ledger row keyed by the charge id; the empty returning
--    list reports the UNIQUE conflict, so re-deliveries write nothing.
creditStarsPayment botName packages chatId userId payment = do
    credited <- evalScript $ dbScript simpleDb ReadWrite $
        insertStarsPaymentRow now chargeId userId stars fiatAmount payload
    case credited of
        []      -> pure DuplicateCharge   -- charge id already credited
        row : _ -> sendCreditConfirmation botName chatId pkg >> pure (CreditedNow row)
```

`creditStarsPayment` returns `CreditedStatus`: `CreditedNow row` (first
delivery, ledger row inserted), `DuplicateCharge` (re-delivery, nothing
written), or `UnknownPayload` (the invoice payload matched no package — no DB
write, no confirmation, dead-end for manual review).

### Routing: pre-checkout has no chat id

A `pre_checkout_query` update carries **no chat** (like a `poll_answer`), so it
cannot pass a chat-id gate — and it must be answered **within 10 seconds** or
the payment times out. Route it BEFORE the chat-id gate and OUTSIDE per-chat
serialisation (`withChatState`'s per-chat `MVar` lock): in the demo driver
(`BotHandler.runUpdate`) the dispatch order is `poll_answer` →
`pre_checkout_query` → chat-id gate → `withChatState`. The follow-up
`successful_payment` update is a normal chat message; the demo routes it before
document/text parsing so a top-up completes from any dialog state.

### Idempotency by DB

The recommended application pattern for crediting is idempotency by the charge
id at the storage layer (demo: the `stars_payments` ledger, whose
`telegram_payment_charge_id` column is `UNIQUE`):

- insert with `ON CONFLICT (telegram_payment_charge_id) DO NOTHING` **plus
  `RETURNING`** (`runInsertReturningList` under beam)
- empty result → the charge id was already present: no row written, report
  `DuplicateCharge` (and send no second confirmation)
- non-empty result → exactly the single inserted row: credit confirmed, then
  send the user-facing confirmation wrapped in `runSafely` so a failed send can
  never roll back or fail the already-committed credit

## Periodic Chat-Action Refresh

Telegram typing status expires after ~5 seconds, so long-running work needs a refresh tick.
Do **not** occupy an async worker with a `forever` + `threadDelay` loop — schedule a
self-re-arming one-shot timer instead:

```haskell
runAsyncAfter 4 $ refreshTick chatId
  where
    refreshTick cid = unlessM answered $ do
        evalScript $ tgScript bot $ sendChatAction cid Typing
        runAsyncAfter 4 $ refreshTick cid
```

`runAsyncAfter` is one-shot with no cancel handle: the tick re-arms itself while the answer
has not been sent, so cancelling the refresh simply means stopping to re-arm. In production
the delay is served by the timer service (see [runtime.md](runtime.md)); in tests the ticks
are captured into the `scheduledTimers` buffer — inspect with `readScheduledTimers`, execute
with `fireScheduledTimers` (see [testing.md](testing.md)).

## Review Checklist

- Is the download size limit explicit (`downloadCheckedFile` rather than raw `downloadFileById`)?
- Are only size rejects handled as `Left` (`FileValidationError`)? Transport errors are exceptions — guarded with `runSafely`.
- Is periodic chat-action refresh implemented with the re-arm pattern (`runAsyncAfter` tick that re-schedules itself) instead of a `forever`/`threadDelay` worker loop?
- Do chat-less payment updates (`pre_checkout_query`) route before the chat-id gate and outside per-chat serialisation (10-second answer deadline)?
- Is Stars-payment crediting idempotent by charge id at the DB layer (`UNIQUE` + `ON CONFLICT DO NOTHING` + `RETURNING`), with the confirmation send guarded so it cannot roll back the credit?
