-- | Coproduct of all supported script types in the Lazy Circus framework.
--
-- PURPOSE: Define the open-sum GADT that tags each domain-specific script
-- (Telegram, Mail, AI, Database) so the ScenarioProgram interpreter can
-- dispatch to the correct handler.
-- SCOPE: Script GADT definition and its constructors.
module LazyCircus.Script (
    Script (..),
) where

import LazyCircus.App.Service (ToolDescription)
import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.DB.Lang (DBScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Scenario (DbMode)
import RIO

-- | Coproduct of all supported script types.
-- Each constructor tags a domain-specific script for its corresponding
-- interpreter within 'ScenarioProgram'.
--
-- NOTE: The [ToolDescription] in AIScriptDef and the ToolCallExec in the
-- environment must correspond to the same tool set. A mismatch (tools
-- described to the model but not executable, or vice versa) is not caught
-- at compile time.
data Script b where
    TelegramScriptDef :: Text -> TelegramScript b -> Script b  -- ^ Telegram script with bot name
    MailScriptDef :: MailScript b -> Script b                  -- ^ Mail script
    AIScriptDef :: [ToolDescription] -> AIScript b -> Script b -- ^ AI script with available tool descriptions
    DBScriptDef :: PgDB db -> DbMode -> DBScript db b -> Script b -- ^ Database script with connection and mode
