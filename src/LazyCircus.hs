module LazyCircus (
    -- * Script coproduct
    Script (..),
    -- * Smart constructors
    tgScript,
    mailScript,
    aiScript,
) where

import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Script (Script (..))
import RIO

{- | Wrap a Telegram script together with the bot name it should run against.
PRE-CONTRACT: None
POST-CONTRACT: Produces a Script value tagged for the Telegram interpreter and bot selection.
-}
tgScript :: Text -> TelegramScript b -> Script b
tgScript = TelegramScriptDef

{- | Wrap a mail script so it can be evaluated by ScenarioProgram.
PRE-CONTRACT: None
POST-CONTRACT: Produces a Script value tagged for the mail interpreter.
-}
mailScript :: MailScript b -> Script b
mailScript = MailScriptDef

{- | Wrap an AI script so it can be evaluated by ScenarioProgram.
PRE-CONTRACT: None
POST-CONTRACT: Produces a Script value tagged for the AI interpreter.
-}
aiScript :: AIScript b -> Script b
aiScript = AIScriptDef
