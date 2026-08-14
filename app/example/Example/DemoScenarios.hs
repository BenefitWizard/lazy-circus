{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Eight demonstration scenarios that exercise each Lazy Circus sub-language.
module Example.DemoScenarios (
    dbCrudScenario,
    dbAdvancedScenario,
    telegramScenario,
    mailScenario,
    aiScenario,
    loggingScenario,
    orchestrationScenario,
    fullCircusLifecycleScenario,
) where

import RIO hiding (ask, log, logError, logInfo, logWarn)
import RIO.Text (unpack)
import Data.HashMap.Strict qualified as HM


import LazyCircus.Scenario
    ( ScenarioProgram, evalScript, logInfo, logWarn, logError, logSensitive
    , getDateTime, getExtraContext, readFromExtraContext, getFeatureFlag
    , withLogContext, withLogEntry
    , throw, runSafely, runAsync
    )
import LazyCircus.Scenario (DbMode(..))
import LazyCircus.Script (Script)
import LazyCircus.Scene.DB.Lang
    ( create, createMany, find, findAll, update, delete
    , rawQuery, withTransaction, withTransactionRLS
    )
import LazyCircus.Scene.Telegram.Lang
    ( sendMessage, sendImportantMessage, scheduleMessage
    , setMessageReaction, editMessageText, getBotName
    )
import LazyCircus.Scene.Mail.Lang (sendMail, makeMail)
import LazyCircus.Scene.AI.Lang (ask)
import LazyCircus.Scene.Log (slogInfo, swithLogCtx)

import LazyCircus (tgScript, mailScript, aiScript, dbScript)
import LazyCircus.AI (mkAIRequest)
import LazyCircus.AI.POML.Types
    ( POML, cp_, role_, task_, list_, examples_, exampleInput_, exampleOutput_
    , json, text
    )
import LazyCircus.Scene.DB.RLS (rlsCircusId)

import Common

import Network.Mail.Mime (Address(..))

import Telegram.Bot.API
    ( defSendMessage
    , ChatId(..), SomeChatId(..)
    , SetMessageReactionRequest(..), MessageId(..)
    )
import Telegram.Bot.API.UpdatingMessages
    ( EditMessageTextRequest(..), defEditMessageText
    )
import Telegram.Bot.API.Types (ReactionType(..))
import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)
import Control.Exception (SomeException, toException)
import GHC.Exception (ErrorCall(..))

import Database.PostgreSQL.Simple.ToField (toField)
import Database.PostgreSQL.Simple.Types (Only(..))

-- | Helper type for decoding AI responses into a structured description.
-- Nothing means the AI declined to answer (e.g. irrelevant question).
newtype AiDescription = AiDescription { aiDescription :: Maybe Text }
    deriving (Show, Generic, FromJSON, ToJSON)


-- | Encode a positive AI answer as a POML JSON leaf.
jsonAiDescription :: Text -> POML
jsonAiDescription desc = json (AiDescription (Just desc))


-- | Encode an AI refusal (no answer) as a POML JSON leaf.
jsonAiNoDescription :: POML
jsonAiNoDescription = json (AiDescription Nothing)


-- | System prompt for the demo AI scenario, following the QuickSpell prompt structure.
demoSystemPrompt :: [POML]
demoSystemPrompt =
    [ role_ ["You are a creative circus assistant that generates vivid descriptions of circus acts."]
    , task_ ["Describe a circus act in one sentence based on the user's request."]
    , cp_
        "rules"
        [ list_
            [ ["Be concise. Use one sentence only."]
            , ["Use vivid, evocative language."]
            , ["Use the language of the question."]
            , ["Reject and do not answer irrelevant questions (unrelated to circus acts)."]
            ,
                [ "Your capabilities:"
                , list_
                    [ ["Describe any circus act (acrobatics, juggling, trapeze, magic, etc.)."]
                    , ["Generate creative names for circus acts."]
                    , ["If a request is ambiguous, make a reasonable creative assumption."]
                    ]
                ]
            , ["Output in the JSON format."]
            ]
        ]
    , examples_
        [
            [ exampleInput_ ["Describe a trapeze act."]
            , exampleOutput_ [jsonAiDescription "A daring aerialist swings high above the crowd, releasing her grip at the peak of the arc to be caught mid-air by her partner."]
            ]
        ,
            [ exampleInput_ ["Опиши номер с жонглированием."]
            , exampleOutput_ [jsonAiDescription "Жонглёр ловко подбрасывает горящие факелы, создавая огненный узор в ночном небе цирка."]
            ]
        ,
            [ exampleInput_ ["What's the weather?"]
            , exampleOutput_ [jsonAiNoDescription]
            ]
        ]
    ]

-- | Basic CRUD scenario: create, find, update, findAll, delete.
dbCrudScenario :: ScenarioProgram Script serviceLib ()
dbCrudScenario = do
    logInfo "DB CRUD: starting"
    -- Create a demo act (using CircusActT Maybe — all optional fields)
    let demoAct = CircusAct
          { circusActId = Nothing
          , circusActName = Just "Flying Trapeze"
          , circusId = Just 1
          , circusActDescription = Just "A daring aerial performance"
          , circusActAudienceReaction = Nothing
          }
    mAct <- evalScript $ dbScript simpleDb ReadWrite $ create demoAct
    case mAct of
        Nothing -> logError "DB create returned no rows"
        Just act -> do
            logInfo $ "Created act with id: " <> tshow (circusActId act)
            -- Find by id
            found <- evalScript $ dbScript simpleDb ReadWrite $ find (CircusActId (circusActId act) :: CircusActId)
            logInfo $ "Found: " <> tshow (circusActName <$> found)
            -- Update
            let patch = CircusAct
                  { circusActId = Nothing
                  , circusActName = Nothing
                  , circusId = Nothing
                  , circusActDescription = Just "Updated: An even more daring performance"
                  , circusActAudienceReaction = Just (Just "wow")
                  }
            _ <- evalScript $ dbScript simpleDb ReadWrite $ update patch (CircusActId (circusActId act) :: CircusActId)
            -- FindAll
            all_ <- evalScript $ dbScript simpleDb ReadWrite $ findAll (CircusActId (circusActId act) :: CircusActId)
            logInfo $ "findAll returned " <> tshow (length all_) <> " rows"
            -- Delete
            evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId (circusActId act) :: CircusActId)
            logInfo "DB CRUD: done"

-- | Advanced DB scenario: createMany, withTransaction, rawQuery, withTransactionRLS.
dbAdvancedScenario :: ScenarioProgram Script serviceLib ()
dbAdvancedScenario = do
    logInfo "DB Advanced: starting"
    -- CreateMany
    let acts =
          [ CircusAct Nothing (Just "Juggling") (Just 2) (Just "Fire juggling") Nothing
          , CircusAct Nothing (Just "Acrobatics") (Just 2) (Just "Contortion") Nothing
          ]
    created <- evalScript $ dbScript simpleDb ReadWrite $ createMany acts
    logInfo $ "Created " <> tshow (length created) <> " acts"
    -- WithTransaction
    result <- evalScript $ dbScript simpleDb ReadWrite $ withTransaction $ do
        slogInfo "Inside transaction"
        rows <- rawQuery "SELECT name FROM circus_acts WHERE circus_id = ?" [toField (2 :: Int32)]
        pure (rows :: [Only Text])
    logInfo $ "Transaction found " <> tshow (length result) <> " rows"
    -- WithTransactionRLS
    _ <- evalScript $ dbScript simpleDb ReadWrite $ withTransactionRLS (rlsCircusId 7) $ do
        slogInfo "Inside RLS transaction for circus_id=7"
        _ <- findAll (CircusActId 0 :: CircusActId)
        pure ()
    logInfo "DB Advanced: RLS transaction completed"
    -- Cleanup: delete the created acts
    forM_ created $ \act ->
        evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId (circusActId act) :: CircusActId)
    logInfo "DB Advanced: done"

-- | Telegram scenario: demonstrates bot-name lookup and message operations.
-- Takes a 'Maybe Text' chat ID; when Nothing, logs a warning and skips sending.
telegramScenario :: Maybe Text -> ScenarioProgram Script serviceLib ()
telegramScenario mChatId = do
    logInfo "Telegram: starting"
    case mChatId of
        Nothing -> do
            logWarn "Telegram: TG_CHAT_ID not set, skipping"
            pure ()
        Just chatId -> case readMaybe (unpack chatId) of
            Nothing -> do
                logWarn $ "Telegram: TG_CHAT_ID is not a valid integer: " <> chatId
                pure ()
            Just chatIdNum -> do
                -- Get bot name
                botName <- evalScript $ tgScript "demo-bot" $ do
                    name <- getBotName
                    slogInfo $ "Bot name: " <> name
                    pure name
                logInfo $ "Telegram bot: " <> botName
                -- Send a regular message
                let chatIdVal = ChatId chatIdNum
                let msgReq = defSendMessage (SomeChatId chatIdVal) "Hello from Lazy Circus!"
                _ <- evalScript $ tgScript "demo-bot" $ sendMessage msgReq
                -- Send an important message
                let importantReq = defSendMessage (SomeChatId chatIdVal) "Important announcement!"
                _ <- evalScript $ tgScript "demo-bot" $ sendImportantMessage importantReq
                -- Schedule a message
                let schedReq = defSendMessage (SomeChatId chatIdVal) "Scheduled greeting"
                evalScript $ tgScript "demo-bot" $ scheduleMessage schedReq
                -- Set a message reaction
                let reactionReq = SetMessageReactionRequest
                        { setMessageReactionRequestChatId = SomeChatId chatIdVal
                        , setMessageReactionRequestMessageId = MessageId 1
                        , setMessageReactionRequestReaction = Just [ReactionTypeEmoji "emoji" "👍"]
                        , setMessageReactionRequestIsBig = Nothing
                        }
                evalScript $ tgScript "demo-bot" $ setMessageReaction reactionReq
                -- Edit a message's text
                let editReq = (defEditMessageText "Edited: Hello from Lazy Circus!")
                        { editMessageTextChatId = Just (SomeChatId chatIdVal)
                        , editMessageTextMessageId = Just (MessageId 1)
                        }
                _ <- evalScript $ tgScript "demo-bot" $ editMessageText editReq
                logInfo "Telegram: scenario complete"

-- | Mail scenario: create and send a demo email.
mailScenario :: ScenarioProgram Script serviceLib ()
mailScenario = do
    logInfo "Mail: starting"
    let toAddr = Address Nothing "demo@example.com"
    _ <- evalScript $ mailScript $ do
        mail <- makeMail toAddr "Lazy Circus Demo" "Hello from Lazy Circus!"
        slogInfo "Mail created, sending..."
        sendMail mail
    logInfo "Mail: sent successfully"

-- | AI scenario: send a typed request and decode the structured response.
aiScenario :: ScenarioProgram Script serviceLib ()
aiScenario = do
    logInfo "AI: starting"
    let request = mkAIRequest
          [cp_ "Question" ["Describe a circus act in one sentence"]]
          demoSystemPrompt
    mResult <- evalScript $ aiScript $ ask request
    case mResult of
        Nothing -> logWarn "AI: no response received"
        Just desc -> logInfo $ "AI response: " <> fromMaybe "(no answer)" (aiDescription desc)
    logInfo "AI: done"

-- | Logging scenario: exercises all four log levels, context enrichment, and sub-language logging.
loggingScenario :: ScenarioProgram Script serviceLib ()
loggingScenario = do
    logInfo "Logging: starting"
    logInfo "This is an info message"
    logWarn "This is a warning message"
    logError "This is an error message"
    logSensitive "This is a sensitive message"
    -- withLogContext
    withLogContext [("scenario", "logging"), ("step", "context-test")] $ do
        logInfo "Inside enriched log context"
    -- withLogEntry
    now <- getDateTime
    withLogEntry "timestamp" now $ do
        logInfo "With timestamp context"
    -- swithLogCtx inside a DB script
    _ <- evalScript $ dbScript simpleDb ReadWrite $
        swithLogCtx [("db_log_test", "true")] $ do
            slogInfo "DB sub-language log with context"
            pure ()
    logInfo "Logging: done"

-- | Orchestration scenario: getDateTime, extra context, feature flags, throw/runSafely, runAsync.
orchestrationScenario :: ScenarioProgram Script serviceLib ()
orchestrationScenario = do
    logInfo "Orchestration: starting"
    -- getDateTime
    now <- getDateTime
    logInfo $ "Current time: " <> tshow now
    -- getExtraContext
    ctx <- getExtraContext
    logInfo $ "Extra context: " <> tshow (HM.toList ctx)
    -- readFromExtraContext
    envVal <- readFromExtraContext "env"
    logInfo $ "env = " <> tshow envVal
    -- getFeatureFlag
    enabled <- getFeatureFlag "some_flag"
    logInfo $ "some_flag enabled: " <> tshow enabled
    -- throw + runSafely
    result <- runSafely @SomeException $ do
        logInfo "Inside runSafely"
        throw $ toException (ErrorCall "Test error")
    case result of
        Left e -> logInfo $ "Caught expected error: " <> tshow (displayException e)
        Right _ -> logInfo "No error (unexpected)"
    -- runAsync
    runAsync $ do
        logInfo "Async action executed!"
    logInfo "Orchestration: done (async action may still be running)"

-- | Full lifecycle scenario: combines DB, orchestration, logging, mail, and async operations.
fullCircusLifecycleScenario :: ScenarioProgram Script serviceLib ()
fullCircusLifecycleScenario = do
    logInfo "Full Lifecycle: starting"
    -- 1. DB: Create in transaction
    mAct <- evalScript $ dbScript simpleDb ReadWrite $ withTransaction $ do
        let demoAct = CircusAct Nothing (Just "Grand Finale") (Just 3) (Just "The ultimate show") Nothing
        create demoAct
    case mAct of
        Nothing -> logError "DB create returned no rows in fullCircusLifecycleScenario"
        Just act -> do
            logInfo $ "Created act: " <> tshow (circusActId act)
            -- 2. Orchestration: check extra context
            aiEnabled <- readFromExtraContext "ai_enabled"
            logInfo $ "AI enabled: " <> tshow aiEnabled
            -- 3. Logging context
            withLogEntry "act_id" (circusActId act) $ do
                logInfo "Processing with act context"
                -- 4. Mail
                _ <- evalScript $ mailScript $ do
                    mail <- makeMail (Address Nothing "ringmaster@circus.example") "New Act Created"
                                      "A new circus act has been registered!"
                    sendMail mail
                logInfo "Notification email sent"
            -- 5. Async background task
            runAsync $ do
                logInfo "Background cleanup task started"
                evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId (circusActId act) :: CircusActId)
                logInfo "Background cleanup task done"
            -- 6. runSafely for graceful error handling
            _ <- runSafely @SomeException $ do
                logInfo "Safe section: attempting risky operation"
                _ <- evalScript $ dbScript simpleDb ReadWrite $ findAll (CircusActId (circusActId act) :: CircusActId)
                logInfo "Safe section completed"
            logInfo "Full Lifecycle: done"
