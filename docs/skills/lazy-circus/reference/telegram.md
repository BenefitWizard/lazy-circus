# Lazy Circus Reference: Telegram Effect

Read this when:

- using or reviewing `TelegramScript` (module `LazyCircus.Scene.Telegram.Lang`)
- downloading files (`downloadFile`, `downloadFileById`, `downloadCheckedFile`)
- wrapping scripts with `tgScript`

## Contents

- Operations
- File Downloads
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

## Review Checklist

- Is the download size limit explicit (`downloadCheckedFile` rather than raw `downloadFileById`)?
- Are only size rejects handled as `Left` (`FileValidationError`)? Transport errors are exceptions — guarded with `runSafely`.
