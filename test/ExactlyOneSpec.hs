{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Pure, DB-free tests for the 'exactlyOne' helper in "LazyCircus.List":
-- singleton selection, and failure messages that name the subject and carry
-- the offending element count.
module ExactlyOneSpec (spec) where

import Control.Exception qualified as E
import LazyCircus.List (exactlyOne)
import RIO
import RIO.Text qualified as T
import Test.Hspec

spec :: Spec
spec =
    describe "exactlyOne" $ do
        it "returns the single element of a singleton list" $
            (exactlyOne "circus act" [42] :: IO Int) `shouldReturn` 42

        it "fails on [] with a message naming the subject and reporting none" $ do
            outcome <- failingExactlyOne []
            case outcome of
                Left err -> do
                    let msg = T.pack (show err)
                    msg `shouldSatisfy` T.isInfixOf "circus act"
                    msg `shouldSatisfy` T.isInfixOf "none"
                Right _ -> expectationFailure "expected exactlyOne to fail on []"

        it "fails on [x, y] with a message reporting the count" $ do
            outcome <- failingExactlyOne [1, 2]
            case outcome of
                Left err -> T.pack (show err) `shouldSatisfy` T.isInfixOf "got 2"
                Right _ -> expectationFailure "expected exactlyOne to fail on [x, y]"

-- | Captures a 'fail' from 'exactlyOne' as 'SomeException': 'evaluate' forces
-- the produced action, the bind runs it, and 'try' catches the raised exception.
failingExactlyOne :: [Int] -> IO (Either E.SomeException Int)
failingExactlyOne xs = E.try @E.SomeException (E.evaluate (exactlyOne "circus act" xs) >>= id)
