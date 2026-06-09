--   PURPOSE: Provide a top-level facade that re-exports the Script coproduct and
--   smart constructors for wrapping domain-specific scripts into the unified
--   interpreter dispatch used by ScenarioProgram.
--   SCOPE: Script coproduct re-export and smart constructors (tgScript, mailScript, aiScript, httpScript).
--   DEPENDS: LazyCircus.Script, LazyCircus.Scene.AI.Lang, LazyCircus.Scene.Mail.Lang, LazyCircus.Scene.Telegram.Lang, LazyCircus.Scene.HTTP.Lang
module LazyCircus (
    -- * Script coproduct
    Script (..),
    -- * Smart constructors
    tgScript,
    mailScript,
    aiScript,
    httpScript,
) where

import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.HTTP.Lang (HTTPScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
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
