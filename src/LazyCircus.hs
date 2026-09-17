--   PURPOSE: Provide a top-level facade that re-exports the Script coproduct and
--   smart constructors for wrapping domain-specific scripts into the unified
--   interpreter dispatch used by ScenarioProgram.
--   SCOPE: Script coproduct re-export and smart constructors (tgScript, mailScript, aiScript, httpScript, dbScript, tenantTransaction).
--   DEPENDS: LazyCircus.Script, LazyCircus.Scene.AI.Lang, LazyCircus.Scene.DB.Lang, LazyCircus.Scene.DB.RLS, LazyCircus.Scene.Mail.Lang, LazyCircus.Scene.Telegram.Lang, LazyCircus.Scene.HTTP.Lang
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
) where

import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.DB.Lang (DBScript, withTransactionRLS)
import LazyCircus.Scene.DB.RLS (RLSContext)
import LazyCircus.Scene.HTTP.Lang (HTTPScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Scenario (DbMode (..), ScenarioProgram, evalScript)
import LazyCircus.Script (Script (..))
import RIO
import Servant.Client (BaseUrl)

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
