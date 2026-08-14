{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

{- | Bot business-logic scenarios built on Lazy Circus.
Each function is a pure 'ScenarioProgram' that orchestrates
DB, AI, Mail, and logging effects without any telegram-bot-simple specifics.
-}
module BotScenarios (
    createActWithReaction,
    listActs,
    getAct,
    generateReaction,
    deleteAct,
    AudienceReaction,
    askAgent,
    askAgentContinuing,
    AgentResponse,
) where

import RIO hiding (ask, log, logError, logInfo, logWarn)

import Common hiding (migration)
import Control.Exception (ErrorCall (..))
import Data.Aeson
import LazyCircus (aiScript, dbScript, mailScript)
import LazyCircus.AI (AIRequest, Conversation, emptyConversation, mkAgentRequest, mkAIRequest)
import LazyCircus.AI.POML.Types (
    POML,
    cp_,
    exampleInput_,
    exampleOutput_,
    examples_,
    json,
    list_,
    role_,
    task_,
    text,
 )
import LazyCircus.Scenario (DbMode (..), ScenarioProgram, evalScript, logError, logInfo, logWarn, runAsync, runSafely, throw, withLogContext)
import LazyCircus.Scene.AI.Lang (ask, solveWithAgentContinuing)
import SimpleServiceLib (aiScriptWithAll)
import LazyCircus.Scene.DB.Lang (
    create,
    delete,
    find,
    rawQuery,
    update,
 )
import LazyCircus.Scene.Mail.Lang (makeMail, sendMail)
import LazyCircus.Script (Script)
import Network.Mail.Mime (Address (..))

-- | AI response type for audience reaction generation.
newtype AudienceReaction = AudienceReaction {audienceReaction :: Text}
    deriving (Show, Generic)

instance FromJSON AudienceReaction where
    parseJSON = withObject "AudienceReaction" $ \v ->
        AudienceReaction <$> v .: "reaction"

instance ToJSON AudienceReaction where
    toJSON (AudienceReaction reaction) =
        object ["reaction" .= reaction]

-- | Encode a positive audience reaction as a POML JSON leaf.
jsonAudienceReaction :: Text -> POML
jsonAudienceReaction reaction = json (AudienceReaction reaction)

-- | AI agent response containing the final text answer produced by the ReAct loop.
-- The model must output JSON matching @{"agentResponseText": "..."}@.
newtype AgentResponse = AgentResponse
    { agentResponseText :: Text -- ^ the final natural-language answer from the agent
    }
    deriving (Show, Generic, FromJSON, ToJSON)

-- | System prompt for the agent loop, instructing the model to use available tools.
circusAgentSystemPrompt :: [POML]
circusAgentSystemPrompt =
    [ role_ ["You are a helpful circus assistant that can perform calculations and process expressions."]
    , task_ ["Answer the user's question using the available tools when needed."]
    , cp_
        "rules"
        [ list_
            [ ["Use the provided tools for any arithmetic or expression operations."]
            , ["Chain multiple tool calls if needed (e.g., for (a+b)-c)."]
            , ["When you have the final answer, respond with a JSON object containing your answer."]
            , ["CRITICAL: Your final response MUST be valid JSON — no markdown, no backticks, no explanation outside JSON."]
            , ["If you answer without tools, still respond as JSON."]
            , ["Use the language of the user's query for your response."]
            ]
        ]
    , examples_
        [
            [ exampleInput_ ["What is 2 + 3?"]
            , exampleOutput_ [json (AgentResponse "The result of 2 + 3 is 5.")]
            ]
        ,
            [ exampleInput_ ["Calculate (10 - 4) + 7"]
            , exampleOutput_ [json (AgentResponse "The result of (10 - 4) + 7 is 13.")]
            ]
        ,
            [ exampleInput_ ["What tools do you have?"]
            , exampleOutput_ [json (AgentResponse "I have three tools: add_numbers, subtract_numbers, and add_expression.")]
            ]
        ]
    ]

-- | Maximum number of ReAct iterations for the agent loop.
-- POST-CONTRACT: Positive natural number.
defaultAgentMaxIterations :: Natural
defaultAgentMaxIterations = 10

{- | Continuing version of 'askAgent': threads a 'Conversation' through the agent
loop and keeps the last-known-good transcript on any failure.
PRE-CONTRACT: The input 'Conversation' does not contain a leading 'Chat.System' message (see the 'Conversation' invariant).
POST-CONTRACT: Returns @(Just resp, conv')@ on success (conv' is the updated transcript including tool exchanges). On exception or no-response, returns @(Nothing, <input conv>)@ — the transcript is NOT overwritten.
-}
askAgentContinuing :: Conversation -> Text -> ScenarioProgram Script serviceLib (Maybe Text, Conversation)
askAgentContinuing conv userQuery =
    withLogContext [("query", userQuery)] $ do
        logInfo "Agent: processing query (continuing)"
        let req = mkAgentRequest [text userQuery] circusAgentSystemPrompt defaultAgentMaxIterations
        eitherResult <- runSafely @SomeException $
            evalScript $ aiScriptWithAll $ solveWithAgentContinuing req conv
        case eitherResult of
            Left _ -> do
                logError "Agent: exception during agent loop (keeping last-known-good)"
                pure (Nothing, conv)
            Right (mResult, conv') -> case mResult of
                Just (AgentResponse resp) -> pure (Just resp, conv')
                Nothing -> do
                    logWarn "Agent: no response (keeping last-known-good)"
                    pure (Nothing, conv)

{- | Send a user query to the AI agent loop for autonomous tool use (stateless).
PRE-CONTRACT: The AI service must be configured and tool descriptions/exec must be set on the app.
POST-CONTRACT: Returns 'Just' the agent's text response, or 'Nothing' if the agent fails to converge. The resulting 'Conversation' is discarded (see 'askAgentContinuing' for the stateful form).
-}
askAgent :: Text -> ScenarioProgram Script serviceLib (Maybe Text)
askAgent userQuery = fst <$> askAgentContinuing emptyConversation userQuery

-- | System prompt for audience reaction generation, following the QuickSpell prompt structure.
reactionSystemPrompt :: [POML]
reactionSystemPrompt =
    [ role_ ["You are an enthusiastic circus audience member who reacts to circus performances."]
    , task_ ["Generate a short audience reaction (one sentence) for the circus act described by the user."]
    , cp_
        "rules"
        [ list_
            [ ["Be concise. Use one sentence only."]
            , ["Be expressive and emotional — you are a spectator, not a critic."]
            , ["Use the language of the act description."]
            ,
                [ "Your capabilities:"
                , list_
                    [ ["React to any circus act (acrobatics, juggling, trapeze, magic, animal acts, clowns, etc.)."]
                    , ["Express surprise, delight, awe, fear, laughter — whatever fits the act."]
                    , ["Use vivid, evocative language."]
                    ]
                ]
            , ["Output in the JSON format."]
            ]
        ]
    , examples_
        [
            [ exampleInput_ ["Act: \"Flying Trapeze\" — A daring aerial performance"]
            , exampleOutput_ [jsonAudienceReaction "The crowd gasps as the aerialist lets go, then erupts in cheers when she is caught mid-air!"]
            ]
        ,
            [ exampleInput_ ["Act: \"Fire Juggling\" — Juggling flaming torches in the dark"]
            , exampleOutput_ [jsonAudienceReaction "The audience holds its breath as the juggler tosses fire into the night sky, mesmerized by the dancing flames."]
            ]
        ,
            [ exampleInput_ ["Номер: «Клоунская пантомима» — Весёлый клоун разыгрывает сценку"]
            , exampleOutput_ [jsonAudienceReaction "Зал взрывается хохотом, когда клоун спотыкается о невидимую ступеньку!"]
            ]
        ]
    ]

-- | Build the user-prompt fragment containing the act name and description.
reactionUserPrompt :: Text -> Text -> [POML]
reactionUserPrompt name desc =
    [ cp_ "Act" [text $ "\"" <> name <> "\" — " <> desc]
    ]

-- | Build an AI request that asks for a short audience reaction for the given act.
mkReactionRequest :: Text -> Text -> AIRequest AudienceReaction
mkReactionRequest name desc =
    mkAIRequest (reactionUserPrompt name desc) reactionSystemPrompt

{- | Create a circus act, generate an AI audience reaction, update the act, and send a notification email.
PRE-CONTRACT: A valid SMTP and AI configuration must be available at runtime.
POST-CONTRACT: Returns the created act with the AI-generated audience reaction when successful.
-}
createActWithReaction :: Text -> Text -> Address -> ScenarioProgram Script serviceLib CircusAct
createActWithReaction name desc notificationEmail = do
    withLogContext [("act_name", name)] $ do
        logInfo "Creating act"
        -- 1. Create the act in the DB
        let newAct =
                CircusAct
                    { circusActId = Nothing
                    , circusActName = Just name
                    , circusId = Just 1
                    , circusActDescription = Just desc
                    , circusActAudienceReaction = Nothing
                    }
        mAct <- evalScript $ dbScript simpleDb ReadWrite $ create newAct
        act <- case mAct of
            Nothing -> do
                logError "DB create returned no rows"
                throw $ ErrorCall "DB create returned no rows"
            Just a -> pure a
        -- 2. Ask AI for a reaction (safely)
        mReaction <- runSafely @SomeException $ do
            mResult <- evalScript $ aiScript $ ask (mkReactionRequest name desc)
            case mResult of
                Nothing -> do
                    logWarn "AI returned no response for audience reaction"
                    pure Nothing
                Just (AudienceReaction reaction) -> pure (Just reaction)
        -- 3. Update the act if a reaction was generated
        finalAct <- case mReaction of
            Left _ -> do
                logWarn "Failed to generate audience reaction"
                pure act
            Right Nothing -> pure act
            Right (Just reaction) -> do
                let patch =
                        CircusAct
                            { circusActId = Nothing
                            , circusActName = Nothing
                            , circusId = Nothing
                            , circusActDescription = Nothing
                            , circusActAudienceReaction = Just (Just reaction)
                            }
                _ <- evalScript $ dbScript simpleDb ReadWrite $ update patch (CircusActId $ circusActId act)
                pure act{circusActAudienceReaction = Just reaction}
        -- 4. Send email notification asynchronously
        runAsync $ do
            evalScript $ mailScript $ do
                mail <- makeMail notificationEmail "New Circus Act Created" ("Act '" <> name <> "' has been created!")
                sendMail mail
        pure finalAct

{- | List all circus acts ordered by id.
PRE-CONTRACT: The circus_acts table must exist.
POST-CONTRACT: Returns all acts in id order.
-}
listActs :: ScenarioProgram Script serviceLib [CircusAct]
listActs = do
    evalScript
        $ dbScript simpleDb ReadOnly
        $ rawQuery "SELECT id, name, circus_id, description, audience_reaction FROM circus_acts ORDER BY id" []

{- | Look up a single circus act by its id.
PRE-CONTRACT: None.
POST-CONTRACT: Returns Just the act when found, Nothing otherwise.
-}
getAct :: Int32 -> ScenarioProgram Script serviceLib (Maybe CircusAct)
getAct actId = do
    evalScript $ dbScript simpleDb ReadOnly $ find (CircusActId actId :: CircusActId)

{- | Generate (or regenerate) an AI audience reaction for an existing act.
PRE-CONTRACT: The act with the given id must exist.
POST-CONTRACT: Returns Just the reaction text when successful, Nothing otherwise.
-}
generateReaction :: Int32 -> ScenarioProgram Script serviceLib (Maybe Text)
generateReaction actId = do
    mAct <- evalScript $ dbScript simpleDb ReadOnly $ find (CircusActId actId :: CircusActId)
    case mAct of
        Nothing -> do
            logWarn $ "Act not found for id: " <> tshow actId
            pure Nothing
        Just act -> do
            mResult <- runSafely @SomeException $ do
                evalScript $ aiScript $ ask (mkReactionRequest (circusActName act) (circusActDescription act))
            case mResult of
                Left _ -> do
                    logWarn "Failed to generate audience reaction"
                    pure Nothing
                Right Nothing -> do
                    logWarn "AI returned no response for audience reaction"
                    pure Nothing
                Right (Just (AudienceReaction reaction)) -> do
                    let patch =
                            CircusAct
                                { circusActId = Nothing
                                , circusActName = Nothing
                                , circusId = Nothing
                                , circusActDescription = Nothing
                                , circusActAudienceReaction = Just (Just reaction)
                                }
                    _ <- evalScript $ dbScript simpleDb ReadWrite $ update patch (CircusActId actId :: CircusActId)
                    pure (Just reaction)

{- | Delete a circus act by its id.
PRE-CONTRACT: None.
POST-CONTRACT: The act is removed from the database.
-}
deleteAct :: Int32 -> ScenarioProgram Script serviceLib ()
deleteAct actId = do
    evalScript $ dbScript simpleDb ReadWrite $ delete (CircusActId actId :: CircusActId)
