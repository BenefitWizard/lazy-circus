module LazyCircus.Script (
    Script (..),
) where

import LazyCircus.DB.Types (PgDB)
import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Scene.DB.Lang (DBScript)
import LazyCircus.Scene.Mail.Lang (MailScript)
import LazyCircus.Scene.Telegram.Lang (TelegramScript)
import LazyCircus.Scenario (DbMode)
import RIO

data Script b where
    TelegramScriptDef :: Text -> TelegramScript b -> Script b
    MailScriptDef :: MailScript b -> Script b
    AIScriptDef :: AIScript b -> Script b
    DBScriptDef :: PgDB db -> DbMode -> DBScript db b -> Script b
