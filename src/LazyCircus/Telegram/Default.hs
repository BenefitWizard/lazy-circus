module LazyCircus.Telegram.Default where

import RIO
import Telegram.Bot.API

-- | Build a canned Telegram response around a supplied payload and optional error code.
defaultResponse :: Maybe Integer -> a -> Response a
defaultResponse errorCode result =
    Response
        { responseResult = result
        , responseErrorCode = errorCode
        , responseDescription = Nothing
        , responseParameters = Nothing
        , responseOk = True
        }

-- | Placeholder Telegram message used when client error handling needs a stable fallback payload.
defaultMessage :: Message
defaultMessage =
    Message
        { messageMessageId = MessageId (-1)
        , messageMessageThreadId = Nothing
        , messageFrom =
            Just $
                User
                    { userId = UserId 0
                    , userIsBot = False
                    , userFirstName = "Test"
                    , userLastName = Just "User"
                    , userUsername = Just "testuser"
                    , userLanguageCode = Just "en"
                    , userIsPremium = Just False
                    , userAddedToAttachmentMenu = Just False
                    , userCanJoinGroups = Nothing
                    , userCanReadAllGroupMessages = Nothing
                    , userSupportsInlineQueries = Nothing
                    }
        , messageDate = 1717411200 -- 2024-06-03 00:00:00 UTC
        , messageChat =
            Chat
                { chatId = ChatId (-1)
                , chatType = ChatTypePrivate
                , chatTitle = Nothing
                , chatUsername = Just "testchat"
                , chatFirstName = Just "Test"
                , chatLastName = Just "Chat"
                , chatIsForum = Nothing
                }
        , messageText = Just "This is a test message."
        , messageAutoDeleteTimerChanged = Nothing
        , messageAuthorSignature = Nothing
        , messageCaption = Nothing
        , messageCaptionEntities = Nothing
        , messageContact = Nothing
        , messageDeleteChatPhoto = Nothing
        , messageDocument = Nothing
        , messageEntities = Nothing
        , messageForwardOrigin = Nothing
        , messageForumTopicClosed = Nothing
        , messageForumTopicCreated = Nothing
        , messageForumTopicEdited = Nothing
        , messageForumTopicReopened = Nothing
        , messageGame = Nothing
        , messageGroupChatCreated = Nothing
        , messageHasProtectedContent = Nothing
        , messageInvoice = Nothing
        , messageIsAutomaticForward = Nothing
        , messageIsTopicMessage = Nothing
        , messageLeftChatMember = Nothing
        , messageLocation = Nothing
        , messageMediaGroupId = Nothing
        , messageMigrateFromChatId = Nothing
        , messageMigrateToChatId = Nothing
        , messageNewChatMembers = Nothing
        , messageNewChatPhoto = Nothing
        , messageNewChatTitle = Nothing
        , messagePassportData = Nothing
        , messagePhoto = Nothing
        , messagePinnedMessage = Nothing
        , messagePoll = Nothing
        , messageProximityAlertTriggered = Nothing
        , messageReplyMarkup = Nothing
        , messageReplyToMessage = Nothing
        , messageSenderChat = Nothing
        , messageSticker = Nothing
        , messageSuccessfulPayment = Nothing
        , messageSupergroupChatCreated = Nothing
        , messageVenue = Nothing
        , messageVideo = Nothing
        , messageVideoChatEnded = Nothing
        , messageVideoChatParticipantsInvited = Nothing
        , messageVideoChatScheduled = Nothing
        , messageVideoChatStarted = Nothing
        , messageVideoNote = Nothing
        , messageVoice = Nothing
        , messageWebAppData = Nothing
        , messageWriteAccessAllowed = Nothing
        , messageSenderBoostCount = Nothing
        , messageSenderBusinessBot = Nothing
        , messageBusinessConnectionId = Nothing
        , messageExternalReply = Nothing
        , messageQuote = Nothing
        , messageReplyToStory = Nothing
        , messageViaBot = Nothing
        , messageEditDate = Nothing
        , messageIsFromOffline = Nothing
        , messageLinkPreviewOptions = Nothing
        , messageEffectId = Nothing
        , messageAnimation = Nothing
        , messageAudio = Nothing
        , messageStory = Nothing
        , messageShowCaptionAboveMedia = Nothing
        , messageHasMediaSpoiler = Nothing
        , messageDice = Nothing
        , messageChannelChatCreated = Nothing
        , messageHasAggressiveAntiSpamEnabled = Nothing
        , messageHasHiddenMembers = Nothing
        , messageUsersShared = Nothing
        , messageChatShared = Nothing
        , messageConnectedWebsite = Nothing
        , messageBoostAdded = Nothing
        , messageChatBackgroundSet = Nothing
        , messageGeneralForumTopicHidden = Nothing
        , messageGeneralForumTopicUnhidden = Nothing
        , messageGiveawayCreated = Nothing
        , messageGiveaway = Nothing
        , messageGiveawayWinners = Nothing
        , messageGiveawayCompleted = Nothing
        }
