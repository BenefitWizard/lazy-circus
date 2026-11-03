{-# LANGUAGE TypeApplications #-}

--   PURPOSE: Provide a top-level facade that re-exports the Script coproduct and
--   smart constructors for wrapping domain-specific scripts into the unified
--   interpreter dispatch used by ScenarioProgram.
--   SCOPE: Script coproduct re-export, smart constructors (tgScript, mailScript, aiScript, httpScript, dbScript, tenantTransaction), and Telegram delivery combinators (sendImportantMessage, sendLater).
--   DEPENDS: LazyCircus.Script, LazyCircus.Scene.AI.Lang, LazyCircus.Scene.DB.Lang, LazyCircus.Scene.DB.RLS, LazyCircus.Scene.Mail.Lang, LazyCircus.Scene.Telegram, LazyCircus.Scene.Telegram.Lang, LazyCircus.Scene.HTTP.Lang
module LazyCircus (
    -- * Script coproduct
    Script (..),
    -- * Smart constructors
    tgScript,
    mailScript,
    aiScript,
    httpScript,
    dbScript,
    tenantTransaction,
    -- * Telegram delivery combinators
    sendImportantMessage,
    sendLater,
) where

import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.DB.Lang (DBScript, withTransactionRLS)
import LazyCircus.Scene.DB.RLS (RLSContext)
import LazyCircus.Scene.HTTP.Lang (HTTPScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram (sendMessage)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Scenario (DbMode (..), ScenarioProgram, evalScript, logWarn, runAsyncAfter, runSafely, throw)
import LazyCircus.Script (Script (..))
import LazyCircus.Telegram (rateLimitRetryDelay)
import LazyCircus.Telegram.Types (TelegramApiRejected)
import RIO hiding (logWarn)
import RIO.Time (NominalDiffTime)
import Servant.Client (BaseUrl)
import Telegram.Bot.API (SendMessageRequest)

{- | Wrap a Telegram script together with the bot name it should run against.
POST-CONTRACT: Produces a Script value tagged for the Telegram interpreter and bot selection.
-}
tgScript :: Text -> TelegramScript b -> Script b
tgScript = TelegramScriptDef

{- | Wrap a mail script so it can be evaluated by ScenarioProgram.
POST-CONTRACT: Produces a Script value tagged for the mail interpreter.
-}
mailScript :: MailScript b -> Script b
mailScript = MailScriptDef

{- | Wrap an AI script so it can be evaluated by ScenarioProgram.
Uses an empty tool list for backward compatibility.
POST-CONTRACT: Produces a Script value tagged for the AI interpreter with no tools registered.
-}
aiScript :: AIScript b -> Script b
aiScript = AIScriptDef []

{- | Wrap an HTTP script together with the target base URL for servant-client execution.
POST-CONTRACT: Produces a Script value tagged for the HTTP interpreter.
-}
httpScript :: BaseUrl -> HTTPScript b -> Script b
httpScript = HTTPScriptDef

{- | Wrap a database script together with its connection descriptor and
read\/write mode so it can be evaluated by ScenarioProgram.
POST-CONTRACT: Produces a Script value tagged for the DB interpreter, to be
run against @db@ in the given 'DbMode' ('ReadWrite' or 'ReadOnly').
-}
dbScript :: PgDB db -> DbMode -> DBScript db b -> Script b
dbScript = DBScriptDef

{- | Run a database script as one tenant-scoped transaction inside a scenario.
PRE-CONTRACT: @body@ must NOT open its own @withTransaction@ /
'withTransactionRLS'. Nesting is NOT detected or rejected by the framework:
an inner transaction emits a no-op @BEGIN@ (a Postgres warning) whose @COMMIT@
ends this wrapper's transaction early — the rest of @body@ then runs outside
the transaction and without the RLS context, and a later exception no longer
rolls back the already-committed part. @body@ must not assume any RLS context
other than @ctx@ — only @ctx@ applies inside the wrapper.
POST-CONTRACT: Evaluated as one 'Script' via 'evalScript': a single ReadWrite
connection (the fixed mode is deliberate — tenant scripts are transactional
writes; use plain 'dbScript' with 'ReadOnly' for context-free reads) inside
one transaction with @ctx@ applied via @SET LOCAL rls.*@; exceptions roll the
transaction back and propagate.
-}
tenantTransaction :: PgDB db -> RLSContext -> DBScript db a -> ScenarioProgram Script serviceLib a
tenantTransaction db ctx body = evalScript $ dbScript db ReadWrite $ withTransactionRLS ctx body

{- | Send an important Telegram message: one attempt now, and when Telegram
rate-limits it (HTTP 429) an automatic deferred retry after the server-advised
@retry_after@, repeating until the message is delivered.

This is the guaranteed-delivery counterpart of a plain
@evalScript (tgScript botName (sendMessage req))@. Delivery policy is an
orchestration concern, so the retry loop is built from ordinary scenario
instructions: each retry runs as its own scenario on the async worker pool —
observable through timing logs and the test journal — and never blocks the
calling scenario.
PRE-CONTRACT: The runtime must run the timer service and the async worker pool
('LazyCircus.AsyncWorker.runTimerService' and 'runAsyncWorkerPool'); without
them the deferred retry is registered but never executed. The bot name must be
configured in the environment.
POST-CONTRACT: Returns unit after the first attempt succeeds or a retry has
been scheduled. A rate-limited attempt emits exactly one warning and registers
exactly one deferred retry, which re-runs this combinator's logic with a fresh
@retry_after@; any non-rate-limit rejection is rethrown immediately —
important delivery is retried against flood limits, not against malformed
requests. The guarantee extends until the runtime stops: pending retries are
dropped on shutdown (not persisted) and run without the original scenario's
log context.
-}
sendImportantMessage :: Text -> SendMessageRequest -> ScenarioProgram Script serviceLib ()
sendImportantMessage botName req = do
    outcome <- runSafely @TelegramApiRejected $ evalScript $ tgScript botName (sendMessage req)
    case outcome of
        Right _ -> pure ()
        Left rej
            | Just delay <- rateLimitRetryDelay rej -> do
                logWarn ("Telegram rate-limited an important send; deferred retry in " <> tshow delay)
                runAsyncAfter delay (sendImportantMessage botName req)
            | otherwise -> throw rej

{- | Send a Telegram message later: not before the delay has elapsed, on the
async worker pool. Scenario-level replacement of deferred message sending —
deferred sends stay observable (timing logs, test journal, mock timers).
PRE-CONTRACT: The runtime must run the timer service and the async worker
pool; the bot name must be configured in the environment.
POST-CONTRACT: Returns immediately after the send is registered; the message
is sent exactly once, not before the deadline. A delivery failure throws
inside the deferred worker and is invisible to this call.
-}
sendLater :: NominalDiffTime -> Text -> SendMessageRequest -> ScenarioProgram Script serviceLib ()
sendLater delay botName req =
    runAsyncAfter delay $ void $ evalScript $ tgScript botName (sendMessage req)
