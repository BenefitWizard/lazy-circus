{-# LANGUAGE OverloadedStrings #-}
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
) where

import Control.Exception qualified as CE
import RIO hiding (ask, log, logError, logInfo, logWarn)
import RIO.Text qualified as Text
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
import Telegram.Bot.Simple.UpdateParser ()

import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Performer.Default (runDefaultPerformer, runDefaultScenario)

import BotScenarios (createActWithReaction, deleteAct, generateReaction, getAct, listActs)
import Common (CircusAct, CircusActT (..))
import Network.Mail.Mime (Address (..))

-- | Per-chat conversation state for the multi-step /newact dialog.
data ChatState
    = Idle
    | WaitingForName
    | -- | act name already received
      WaitingForDescription Text

-- | Bot model holding the current chat conversation state.
data Model = Model
    { modelChatState :: ChatState
    }

-- | Actions the bot can perform, derived from incoming Telegram updates.
data Action
    = NoAction
    | HandleStart
    | HandleNewAct
    | HandleList
    | HandleViewAct Int32
    | HandleReactAct Int32
    | HandleDeleteAct Int32
    | HandleTextMessage Text

{- | Build a telegram-bot-simple BotApp that routes commands to Lazy Circus scenarios.
PRE-CONTRACT: The 'DefaultApp' environment must be fully initialised (DB, AI, SMTP, etc.).
POST-CONTRACT: Returns a BotApp whose initial model is 'Idle'.
-}
makeBot :: DefaultApp -> Maybe Address -> BotApp Model Action
makeBot app notificationEmail =
    BotApp
        { botInitialModel = Model Idle
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
handleAction :: DefaultApp -> Maybe Address -> Action -> Model -> Eff Action Model
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
        Model WaitingForName <# do
            replyText "🎭 Enter act name:"
            return ()
    HandleList ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ runDefaultScenario listActs
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (list): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right [] -> replyText "📭 No acts found."
                Right acts -> replyText $ "🎭 Circus Acts:\n" <> Text.unlines (map formatActShort acts)
            return ()
    HandleViewAct actId ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ runDefaultScenario (getAct actId)
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
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ runDefaultScenario (generateReaction actId)
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (react): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right Nothing -> replyText "Could not generate reaction."
                Right (Just reaction) -> replyText $ "🎉 New reaction: " <> reaction
            return ()
    HandleDeleteAct actId ->
        model <# do
            result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ runDefaultScenario (deleteAct actId)
            case result of
                Left err -> do
                    liftIO $ hPutStrLn stderr $ "Bot error (delete): " ++ show err
                    replyText "❌ An internal error occurred. Please try again later."
                Right () -> replyText "🗑️ Act deleted."
            return ()
    HandleTextMessage txt -> case modelChatState model of
        Idle ->
            model <# do
                replyText "Unknown command. Use /start for help."
                return ()
        WaitingForName ->
            Model (WaitingForDescription txt) <# do
                replyText "📝 Enter act description:"
                return ()
        WaitingForDescription name ->
            Model Idle <# do
                replyText "⏳ Creating act..."
                let email = fromMaybe (Address Nothing "noreply@lazy-circus.example") notificationEmail
                result <- liftIO $ CE.try @SomeException $ runRIO app $ runDefaultPerformer $ runDefaultScenario $ createActWithReaction name txt email
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
