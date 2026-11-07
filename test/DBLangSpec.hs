{-# LANGUAGE OverloadedStrings #-}

module DBLangSpec (spec) where

import Common
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError, query_)
import Database.PostgreSQL.Simple qualified as Simple
import Database.PostgreSQL.Simple.ToField qualified as ToField
import Database.PostgreSQL.Simple.Types (Query (..))
import LazyCircus.Scene.DB
import LazyCircus.Scenario (DbMode (..))
import RIO
import RIO.Time (UTCTime, getCurrentTime)
import Test.Hspec
import TestDbSupport

-- | Unwrap a 'Just' value, failing the test with a descriptive message on 'Nothing'.
expectJust :: HasCallStack => String -> Maybe a -> IO a
expectJust _ (Just a) = pure a
expectJust label Nothing =
    expectationFailure (label <> " returned Nothing") >> error "unreachable"

spec :: Spec
spec = aroundAll withFreshTestDb $ do
    describe "DB language integration" $ do
        it "create inserts a row and returns it with generated id" $ \env -> do
            beforeRows <- queryActs env
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            circusId created `shouldBe` 7
            circusActName created `shouldBe` "Acrobats"
            circusActDescription created `shouldBe` "Flying trapeze"
            circusActAudienceReaction created `shouldBe` Just "wow"

            afterRows <- queryActs env
            length afterRows `shouldBe` length beforeRows + 1
            last afterRows
                `shouldBe` TestRow (circusActId created) "Acrobats" 7 "Flying trapeze" (Just "wow")

        it "find returns Nothing for an absent id" $ \env -> do
            result <- runDbScript simpleDb ReadWrite (findCircusAct 999) env
            result `shouldBe` Nothing

        it "find returns the row for an existing id" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            found <- runDbScript simpleDb ReadWrite (findCircusAct $ circusActId created) env
            found `shouldBe` Just created

        it "findLocked returns Nothing for an absent id" $ \env -> do
            result <- runDbScript simpleDb ReadWrite (withTransaction $ findLockedCircusAct 999) env
            result `shouldBe` Nothing

        it "findLocked returns the same row as find for an existing id" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            locked <- runDbScript simpleDb ReadWrite (withTransaction $ findLockedCircusAct (circusActId created)) env
            found <- runDbScript simpleDb ReadWrite (findCircusAct (circusActId created)) env

            locked `shouldBe` Just created
            locked `shouldBe` found

        it "findAllLocked returns the row for an existing id" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            locked <- runDbScript simpleDb ReadWrite (withTransaction $ findAllLockedCircusAct (circusActId created)) env
            locked `shouldBe` [created]

        it "findLocked is allowed in ReadOnly mode" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            locked <- runDbScript simpleDb ReadOnly (withTransaction $ findLockedCircusAct (circusActId created)) env
            locked `shouldBe` Just created

        it "update changes only provided fields" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            updated <-
                runDbScript
                    simpleDb
                    ReadWrite
                    (updateCircusAct updatePatch (circusActId created))
                    env

            length updated `shouldBe` 1
            let [row] = updated
            circusActName row `shouldBe` "Acrobats"
            circusActDescription row `shouldBe` "New finale"
            circusId row `shouldBe` 7
            circusActAudienceReaction row `shouldBe` Nothing

        it "delete removes the matching row" $ \env -> do
            beforeRows <- queryActs env
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            runDbScript simpleDb ReadWrite (deleteCircusAct $ circusActId created) env

            found <- runDbScript simpleDb ReadWrite (findCircusAct $ circusActId created) env
            found `shouldBe` Nothing
            queryActs env `shouldReturn` beforeRows

        it "createMany inserts multiple rows" $ \env -> do
            inserted <- runDbScript simpleDb ReadWrite (createMany [circusActMaybe, secondCircusActMaybe]) env

            length inserted `shouldBe` 2
            map circusActName inserted `shouldBe` ["Acrobats", "Jugglers"]
            map circusId inserted `shouldBe` [7, 8]

        it "updateMany updates all matching rows" $ \env -> do
            inserted <- runDbScript simpleDb ReadWrite (createMany [circusActMaybe, secondCircusActMaybe]) env
            let ids = map (CircusActId . circusActId) inserted

            updated <- runDbScript simpleDb ReadWrite (updateMany sharedReactionPatch ids) env

            length updated `shouldBe` 2
            map circusActAudienceReaction updated `shouldBe` [Just "cheers", Just "cheers"]

        it "upsert inserts a new row and returns it" $ \env -> do
            beforeRows <- queryActs env

            upserted <- expectJust "upsertScript" =<< runDbScript simpleDb ReadWrite upsertScript env

            circusId upserted `shouldBe` 7
            circusActName upserted `shouldBe` "Acrobats"
            circusActDescription upserted `shouldBe` "Flying trapeze"
            circusActAudienceReaction upserted `shouldBe` Just "wow"

            afterRows <- queryActs env
            length afterRows `shouldBe` length beforeRows + 1
            last afterRows
                `shouldBe` TestRow (circusActId upserted) "Acrobats" 7 "Flying trapeze" (Just "wow")

        it "upsert updates only provided fields on conflict" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env
            beforeRows <- queryActs env

            upserted <-
                expectJust "upsertScript" =<<
                runDbScript simpleDb ReadWrite (upsert (conflictPatch (circusActId created))) env

            circusActId upserted `shouldBe` circusActId created
            circusId upserted `shouldBe` 7
            circusActName upserted `shouldBe` "Acrobats"
            circusActDescription upserted `shouldBe` "New finale"
            circusActAudienceReaction upserted `shouldBe` Nothing

            afterRows <- queryActs env
            length afterRows `shouldBe` length beforeRows

        it "upsertMany mixes inserts and updates" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env
            beforeRows <- queryActs env

            affected <-
                runDbScript
                    simpleDb
                    ReadWrite
                    (upsertMany [secondCircusActMaybe, conflictPatch (circusActId created)])
                    env

            length affected `shouldBe` 2
            map circusActName affected `shouldSatisfy` elem "Jugglers"
            map circusActName affected `shouldSatisfy` elem "Acrobats"

            afterRows <- queryActs env
            length afterRows `shouldBe` length beforeRows + 1
            let updatedRows = filter (\r -> testRowId r == circusActId created) afterRows
            testRowDescription <$> listToMaybe updatedRows `shouldBe` Just "New finale"

        it "upsert conflicts on the charge id, not the primary key" $ \env -> do
            first <-
                expectJust "first upsert" =<<
                runDbScript simpleDb ReadWrite (upsert (starsPaymentUpsert "chg-42" (Just 10))) env
            second <-
                expectJust "second upsert" =<<
                runDbScript simpleDb ReadWrite (upsert (starsPaymentUpsert "chg-42" (Just 25))) env

            starsPaymentId second `shouldBe` starsPaymentId first
            starsPaymentStars second `shouldBe` Just 25
            starsPaymentTelegramPaymentChargeId second `shouldBe` "chg-42"

            rows <-
                runDbScript
                    simpleDb
                    ReadWrite
                    ( rawQuery
                        "select-stars-payments"
                        (Query "SELECT id, telegram_payment_charge_id, user_id, stars, currency_amount, invoice_payload, created_at FROM stars_payments")
                        []
                    )
                    env
            rows `shouldBe` [second]

        it "upsert works inside withTransactionRLS" $ \env -> do
            let script = withTransactionRLS (rlsCircusId 7) $ do
                    mAct <- upsert circusActMaybe
                    forM mAct $ \act -> upsert (conflictPatch (circusActId act))

            res <- runDbScript simpleDb ReadWrite script env

            fmap circusActDescription (join res) `shouldBe` Just "New finale"

        it "rawQuery reads rows from the same database" $ \env -> do
            _ <- runDbScript simpleDb ReadWrite createScript env

            rows <-
                runDbScript
                    simpleDb
                    ReadWrite
                    (rawQuery "select-act-names-by-circus" rawSelect [ToField.toField (7 :: Int32)])
                    env

            rows `shouldSatisfy` (Only ("Acrobats" :: String) `elem`)

        it "ReadOnly rejects create operations" $ \env -> do
            runDbScript simpleDb ReadOnly createScript env `shouldThrow` isReadOnlyViolation

        it "ReadOnly rejects update operations" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            runDbScript simpleDb ReadOnly (updateCircusAct updatePatch (circusActId created)) env
                `shouldThrow` isReadOnlyViolation

        it "ReadOnly rejects upsert operations" $ \env ->
            runDbScript simpleDb ReadOnly upsertScript env `shouldThrow` isReadOnlyViolation

        it "ReadOnly rejects delete operations" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            runDbScript simpleDb ReadOnly (deleteCircusAct $ circusActId created) env
                `shouldThrow` isReadOnlyViolation

        it "ReadOnly still allows reads" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            found <- runDbScript simpleDb ReadOnly (findCircusAct $ circusActId created) env
            found `shouldBe` Just created

        it "withTransaction commits successful work" $ \env -> do
            beforeRows <- queryActs env
            _ <- runDbScript simpleDb ReadWrite (withTransaction createScript) env

            afterRows <- queryActs env
            length afterRows `shouldBe` length beforeRows + 1
            map testRowName afterRows `shouldSatisfy` ("Acrobats" `elem`)

        it "withTransaction rolls back when the nested script throws" $ \env -> do
            _ <- runDbScript simpleDb ReadWrite createScript env
            beforeRows <- queryActs env
            let preservedRow = last beforeRows
                preservedId = testRowId preservedRow

            let failingScript = withTransaction $ do
                    _ <- updateCircusAct updatePatch preservedId
                    _ <- create secondCircusActMaybe
                    _ <- badQuery
                    pure ()

            runDbScript simpleDb ReadWrite failingScript env `shouldThrow` anyException
            queryActs env `shouldReturn` beforeRows

        it "withTransactionRLS exposes local RLS settings inside the transaction" $ \env -> do
            let checkRlsScript = withTransactionRLS (rlsCircusId 42) $ do
                    vals <- rawQuery "read-rls-setting" (Query "SELECT current_setting('rls.circus_id')") []
                    pure vals

            vals <- runDbScript simpleDb ReadWrite checkRlsScript env
            vals `shouldBe` [Only ("42" :: Text)]

            outside <- query_ (testDbConn env) "SELECT current_setting('rls.circus_id', true)"
            outside `shouldBe` [Only (Just ("" :: Text))]

        it "withTransactionRLS applies Postgres RLS policy for circus_id" $ \env -> do
            _ <- runDbScript simpleDb ReadWrite (createMany [circusActMaybe, secondCircusActMaybe]) env

            let rlsSelectScript = withTransactionRLS (rlsCircusId 7) $ do
                    rawQuery "select-acts-under-rls" (Query "SELECT id, name, circus_id, description, audience_reaction FROM circus_acts ORDER BY id") []

            rows <- runDbScript simpleDb ReadWrite rlsSelectScript env
            rows `shouldSatisfy` (not . null)
            map testRowCircusId rows `shouldBe` replicate (length rows) 7
            map testRowName rows `shouldSatisfy` ("Acrobats" `elem`)
            map testRowName rows `shouldSatisfy` (not . elem "Jugglers")

    describe "findLocked / findAllLocked row locking (FOR UPDATE concurrency)" $ do
        it "findLocked blocks a second locking reader until the holder commits" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env
            let rowId = circusActId created
            bracket
                ((,) <$> openTestConn <*> openTestConn)
                (\(connA, connB) -> Simple.close connA >> Simple.close connB)
                $ \(connA, connB) -> do
                    let envB = env{testDbConn = connB}
                    lockHeld <- newEmptyMVar
                    a <- async (holdRowLock connA lockHeld rowId)
                    takeMVar lockHeld
                    b <- async $ do
                        res <- runDbScript simpleDb ReadWrite (withTransaction $ findLockedCircusAct rowId) envB
                        tBfinish <- getCurrentTime
                        pure (res, tBfinish)
                    (tAcommit, (res, tBfinish)) <- waitBoth a b
                    res `shouldBe` Just created
                    tBfinish `shouldSatisfy` (>= tAcommit)

        it "findAllLocked with WaitSkipLocked skips a row held by another transaction" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env
            let rowId = circusActId created
            bracket
                ((,) <$> openTestConn <*> openTestConn)
                (\(connA, connB) -> Simple.close connA >> Simple.close connB)
                $ \(connA, connB) -> do
                    let envB = env{testDbConn = connB}
                    lockHeld <- newEmptyMVar
                    a <- async (holdRowLock connA lockHeld rowId)
                    takeMVar lockHeld
                    mResult <-
                        timeout 2000000 $
                            runDbScript simpleDb ReadWrite (withTransaction $ findAllLockedSpec (LockSpec LockUpdate WaitSkipLocked) rowId) envB
                    void (wait a)
                    mResult `shouldBe` (Just [] :: Maybe [CircusAct])

        it "findLocked with WaitNoWait throws when the row is already locked" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env
            let rowId = circusActId created
            bracket
                ((,) <$> openTestConn <*> openTestConn)
                (\(connA, connB) -> Simple.close connA >> Simple.close connB)
                $ \(connA, connB) -> do
                    let envB = env{testDbConn = connB}
                    lockHeld <- newEmptyMVar
                    a <- async (holdRowLock connA lockHeld rowId)
                    takeMVar lockHeld
                    runDbScript simpleDb ReadWrite (withTransaction $ findLockedSpec (LockSpec LockUpdate WaitNoWait) rowId) envB
                        `shouldThrow` anySqlError
                    void (wait a)
  where
    rawSelect = Query "SELECT name FROM circus_acts WHERE circus_id = ? ORDER BY id"

createScript :: DBScript SimpleDb (Maybe CircusAct)
createScript = create circusActMaybe

upsertScript :: DBScript SimpleDb (Maybe CircusAct)
upsertScript = upsert circusActMaybe

-- | Upsert patch for an existing row: keeps unspecified fields, clears the reaction.
-- circusId is Just because Postgres validates the would-be INSERT row (NOT NULL,
-- RLS WITH CHECK) even when the row conflicts and takes the DO UPDATE branch.
conflictPatch :: Int32 -> CircusActT Maybe
conflictPatch actId =
    CircusAct
        { circusActId = Just actId
        , circusActName = Nothing
        , circusId = Just 7
        , circusActDescription = Just "New finale"
        , circusActAudienceReaction = Just Nothing
        }

-- | Upsert row for a stars payment keyed by the telegram charge id.
starsPaymentUpsert :: Text -> Maybe Int32 -> StarsPaymentT Maybe
starsPaymentUpsert chargeId stars =
    StarsPayment
        { starsPaymentId = Nothing
        , starsPaymentTelegramPaymentChargeId = Just chargeId
        , starsPaymentUserId = Just (Just 111)
        , starsPaymentStars = Just stars
        , starsPaymentCurrencyAmount = Nothing
        , starsPaymentInvoicePayload = Nothing
        , starsPaymentCreatedAt = Nothing
        }

circusActMaybe :: CircusActT Maybe
circusActMaybe =
    CircusAct
        { circusActId = Nothing
        , circusActName = Just "Acrobats"
        , circusId = Just 7
        , circusActDescription = Just "Flying trapeze"
        , circusActAudienceReaction = Just (Just "wow")
        }

secondCircusActMaybe :: CircusActT Maybe
secondCircusActMaybe =
    CircusAct
        { circusActId = Nothing
        , circusActName = Just "Jugglers"
        , circusId = Just 8
        , circusActDescription = Just "Club cascade"
        , circusActAudienceReaction = Nothing
        }

updatePatch :: CircusActT Maybe
updatePatch =
    CircusAct
        { circusActId = Nothing
        , circusActName = Nothing
        , circusId = Nothing
        , circusActDescription = Just "New finale"
        , circusActAudienceReaction = Just Nothing
        }

sharedReactionPatch :: CircusActT Maybe
sharedReactionPatch =
    CircusAct
        { circusActId = Nothing
        , circusActName = Nothing
        , circusId = Nothing
        , circusActDescription = Nothing
        , circusActAudienceReaction = Just (Just "cheers")
        }

badQuery :: DBScript SimpleDb [Only Int]
badQuery = rawQuery "select-missing-column" (Query "SELECT definitely_missing_column FROM circus_acts") []

findCircusAct :: Int32 -> DBScript SimpleDb (Maybe CircusAct)
findCircusAct actId = find (CircusActId actId :: CircusActId)

findLockedCircusAct :: Int32 -> DBScript SimpleDb (Maybe CircusAct)
findLockedCircusAct actId = findLocked defaultLock (CircusActId actId :: CircusActId)

findAllLockedCircusAct :: Int32 -> DBScript SimpleDb [CircusAct]
findAllLockedCircusAct actId = findAllLocked defaultLock (CircusActId actId :: CircusActId)

findLockedSpec :: LockSpec -> Int32 -> DBScript SimpleDb (Maybe CircusAct)
findLockedSpec lockSpec actId = findLocked lockSpec (CircusActId actId :: CircusActId)

findAllLockedSpec :: LockSpec -> Int32 -> DBScript SimpleDb [CircusAct]
findAllLockedSpec lockSpec actId = findAllLocked lockSpec (CircusActId actId :: CircusActId)

deleteCircusAct :: Int32 -> DBScript SimpleDb ()
deleteCircusAct actId = delete (CircusActId actId :: CircusActId)

updateCircusAct :: CircusActT Maybe -> Int32 -> DBScript SimpleDb [CircusAct]
updateCircusAct patch actId = update patch (CircusActId actId :: CircusActId)

isReadOnlyViolation :: Selector DbError
isReadOnlyViolation DbReadOnlyViolation = True

anySqlError :: Selector SqlError
anySqlError = const True

-- | Drives the given connection as a row-lock holder for the concurrency tests.
-- Opens a transaction, acquires a raw 'FOR UPDATE' lock on the seeded row,
-- signals via the 'MVar' that the lock is held, sleeps to keep the lock open,
-- and returns the timestamp captured just before the transaction commits.
-- PRE-CONTRACT: 'rowId' must identify an existing 'circus_acts' row.
-- POST-CONTRACT: The 'MVar' is filled exactly once, after the FOR UPDATE lock is
-- acquired; the lock stays held until the surrounding transaction commits.
holdRowLock :: Connection -> MVar () -> Int32 -> IO UTCTime
holdRowLock conn lockHeld rowId =
    Simple.withTransaction conn $ do
        _ :: [Only Int] <-
            Simple.query
                conn
                "SELECT 1 FROM circus_acts WHERE id = ? FOR UPDATE"
                (Only rowId)
        putMVar lockHeld ()
        threadDelay 300000
        getCurrentTime
