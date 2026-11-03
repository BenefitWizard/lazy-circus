{-# LANGUAGE OverloadedStrings #-}

{- | Pure pins for the honest Telegram failure classification introduced with
the unified error model: 'classifyFailureBody' parses the error-shaped body of
a Bot API failure response (a real 429 body carries no @result@ field, so the
generic 'Response' decoder can never read it), 'rateLimitRetryDelay' derives
the retry delay for the deferred-retry delivery policy, and one pin documents
why the dedicated error-shape parser exists at all.
-}
module TgFailureClassificationSpec (spec) where

import Data.Aeson (decode)
import RIO hiding (decode)
import Test.Hspec

import LazyCircus.Telegram (classifyFailureBody, rateLimitRetryDelay)
import LazyCircus.Telegram.Types (TelegramApiRejected (..))
import Telegram.Bot.API (Message, Response)

-- | A real Telegram 429 body, verbatim shape: no @result@ field, the advised
-- delay under @parameters.retry_after@.
rateLimitedBody :: LByteString
rateLimitedBody =
    "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 5\",\"parameters\":{\"retry_after\":5}}"

-- | A 429 body whose intermediary stripped the @parameters@ object.
rateLimitedBodyNoParameters :: LByteString
rateLimitedBodyNoParameters =
    "{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests\"}"

-- | An @ok = false@ body with no error code at all: the HTTP status is the
-- only signal left.
bareRejectionBody :: LByteString
bareRejectionBody = "{\"ok\":false}"

-- | A non-JSON body an intermediary might return instead of the Bot API.
htmlGarbageBody :: LByteString
htmlGarbageBody = "<html><body>502 Bad Gateway</body></html>"

-- | A 409 conflict body, the other status the old code fabricated success for.
conflictBody :: LByteString
conflictBody = "{\"ok\":false,\"error_code\":409,\"description\":\"Conflict: terminated by other setMyCommands request\"}"

spec :: Spec
spec =
    describe "Telegram failure classification" $ do
        describe "classifyFailureBody" $ do
            it "preserves error_code, description and retry_after of a 429 body" $ do
                classifyFailureBody 429 rateLimitedBody
                    `shouldBe` TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 429
                        , telegramApiRejectedDescription = Just "Too Many Requests: retry after 5"
                        , telegramApiRejectedRetryAfter = Just 5
                        }

            it "yields no retry_after when the 429 body carries no parameters" $ do
                classifyFailureBody 429 rateLimitedBodyNoParameters
                    `shouldBe` TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 429
                        , telegramApiRejectedDescription = Just "Too Many Requests"
                        , telegramApiRejectedRetryAfter = Nothing
                        }

            it "falls back to the HTTP status when the body has no error_code" $ do
                classifyFailureBody 429 bareRejectionBody
                    `shouldBe` TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 429
                        , telegramApiRejectedDescription = Nothing
                        , telegramApiRejectedRetryAfter = Nothing
                        }

            it "falls back to the bare HTTP status on a non-decodable body" $ do
                classifyFailureBody 502 htmlGarbageBody
                    `shouldBe` TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 502
                        , telegramApiRejectedDescription = Nothing
                        , telegramApiRejectedRetryAfter = Nothing
                        }

            it "classifies a 409 body as a rejection instead of fabricated success" $ do
                classifyFailureBody 409 conflictBody
                    `shouldBe` TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 409
                        , telegramApiRejectedDescription = Just "Conflict: terminated by other setMyCommands request"
                        , telegramApiRejectedRetryAfter = Nothing
                        }

        describe "rateLimitRetryDelay" $ do
            it "advises retry_after plus the safety margin on a 429 rejection" $ do
                rateLimitRetryDelay
                    TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 429
                        , telegramApiRejectedDescription = Nothing
                        , telegramApiRejectedRetryAfter = Just 5
                        }
                    `shouldBe` Just 6

            it "advises the default delay on a 429 without retry_after" $ do
                rateLimitRetryDelay
                    TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 429
                        , telegramApiRejectedDescription = Nothing
                        , telegramApiRejectedRetryAfter = Nothing
                        }
                    `shouldBe` Just 1

            it "advises no retry for non-rate-limit rejections" $ do
                rateLimitRetryDelay
                    TelegramApiRejected
                        { telegramApiRejectedErrorCode = Just 400
                        , telegramApiRejectedDescription = Nothing
                        , telegramApiRejectedRetryAfter = Nothing
                        }
                    `shouldBe` Nothing

        describe "why a dedicated error-shape parser exists" $ do
            it "a real 429 body does not decode into Response Message (result is a required field)" $ do
                let decoded = decode rateLimitedBody :: Maybe (Response Message)
                decoded `shouldSatisfy` isNothing
