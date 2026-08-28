# Lazy Circus Reference: Mail And HTTP Effects

Read this when:

- using or reviewing `MailScript` (module `LazyCircus.Scene.Mail.Lang`) or `HTTPScript` (module `LazyCircus.Scene.HTTP.Lang`)
- wrapping scripts with `mailScript` / `httpScript`

## Mail

Program type:

```haskell
type MailScript = F MailLangF
```

Main operations:

| Function | Result |
|---|---|
| `makeMail` | `Mail` |
| `sendMail` | `()` |

Signatures (module `LazyCircus.Scene.Mail.Lang`):

```haskell
makeMail :: MonadFree MailLangF m => Address -> Text -> Text -> m Mail   -- recipient, subject, body
sendMail :: MonadFree MailLangF m => Mail -> m ()
```

Example:

```haskell
welcomeMail :: Address -> MailScript ()
welcomeMail recipient = do
    mail <- makeMail recipient "Welcome" "Hello from Lazy Circus"
    slogInfo "Mail built"
    sendMail mail
```

Wrap Mail scripts with `mailScript`.

## HTTP

Program type:

```haskell
type HTTPScript = F HTTPLangF
```

Main operation:

| Function | Result |
|---|---|
| `runClient` | `Either ClientError a` |

Signature (module `LazyCircus.Scene.HTTP.Lang`):

```haskell
runClient :: MonadFree HTTPLangF m => ClientM b -> m (Either ClientError b)
```

`runClient` takes a `ClientM a` action (from servant-client) and lifts it into the HTTP script language. The result is `Either ClientError a` — `Left` for network or decode failures, `Right` for success.

Example:

```haskell
import Servant.Client (ClientM, BaseUrl(..), mkClientEnv)

fetchData :: ClientM MyData -> HTTPScript (Either ClientError MyData)
fetchData request = runClient request
```

Production HTTP behavior:

- uses the shared `httpManager` from `DefaultApp` to create a `ClientEnv`
- dispatches the servant-client action via `runClientM`
- returns `Left ClientError` on connection or decode failures

Wrap HTTP scripts with `httpScript`, passing the target `BaseUrl`:

```haskell
evalScript $ httpScript (BaseUrl Https "api.example.com" 443 "") $ runClient myRequest
```
