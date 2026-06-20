{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- | Telegram bot application definition for Lazy Circus.
Wires together the telegram-bot-simple BotApp with Lazy Circus scenarios
to provide a conversational interface for managing circus acts.
-}
module BotApp (
    Model (..),
    ChatState (..),
    Action (..),
    makeBot,
    handleUpdate,
) where

import Control.Exception qualified as CE
import Control.Monad.Except (catchError)
import RIO hiding (ask, log, logError, logInfo, logWarn)
import RIO.Text qualified as Text
import Servant.Client (ClientError)
import System.IO (hPutStrLn, stderr)

import Telegram.Bot.API (
    Update,
    messageText,
    updateMessage,
 )
import Telegram.Bot.Simple (
    BotApp (..),
    Eff,
    replyText,
    (<#),
 )
import Telegram.Bot.Simple.Eff (BotM (..))
import Telegram.Bot.Simple.UpdateParser ()

import LazyCircus.AI (Conversation, emptyConversation)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scenario (run)
import LazyCircus.Performer.Default (runDefaultPerformer)
import LazyCircus.Script (Script)

import BotScenarios (askAgentContinuing, createActWithReaction, deleteAct, generateReaction, getAct, listActs)
import Common (CircusAct, CircusActT (..))
import LazyCircus.App.Service
import Network.Mail.Mime (Address (..))
import SimpleServiceLib (AllServices)

-- | Per-chat conversation state for the multi-step /newact dialog and the agent busy-lock.
data ChatState
    = Idle
    | WaitingForName
    | -- | act name already received
      WaitingForDescription Text
    | -- | an agent turn is in flight; used as a non-reentrancy lock so a second
      -- text message arriving during the (multi-second) agent call is deferred
      -- instead of reading a stale 'modelConversation' and clobbering it.
      AgentBusy

-- | Bot model holding the current chat conversation state and the durable agent transcript.
data Model = Model
    { modelChatState :: ChatState
      -- ^ current multi-step dialog state for commands like /newact
    , modelConversation :: Conversation
      -- ^ durable agent 'Conversation' threaded across messages so tool exchanges survive
    }

-- | Actions the bot can perform, derived from incoming Telegram updates.
-- 'Show' is hand-written because 'Conversation' intentionally has no 'Show' instance.
data Action
    = NoAction
    | HandleStart
    | HandleNewAct
    | HandleList
    | HandleViewAct Int32
    | HandleReactAct Int32
    | HandleDeleteAct Int32
    | HandleTextMessage Text
    | HandleAgentDone Conversation (Maybe Text)
    -- ^ follow-up action carrying the agent's resulting 'Conversation' and optional text reply;
    -- emitted by the 'HandleTextMessage'/'Idle' branch so the pure 'Eff' model can be updated.

instance Show Action where
    show a = case a of
        NoAction -> "NoAction"
        HandleStart -> "HandleStart"
        HandleNewAct -> "HandleNewAct"
        HandleList -> "HandleList"
        HandleViewAct n -> "HandleViewAct " ++ show n
        HandleReactAct n -> "HandleReactAct " ++ show n
        HandleDeleteAct n -> "HandleDeleteAct " ++ show n
        HandleTextMessage t -> "HandleTextMessage " ++ show t
        HandleAgentDone _conv mResp -> "HandleAgentDone <Conversation> " ++ show mResp

-- | Structural equality for 'Action'. All constructors compare fully, EXCEPT
-- 'HandleAgentDone' which compares only the reply text — the carried
-- 'Conversation' intentionally has no 'Eq' instance (see "LazyCircus.AI.Conversation").
-- LAW: reflexivity: holds; for 'HandleAgentDone' equality is partial on the text only.
instance Eq Action where
    (==) = \case
        NoAction -> \case
            NoAction -> True
            _ -> False
        HandleStart -> \case
            HandleStart -> True
            _ -> False
        HandleNewAct -> \case
            HandleNewAct -> True
            _ -> False
        HandleList -> \case
            HandleList -> True
            _ -> False
        HandleViewAct a -> \case
            HandleViewAct b -> a == b
            _ -> False
        HandleReactAct a -> \case
            HandleReactAct b -> a == b
            _ -> False
        HandleDeleteAct a -> \case
            HandleDeleteAct b -> a == b
            _ -> False
        HandleTextMessage a -> \case
            HandleTextMessage b -> a == b
            _ -> False
        HandleAgentDone _ a -> \case
            HandleAgentDone _ b -> a == b
            _ -> False

{- | Build a telegram-bot-simple BotApp that routes commands to Lazy Circus scenarios.
PRE-CONTRACT: The 'DefaultApp' environment must be fully initialised (DB, AI, SMTP, etc.).
POST-CONTRACT: Returns a BotApp whose initial model is 'Idle'.
-}
makeBot :: DefaultApp AllServices -> Maybe Address -> BotApp Model Action
makeBot app notificationEmail =
    BotApp
        { botInitialModel = Model Idle emptyConversation
        , botAction = flip handleUpdate
        , botHandler = handleAction app notificationEmail
        , botJobs = []
        }

{- | Parse an incoming Telegram update into an 'Action' or 'Nothing'.
PRE-CONTRACT: None.
POST-CONTRACT: Returns 'Just' for recognised commands and text messages, 'Nothing' otherwise.
-}
handleUpdate :: Model -> Update -> Maybe Action
handleUpdate _model update = do
    txt <- updateMessage update >>= messageText
    case txt of
        "/start" -> Just HandleStart
        "/newact" -> Just HandleNewAct
        "/list" -> Just HandleList
        t
            | "/act " `Text.isPrefixOf` t -> HandleViewAct <$> parseCommandArg "/act" t
            | "/react " `Text.isPrefixOf` t -> HandleReactAct <$> parseCommandArg "/react" t
            | "/delete " `Text.isPrefixOf` t -> HandleDeleteAct <$> parseCommandArg "/delete" t
            | otherwise -> Just (HandleTextMessage txt)

{- | Handle an action by replying to the user and invoking Lazy Circus scenarios.
PRE-CONTRACT: The 'DefaultApp' environment must be fully initialised.
POST-CONTRACT: Model state is updated and replies are sent via Telegram.
-}
handleAction :: DefaultApp AllServices -> Maybe Address -> Action -> Model -> Eff Action Model
handleAction app notificationEmail action model = case action of
    NoAction ->
        model <# do
            return ()
    HandleStart ->
        model <# do
            replyText
                "🎪 Welcome to Lazy Circus Bot!\n\n\
                \Commands:\n\
                \/newact — create a new act\n\
                \/list — list all acts\n\
                \/act <id> — view act details\n\
                \/react <id> — regenerate reaction\n\
                \/delete <id> — delete an act"
            return ()
    HandleNewAct ->
        model { modelChatState = WaitingForName } <# do
            replyText "🎭 Enter act name:"
            return ()
    HandleList ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ run @Script @AllServices listActs
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (list): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right [] -> replyText "📭 No acts found."
                Right acts -> replyText $ "🎭 Circus Acts:\n" <> Text.unlines (map formatActShort acts)
            return ()
    HandleViewAct actId ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ run @Script @AllServices (getAct actId)
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (view): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right Nothing -> replyText "📭 Act not found."
                Right (Just act) -> replyText $ formatAct act
            return ()
    HandleReactAct actId ->
        model <# do
            replyText "⏳ Generating reaction..."
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ run @Script @AllServices (generateReaction actId)
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (react): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right Nothing -> replyText "Could not generate reaction."
                Right (Just reaction) -> replyText $ "🎉 New reaction: " <> reaction
            return ()
    HandleDeleteAct actId ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ run @Script @AllServices (deleteAct actId)
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (delete): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right () -> replyText "🗑️ Act deleted."
            return ()
    HandleAgentDone conv mResp ->
        model { modelConversation = conv, modelChatState = busyToIdle (modelChatState model) } <# do
            case mResp of
                Nothing  -> replyText "🤷 I couldn't process your request. Please try again."
                Just resp -> replyText resp
            return ()
    HandleTextMessage txt -> case modelChatState model of
        Idle ->
            model { modelChatState = AgentBusy } <# do
                safeReplyText "🤔 Thinking..."
                result <-
                    liftIO $ CE.try @SomeException $
                        runRIO app $ runDefaultPerformer $ run @Script @AllServices
                            (askAgentContinuing (modelConversation model) txt)
                (mResp, conv') <- case result of
                    Left e -> do
                        liftIO $ hPutStrLn stderr $ "Bot error (agent): " ++ show e
                        pure (Nothing, modelConversation model)
                    Right (r, c) -> pure (r, c)
                pure (HandleAgentDone conv' mResp)
        AgentBusy ->
            model <# do
                replyText "⏳ Still processing your previous message — please wait for the reply, then resend."
                return ()
        WaitingForName ->
            model { modelChatState = WaitingForDescription txt } <# do
                replyText "📝 Enter act description:"
                return ()
        WaitingForDescription name ->
            model { modelChatState = Idle } <# do
                replyText "⏳ Creating act..."
                let email = fromMaybe (Address Nothing "noreply@lazy-circus.example") notificationEmail
                result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ run @Script @AllServices $ createActWithReaction name txt email
                case result of
                    Left err -> do
                        liftIO $ hPutStrLn stderr $ "Bot error (create): " ++ show err
                        replyText "❌ An internal error occurred. Please try again later."
                    Right act -> replyText $ formatAct act
                return ()

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

{- | 'replyText' that swallows 'Servant.Client.ClientError' so a transient Telegram
API / network failure cannot abort the enclosing 'BotM' effect. This matters in the
'Idle' agent arm, where aborting before emitting 'HandleAgentDone' would stick the
'AgentBusy' lock permanently (the model is a single global 'TVar').
PRE-CONTRACT: None.
POST-CONTRACT: Never throws 'ClientError'; a failed reply is silently dropped (the consumer loop logs it).
-}
safeReplyText :: Text -> BotM ()
safeReplyText t =
    BotM (_runBotM (replyText t) `catchError` \(_e :: ClientError) -> pure ())

{- | Release the agent busy-lock: reset 'AgentBusy' back to 'Idle' while leaving any
unrelated chat state untouched (e.g. a /newact dialog begun while an agent turn was in flight).
PRE-CONTRACT: None.
POST-CONTRACT: 'AgentBusy' maps to 'Idle'; every other 'ChatState' is returned unchanged.
-}
busyToIdle :: ChatState -> ChatState
busyToIdle AgentBusy = Idle
busyToIdle other     = other
