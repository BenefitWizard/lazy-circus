{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- | Telegram update handler for the Lazy Circus bot.

'handleScenario' runs entirely inside 'ScenarioProgram'. Replies go through the
TelegramScript DSL ('Tg.sendMessage') rather than telegram-bot-simple's
@replyText@, so they share the same client environment, bot-name routing,
structured logging, and automatic timing as every other Lazy Circus Telegram
effect.

= Concurrency model (AgentBusy note)

The production bot dispatches each Telegram update fire-and-forget (its own
thread) via 'Telegram.Bot.Extra.Polling.runPollingBot'.
'ChatStateStore.withChatState' serialises updates /per chat/ (an 'MVar' per
'ChatId'), so a second message arriving on the SAME chat while the first is
still processing will QUEUE on that chat's lock and run only after the first
completes. Different chats run in parallel.

'handleScenario' runs the entire update — including any multi-second AI\/agent
call — synchronously and returns the final 'Model'. This is intentional and is
SAFER than a busy-lock design: because an exception in the scenario restores the
original 'Model' (via 'modifyMVar' inside 'withChatState') and always releases
the per-chat lock, a transient Telegram\/AI failure can NO LONGER leave a stuck
lock. As a result the 'Idle' text branch processes the agent call inline and
does NOT transition through 'BotApp.AgentBusy'; the 'BotApp.AgentBusy' branch in
'handleTextMessage' is kept only as defensive code and, under the normal
per-chat serialisation, is effectively unreachable.
-}
module BotHandler (
    BotHandlerConfig (..),
    handleScenario,
    runUpdate,
    updateAction,
    ) where

import RIO hiding (log, logError, logInfo, logWarn)
import RIO.Text qualified as Text

import Network.Mail.Mime (Address (..))
import System.IO (hPutStrLn)

import Telegram.Bot.API (
    ChatId,
    SomeChatId (..),
    Update,
    defSendMessage,
    messageText,
    updateMessage,
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)

import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Scene.Telegram.Lang qualified as Tg (sendMessage)
import LazyCircus.Scenario (ScenarioProgram, evalScript, logError, run, runSafely)
import LazyCircus.Script (Script)
import SimpleServiceLib (AllServices)

import BotApp (ChatState (..), Model (..))
import BotScenarios (
    askAgentContinuing,
    createActWithReaction,
    deleteAct,
    generateReaction,
    getAct,
    listActs,
    )
import ChatStateStore (ChatStateStore, withChatState)
import Common (CircusAct, CircusActT (..))

-- | Bundle of per-bot parameters consumed by 'handleScenario' and 'updateAction'.
data BotHandlerConfig = BotHandlerConfig
    { bhcBotName :: Text
      -- ^ logical bot name registered in the app's @botEnvs@ (the demo registers @"demo-bot"@)
    , bhcNotificationEmail :: Maybe Address
      -- ^ sender address used for act-creation notification emails; falls back to a default when 'Nothing'
    }

{- | Migrated bot update handler that runs entirely inside 'ScenarioProgram'.

Replaces the old telegram-bot-simple @BotApp.handleAction@. Replies are sent
through the TelegramScript DSL ('Tg.sendMessage') so they share the bot's
client environment, structured logging, and automatic timing. Branch logic,
reply strings, and FSM transitions are preserved verbatim from the previous
implementation.

See the module Haddock for the /AgentBusy note/: the handler processes each
update synchronously and relies on 'ChatStateStore' for per-chat serialisation
rather than maintaining an 'AgentBusy' non-reentrancy lock.

PRE-CONTRACT: The caller wraps this with @runDefaultPerformer . run@ against a
'DefaultApp' whose @botEnvs@ contains the bot named by 'bhcBotName'.
POST-CONTRACT: Returns the updated 'Model' paired with @()@. Updates without a
chat id or message text are no-ops and return the input model unchanged.
-}
handleScenario ::
    BotHandlerConfig ->
    Model ->
    Update ->
    ScenarioProgram Script serviceLib (Model, ())
handleScenario cfg model update =
    case updateChatId update of
        Nothing -> pure (model, ())
        Just chatId ->
            case updateMessage update >>= messageText of
                Nothing -> pure (model, ())
                Just txt -> dispatch cfg model chatId txt

{- | Route a recognised text message to the matching command or dialog branch.
Mirrors the previous @BotApp.handleUpdate@ prefix-matching exactly.
PRE-CONTRACT: 'txt' is the incoming message text (non-'Nothing').
POST-CONTRACT: Returns the updated 'Model' paired with @()@; malformed command
arguments (e.g. @/act abc@) are silently ignored, matching the prior behaviour.
-}
dispatch ::
    BotHandlerConfig ->
    Model ->
    ChatId ->
    Text ->
    ScenarioProgram Script serviceLib (Model, ())
dispatch cfg model chatId txt =
    case txt of
        "/start" -> do
            replyTxt cfg chatId welcomeText
            pure (model, ())
        "/newact" -> do
            replyTxt cfg chatId "🎭 Enter act name:"
            pure (model{modelChatState = WaitingForName}, ())
        "/list" -> do
            result <- runSafely @SomeException listActs
            case result of
                Left e -> do
                    logError ("listActs failed: " <> tshow e)
                    replyTxt cfg chatId "❌ An internal error occurred. Please try again later."
                Right [] -> replyTxt cfg chatId "📭 No acts found."
                Right acts ->
                    replyTxt cfg chatId $ "🎭 Circus Acts:\n" <> Text.unlines (map formatActShort acts)
            pure (model, ())
        t
            | "/act " `Text.isPrefixOf` t ->
                case parseCommandArg "/act" t of
                    Nothing -> pure (model, ())
                    Just actId -> do
                        result <- runSafely @SomeException (getAct actId)
                        case result of
                            Left e -> do
                                logError ("getAct failed: " <> tshow e)
                                replyTxt cfg chatId "❌ An internal error occurred. Please try again later."
                            Right Nothing -> replyTxt cfg chatId "📭 Act not found."
                            Right (Just act) -> replyTxt cfg chatId (formatAct act)
                        pure (model, ())
            | "/react " `Text.isPrefixOf` t ->
                case parseCommandArg "/react" t of
                    Nothing -> pure (model, ())
                    Just actId -> do
                        replyTxt cfg chatId "⏳ Generating reaction..."
                        result <- runSafely @SomeException (generateReaction actId)
                        case result of
                            Left e -> do
                                logError ("generateReaction failed: " <> tshow e)
                                replyTxt cfg chatId "❌ An internal error occurred. Please try again later."
                            Right Nothing -> replyTxt cfg chatId "Could not generate reaction."
                            Right (Just reaction) -> safeReplyTxt cfg chatId ("🎉 New reaction: " <> reaction)
                        pure (model, ())
            | "/delete " `Text.isPrefixOf` t ->
                case parseCommandArg "/delete" t of
                    Nothing -> pure (model, ())
                    Just actId -> do
                        result <- runSafely @SomeException (deleteAct actId)
                        case result of
                            Left e -> do
                                logError ("deleteAct failed: " <> tshow e)
                                replyTxt cfg chatId "❌ An internal error occurred. Please try again later."
                            Right () -> replyTxt cfg chatId "🗑️ Act deleted."
                        pure (model, ())
            | otherwise -> handleTextMessage cfg model chatId txt

{- | Handle a free-form text message, routing on the current dialog 'ChatState'.
PRE-CONTRACT: 'txt' is the incoming message text (non-'Nothing').
POST-CONTRACT: Returns the updated 'Model' paired with @()@; see the module
Haddock for the 'AgentBusy' serialisation rationale.
-}
handleTextMessage ::
    BotHandlerConfig ->
    Model ->
    ChatId ->
    Text ->
    ScenarioProgram Script serviceLib (Model, ())
handleTextMessage cfg model chatId txt =
    case modelChatState model of
        Idle -> do
            replyTxt cfg chatId "🤔 Thinking..."
            (mResp, conv') <- askAgentContinuing (modelConversation model) txt
            case mResp of
                Nothing -> safeReplyTxt cfg chatId "🤷 I couldn't process your request. Please try again."
                Just resp -> safeReplyTxt cfg chatId resp
            pure (model{modelConversation = conv'}, ())
        AgentBusy -> do
            replyTxt cfg chatId "⏳ Still processing your previous message — please wait for the reply, then resend."
            pure (model, ())
        WaitingForName -> do
            replyTxt cfg chatId "📝 Enter act description:"
            pure (model{modelChatState = WaitingForDescription txt}, ())
        WaitingForDescription name -> do
            replyTxt cfg chatId "⏳ Creating act..."
            let email = fromMaybe (Address Nothing "noreply@lazy-circus.example") (bhcNotificationEmail cfg)
            result <- runSafely @SomeException (createActWithReaction name txt email)
            case result of
                Left e -> do
                    logError ("createActWithReaction failed: " <> tshow e)
                    replyTxt cfg chatId "❌ An internal error occurred. Please try again later."
                Right act -> safeReplyTxt cfg chatId (formatAct act)
            pure (model{modelChatState = Idle}, ())

{- | Send a plain Telegram text reply to the given chat through the TelegramScript DSL.
PRE-CONTRACT: The enclosing 'ScenarioProgram' is run against a 'DefaultApp'
whose @botEnvs@ contains the bot named by 'bhcBotName'.
POST-CONTRACT: The message is dispatched via the Telegram interpreter; the
resulting 'Telegram.Bot.API.Response' is discarded.
-}
replyTxt :: BotHandlerConfig -> ChatId -> Text -> ScenarioProgram Script serviceLib ()
replyTxt cfg chatId txt =
    void $
        evalScript $
            tgScript (bhcBotName cfg) $
                Tg.sendMessage (defSendMessage (SomeChatId chatId) txt)

{- | Send a reply whose failure must NOT abort the surrounding flow.
-- 'replyTxt' failures (a transient Telegram API / network error) are swallowed
-- so that a reply that follows a durable, non-idempotent side effect — such as
-- an act creation, a reaction regeneration, or an agent turn that advanced the
-- 'Conversation' — cannot roll back the 'Model' (via 'withChatState'\'s
-- restore-on-exception) and cause the user's retry to re-run that side effect.
-- Use 'replyTxt' for replies that precede any side effect (progress
-- indicators) or follow idempotent / read-only work.
-- PRE-CONTRACT: The enclosing 'ScenarioProgram' is run against a 'DefaultApp'
-- whose @botEnvs@ contains the bot named by 'bhcBotName'.
-- POST-CONTRACT: Never throws a synchronous Telegram-send failure; the send's
-- 'Response' is discarded.
-}
safeReplyTxt :: BotHandlerConfig -> ChatId -> Text -> ScenarioProgram Script serviceLib ()
safeReplyTxt cfg chatId txt =
    void $ runSafely @SomeException $ replyTxt cfg chatId txt

-- | Welcome and command-list message sent on the @/start@ command.
welcomeText :: Text
welcomeText =
    "🎪 Welcome to Lazy Circus Bot!\n\n\
    \Commands:\n\
    \/newact — create a new act\n\
    \/list — list all acts\n\
    \/act <id> — view act details\n\
    \/react <id> — regenerate reaction\n\
    \/delete <id> — delete an act"

{- | Performer-agnostic driver that turns one 'Update' into one bot turn.

Resolves the chat id, loads the per-chat 'Model' from the 'ChatStateStore'
(serialising updates for that chat under its 'MVar'), runs 'handleScenario' via
the supplied @runScenario@ runner, and stores the resulting 'Model' back.
Updates without a chat id are logged to stderr and dropped.

Production and the @tgTest@ runner share this exact driver: they differ only in
the @runScenario@ argument. Production passes the default performer; the test
runner passes the test performer (which mocks Telegram\/AI\/mail and publishes
replies to its STM mailbox). That is how the test exercises the bot's ordinary
script with everything mocked — see @LazyCircus.Testing.TgTest@.

PRE-CONTRACT: @runScenario@ runs a 'ScenarioProgram' to completion in 'IO' and
returns its result; @store@ is shared across all dispatch threads for the
lifetime of the bot.
POST-CONTRACT: The chat's 'Model' is updated atomically; on exception the
original 'Model' is restored (see 'withChatState').
-}
runUpdate ::
    (ScenarioProgram Script AllServices (Model, ()) -> IO (Model, ())) ->
    BotHandlerConfig ->
    ChatStateStore ->
    Update ->
    IO ()
runUpdate runScenario cfg store update =
    case updateChatId update of
        Nothing -> hPutStrLn stderr "Bot update without chat id"
        Just chatId ->
            withChatState store chatId $ \model ->
                runScenario (handleScenario cfg model update)

{- | Production 'Update -> IO ()' seam: 'runUpdate' wired with the default
performer stack. The polling\/webhook bot dispatches this fire-and-forget.

PRE-CONTRACT: 'app' is a fully initialised 'DefaultApp' whose @botEnvs@
contains the bot named by 'bhcBotName'.
POST-CONTRACT: The chat's 'Model' is updated atomically; on exception the
original 'Model' is restored (see 'withChatState').
-}
updateAction :: BotHandlerConfig -> ChatStateStore -> DefaultApp AllServices -> Update -> IO ()
updateAction cfg store app = runUpdate (runRIO app . runDefaultPerformer . run @Script @AllServices) cfg store

{- | Format a CircusAct for detailed display.
PRE-CONTRACT: None.
POST-CONTRACT: Result is a human-readable multi-line text representation.
-}
formatAct :: CircusAct -> Text
formatAct act =
    "🎭 Act #"
        <> tshow (circusActId act)
        <> "\n  Name: "
        <> circusActName act
        <> "\n  Description: "
        <> circusActDescription act
        <> "\n  Reaction: "
        <> fromMaybe "(none)" (circusActAudienceReaction act)

{- | Format a CircusAct as a single line for list display.
PRE-CONTRACT: None.
POST-CONTRACT: Result is a compact single-line representation.
-}
formatActShort :: CircusAct -> Text
formatActShort act = "#" <> tshow (circusActId act) <> " " <> circusActName act

{- | Parse an Int32 argument from a command like "/act 42".
PRE-CONTRACT: The prefix must be present in the text (not checked here).
POST-CONTRACT: Returns 'Just' the parsed number, or 'Nothing' on failure.
-}
parseCommandArg :: Text -> Text -> Maybe Int32
parseCommandArg prefix txt = do
    let rest = Text.drop (Text.length prefix + 1) txt
    readMaybe (Text.unpack rest)
