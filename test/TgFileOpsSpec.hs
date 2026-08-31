{-# LANGUAGE OverloadedStrings #-}

{- | End-to-end spec for the Telegram file operations (T12): size-gated
download ('downloadCheckedFile') and message deletion ('deleteMessage') driven
through the @tgTest@ mock infrastructure via the demo 'handleDocumentUpload'
scenario, plus a direct e2e of the raw 'downloadFileById' composite (which
applies NO size gating, unlike its checked sibling), and an e2e proving the
client-declared document metadata (@file_name@ / @mime_type@ / @file_size@)
delivered via 'sendDocumentAs' reaches the scenario's 'Document' — the pattern
metadata-based (format/size) pre-checks are tested with.

Each test wires its own action builder into 'tgTest': the builder injects
canned downloads into the SAME 'Mocks' the runner hands it (the classic tgTest
pitfall) and runs the scenario under test under the test performer against the
test-chosen wiring — 'buildFileOpsAction' invokes 'handleDocumentUpload' with a
test-chosen size limit (the production handler uses a fixed 5 MB limit, so the
gate-A rejection matrix needs the scenario invoked directly with a small one),
while 'buildDirectDownloadAction' runs a spec-local scenario over
'downloadFileById'.
-}
module TgFileOpsSpec (spec) where

import RIO
import RIO.ByteString qualified as BS
import RIO.Text qualified as Text
import Test.Hspec

import BotScenarios (handleDocumentUpload)
import LazyCircus (tgScript)
import LazyCircus.App.Default (DefaultApp)
import LazyCircus.Scenario (ScenarioProgram, evalScript)
import LazyCircus.Scene.Telegram (downloadFileById, fileSha256Hex, sendMessage)
import LazyCircus.Script (Script)
import LazyCircus.Telegram (fileDownloadUrl)
import LazyCircus.Testing.Performer
    ( Mocks
    , TestConfig
    , addTgDownloads
    , runScenarioProgram
    , runWithConfig
    , tgMock
    )
import LazyCircus.Testing.TgTest
    ( Mailboxes
    , TgTestError
    , TelegramTestScript
    , defaultTgTestConfig
    , guardWith
    , sendDocumentAs
    , sendFile
    , tgTest
    , waitForDeletion
    , waitForReply
    )
import Servant.Client (BaseUrl (..), Scheme (..))
import SimpleServiceLib (AllServices)
import Telegram.Bot.API
    ( ChatId
    , SomeChatId (..)
    , Update
    , defSendMessage
    , documentFileId
    , documentFileName
    , documentFileSize
    , documentMimeType
    , messageDocument
    , messageMessageId
    , updateMessage
    )
import Telegram.Bot.API.GettingUpdates (updateChatId)
import Telegram.Bot.API.Types (Document, FileId (..))
import TestHelpers.Bot (withBotTestApp)

-- | The file id used for correlation between the injected canned download and
-- the upload update (NOT the placeholder 'LazyCircus.Testing.TgTest.waitForFile'
-- returns).
docFileId :: FileId
docFileId = FileId "doc-1"

-- | Recognizable text content for the happy-path download.
docBytes :: ByteString
docBytes = "hello lazy circus document"

-- | Payload longer than the rejection test's limit (40 bytes vs 10).
oversizeBytes :: ByteString
oversizeBytes = BS.pack (replicate 40 0x41)

-- | Arbitrary non-UTF-8-decodable binary content for the no-format-validation pin.
binaryBytes :: ByteString
binaryBytes = BS.pack [0xDE, 0xAD, 0xBE, 0xEF]

-- | The file id used by the raw 'downloadFileById' composite test (distinct
-- from 'docFileId' so the two fixtures cannot be confused in a stale-mock bug).
directFileId :: FileId
directFileId = FileId "doc-direct"

-- | 30 canned bytes for the raw-composite test: deliberately LONGER than the
-- 10-byte limit the gate-A rejection test uses, proving 'downloadFileById'
-- applies no size gating of its own.
directBytes :: ByteString
directBytes = BS.pack (replicate 30 0x42)

-- | The 16-hex-char digest prefix the scenario includes in acceptance replies,
-- computed with the library's own 'fileSha256Hex' (no hand-rolled hashing here).
shaPrefixOf :: ByteString -> Text
shaPrefixOf = Text.take 16 . fileSha256Hex

-- | Build the bot's @Update -> IO ()@ action for this spec: injects the canned
-- downloads into the supplied mocks and, on every document update, runs
-- 'handleDocumentUpload' with the test-chosen limit under the test performer
-- against the SAME mocks the runner observes (the sharing is the point).
buildFileOpsAction ::
    DefaultApp AllServices ->
    Integer ->
    [(FileId, ByteString)] ->
    TestConfig app ->
    Mocks AllServices ->
    IO (Update -> IO ())
buildFileOpsAction app maxBytes downloads cfg mocks = do
    addTgDownloads (tgMock mocks) downloads
    pure $ \update -> case updateChatId update of
        Nothing -> pure ()
        Just chatId -> case updateMessage update of
            Nothing -> pure ()
            Just msg -> case messageDocument msg of
                Nothing -> pure ()
                Just doc ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram $
                            handleDocumentUpload
                                "demo-bot"
                                maxBytes
                                chatId
                                (messageMessageId msg)
                                (documentFileId doc)

-- | Run a DSL script via 'tgTest' with the file-ops action for the given limit
-- and canned downloads; returns the snapshot and the DSL result.
runFileOpsTest ::
    DefaultApp AllServices ->
    Integer ->
    [(FileId, ByteString)] ->
    TelegramTestScript a ->
    IO (Mailboxes, Either TgTestError a)
runFileOpsTest app maxBytes downloads =
    tgTest defaultTgTestConfig (buildFileOpsAction app maxBytes downloads)

-- | Acceptance pilot: uploads the canned file, asserts the verdict reply carries
-- the acceptance marker, the downloaded byte count, and the 16-char sha prefix,
-- then asserts the user's upload message is deleted.
acceptPilot :: Text -> Text -> TelegramTestScript ()
acceptPilot byteCountNeedle shaPrefix = do
    (_uid, userMsgId) <- sendFile docFileId
    reply <- waitForReply
    guardWith "expected an acceptance reply" ("✅" `Text.isInfixOf` reply)
    guardWith "expected the downloaded byte count in the reply" (byteCountNeedle `Text.isInfixOf` reply)
    guardWith "expected the 16-char sha256 prefix of the exact downloaded bytes" (shaPrefix `Text.isInfixOf` reply)
    waitForDeletion userMsgId

-- | Rejection pilot: uploads a file whose canned bytes exceed the limit, asserts
-- the verdict reply names both numbers, leaks no digest (gate A rejected before
-- any download), and still deletes the user's upload message.
rejectPilot :: Text -> Text -> TelegramTestScript ()
rejectPilot numbersFragment shaPrefix = do
    (_uid, userMsgId) <- sendFile docFileId
    reply <- waitForReply
    guardWith "expected a too-large rejection reply" ("too large" `Text.isInfixOf` reply)
    guardWith "expected the reported size and the limit in the reply" (numbersFragment `Text.isInfixOf` reply)
    guardWith "the rejection reply must not contain any sha256 text" (not ("sha256" `Text.isInfixOf` reply))
    guardWith "the rejection reply must not leak the digest of the canned bytes" (not (shaPrefix `Text.isInfixOf` reply))
    waitForDeletion userMsgId

-- | Spec-local demo scenario over the raw 'downloadFileById' composite: no size
-- gate, no deletion — just the (response, bytes) pair surfaced somewhere
-- assertable. Mirrors 'handleDocumentUpload''s acceptance reply: the downloaded
-- byte count plus a 16-char sha256 prefix, so 'waitForReply' can correlate the
-- reply with the canned file.
directDownloadScenario :: Text -> ChatId -> FileId -> ScenarioProgram Script serviceLib ()
directDownloadScenario botName chatId fid = do
    (_resp, bytes) <- evalScript $ tgScript botName $ downloadFileById fid
    let shaHex = fileSha256Hex bytes
    void $
        evalScript $
            tgScript botName $
                sendMessage $
                    defSendMessage (SomeChatId chatId) $
                        "✅ Raw download: "
                            <> tshow (BS.length bytes)
                            <> " bytes, sha256: "
                            <> Text.take 16 shaHex

-- | Build the bot's @Update -> IO ()@ action for the raw-composite test: injects
-- the canned download into the supplied mocks and, on every document update,
-- runs 'directDownloadScenario' under the test performer against the SAME mocks
-- the runner observes (the sharing is the point).
buildDirectDownloadAction ::
    DefaultApp AllServices ->
    [(FileId, ByteString)] ->
    TestConfig app ->
    Mocks AllServices ->
    IO (Update -> IO ())
buildDirectDownloadAction app downloads cfg mocks = do
    addTgDownloads (tgMock mocks) downloads
    pure $ \update -> case updateChatId update of
        Nothing -> pure ()
        Just chatId -> case updateMessage update of
            Nothing -> pure ()
            Just msg -> case messageDocument msg of
                Nothing -> pure ()
                Just doc ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram $
                            directDownloadScenario "demo-bot" chatId (documentFileId doc)

-- | Run a DSL script via 'tgTest' with the raw-composite action and the given
-- canned downloads; returns the snapshot and the DSL result.
runDirectDownloadTest ::
    DefaultApp AllServices ->
    [(FileId, ByteString)] ->
    TelegramTestScript a ->
    IO (Mailboxes, Either TgTestError a)
runDirectDownloadTest app downloads =
    tgTest defaultTgTestConfig (buildDirectDownloadAction app downloads)

-- | Raw-download pilot: uploads the canned file and asserts the reply carries
-- the exact canned byte count and the 16-char sha256 prefix — the prefix can
-- only be computed from the actually downloaded bytes, which in the mock are
-- keyed by the 'fileFileId' of the 'getFile' response, so matching it proves
-- the whole @getFile@ → @downloadFile@ threading of the composite.
directDownloadPilot :: Text -> Text -> TelegramTestScript ()
directDownloadPilot byteCountNeedle shaPrefix = do
    _ <- sendFile directFileId
    reply <- waitForReply
    guardWith "expected a raw-download reply" ("✅" `Text.isInfixOf` reply)
    guardWith "expected the downloaded byte count in the reply" (byteCountNeedle `Text.isInfixOf` reply)
    guardWith "expected the 16-char sha256 prefix of the exact downloaded bytes" (shaPrefix `Text.isInfixOf` reply)

-- | Bot API base URL of a (fake) bot used by the pure 'fileDownloadUrl' checks.
pureTestBotBase :: BaseUrl
pureTestBotBase = BaseUrl Https "api.telegram.org" 443 "/bot123:ABC"

-- | Spec-local scenario proving the client-declared document METADATA rides
-- through the update end-to-end: reads name / MIME type / size straight from the
-- update's 'Document' and echoes them back — exactly the read pattern a
-- format/size pre-check scenario would use before downloading.
metadataEchoScenario :: Text -> ChatId -> Document -> ScenarioProgram Script serviceLib ()
metadataEchoScenario botName chatId doc =
    void $
        evalScript $
            tgScript botName $
                sendMessage $
                    defSendMessage (SomeChatId chatId) $
                        "📄 "
                            <> fromMaybe "<no-name>" (documentFileName doc)
                            <> " ("
                            <> fromMaybe "<no-mime>" (documentMimeType doc)
                            <> ", "
                            <> tshow (fromMaybe (-1) (documentFileSize doc))
                            <> " bytes)"

-- | Build the bot's @Update -> IO ()@ action for the metadata test: on every
-- document update, echo the FULL document metadata back under the test
-- performer against the SAME mocks the runner observes. No canned downloads are
-- staged — the scenario must NOT download anything.
buildMetadataEchoAction ::
    DefaultApp AllServices ->
    TestConfig app ->
    Mocks AllServices ->
    IO (Update -> IO ())
buildMetadataEchoAction app cfg mocks =
    pure $ \update -> case updateChatId update of
        Nothing -> pure ()
        Just chatId -> case updateMessage update of
            Nothing -> pure ()
            Just msg -> case messageDocument msg of
                Nothing -> pure ()
                Just doc ->
                    runWithConfig app cfg mocks $
                        runScenarioProgram $
                            metadataEchoScenario "demo-bot" chatId doc

-- | Metadata pilot: uploads a document declared as a named PDF of a known size
-- and asserts the echoed reply carries all three metadata values — proving the
-- sender's claim reached the scenario's 'Document' untouched.
metadataPilot :: TelegramTestScript ()
metadataPilot = do
    _ <- sendDocumentAs (FileId "doc-meta") (Just "report.pdf") (Just "application/pdf") (Just 12345)
    reply <- waitForReply
    guardWith "expected the declared file name in the reply" ("report.pdf" `Text.isInfixOf` reply)
    guardWith "expected the declared mime type in the reply" ("application/pdf" `Text.isInfixOf` reply)
    guardWith "expected the declared size in the reply" ("12345 bytes" `Text.isInfixOf` reply)

spec :: Spec
spec = do
    describe "fileDownloadUrl (pure)" $ do
        it "embeds the server-issued file_path verbatim, with no percent-encoding" $ do
            let url = fileDownloadUrl pureTestBotBase "documents/file_10.pdf"
            url `shouldSatisfy` ("/file/bot123:ABC/" `Text.isInfixOf`)
            url `shouldSatisfy` ("documents/file_10.pdf" `Text.isInfixOf`)
            url `shouldNotSatisfy` ("%2F" `Text.isInfixOf`)

        it "is exactly the file base URL plus the verbatim path" $
            fileDownloadUrl pureTestBotBase "documents/file_10.pdf"
                `shouldBe` "https://api.telegram.org/file/bot123:ABC/documents/file_10.pdf"

    aroundAll withBotTestApp $
        describe "tgTest: handleDocumentUpload e2e (download + delete)" $ do
            it "downloads the canned file, replies with byte count and sha prefix, and deletes the upload" $ \app -> do
                (_mailboxes, result) <-
                    runFileOpsTest app 1_000_000 [(docFileId, docBytes)] $
                        acceptPilot (tshow (BS.length docBytes) <> " bytes") (shaPrefixOf docBytes)
                case result of
                    Left e -> expectationFailure ("expected the happy path to complete, but it aborted: " <> show e)
                    Right () -> pure ()

            it "rejects an oversized file at gate A before downloading, and still deletes the upload" $ \app -> do
                let limit = 10 :: Integer
                    numbersFragment =
                        tshow (BS.length oversizeBytes)
                            <> " bytes exceeds the "
                            <> tshow limit
                            <> "-byte limit"
                (_mailboxes, result) <-
                    runFileOpsTest app limit [(docFileId, oversizeBytes)] $
                        rejectPilot numbersFragment (shaPrefixOf oversizeBytes)
                case result of
                    Left e -> expectationFailure ("expected the rejection path to complete, but it aborted: " <> show e)
                    Right () -> pure ()

            it "accepts arbitrary binary content with no format validation (v1 pin)" $ \app -> do
                (_mailboxes, result) <-
                    runFileOpsTest app 1_000 [(docFileId, binaryBytes)] $
                        acceptPilot (tshow (BS.length binaryBytes) <> " bytes") (shaPrefixOf binaryBytes)
                case result of
                    Left e -> expectationFailure ("expected the binary upload to be accepted, but it aborted: " <> show e)
                    Right () -> pure ()

    aroundAll withBotTestApp $
        describe "tgTest: downloadFileById e2e (raw composite, no gating)" $ do
            it "returns the raw getFile response and exact canned bytes with no size validation" $ \app -> do
                (_mailboxes, result) <-
                    runDirectDownloadTest app [(directFileId, directBytes)] $
                        directDownloadPilot (tshow (BS.length directBytes) <> " bytes") (shaPrefixOf directBytes)
                case result of
                    Left e -> expectationFailure ("expected the raw composite download to complete, but it aborted: " ++ show e)
                    Right () -> pure ()

    aroundAll withBotTestApp $
        describe "tgTest: document metadata e2e (sendDocumentAs pre-check pattern)" $ do
            it "delivers the client-declared file_name, mime_type, and file_size to the scenario" $ \app -> do
                (_mailboxes, result) <-
                    tgTest defaultTgTestConfig (buildMetadataEchoAction app) metadataPilot
                case result of
                    Left e -> expectationFailure ("expected the metadata echo to complete, but it aborted: " ++ show e)
                    Right () -> pure ()
