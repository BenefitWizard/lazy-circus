{-# LANGUAGE OverloadedStrings #-}

module DBLangSpec (spec) where

import Common
import Database.PostgreSQL.Simple (Only (..), query_)
import Database.PostgreSQL.Simple.ToField qualified as ToField
import Database.PostgreSQL.Simple.Types (Query (..))
import LazyCircus.Scene.DB
import LazyCircus.Scenario (DbMode (..))
import RIO
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

        it "rawQuery reads rows from the same database" $ \env -> do
            _ <- runDbScript simpleDb ReadWrite createScript env

            rows <-
                runDbScript
                    simpleDb
                    ReadWrite
                    (rawQuery rawSelect [ToField.toField (7 :: Int32)])
                    env

            rows `shouldSatisfy` (Only ("Acrobats" :: String) `elem`)

        it "ReadOnly rejects create operations" $ \env -> do
            runDbScript simpleDb ReadOnly createScript env `shouldThrow` isReadOnlyViolation

        it "ReadOnly rejects update operations" $ \env -> do
            created <- expectJust "createScript" =<< runDbScript simpleDb ReadWrite createScript env

            runDbScript simpleDb ReadOnly (updateCircusAct updatePatch (circusActId created)) env
                `shouldThrow` isReadOnlyViolation

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
                    vals <- rawQuery (Query "SELECT current_setting('rls.circus_id')") []
                    pure vals

            vals <- runDbScript simpleDb ReadWrite checkRlsScript env
            vals `shouldBe` [Only ("42" :: Text)]

            outside <- query_ (testDbConn env) "SELECT current_setting('rls.circus_id', true)"
            outside `shouldBe` [Only (Just ("" :: Text))]

        it "withTransactionRLS applies Postgres RLS policy for circus_id" $ \env -> do
            _ <- runDbScript simpleDb ReadWrite (createMany [circusActMaybe, secondCircusActMaybe]) env

            let rlsSelectScript = withTransactionRLS (rlsCircusId 7) $ do
                    rawQuery (Query "SELECT id, name, circus_id, description, audience_reaction FROM circus_acts ORDER BY id") []

            rows <- runDbScript simpleDb ReadWrite rlsSelectScript env
            rows `shouldSatisfy` (not . null)
            map testRowCircusId rows `shouldBe` replicate (length rows) 7
            map testRowName rows `shouldSatisfy` ("Acrobats" `elem`)
            map testRowName rows `shouldSatisfy` (not . elem "Jugglers")
  where
    rawSelect = Query "SELECT name FROM circus_acts WHERE circus_id = ? ORDER BY id"

createScript :: DBScript SimpleDb (Maybe CircusAct)
createScript = create circusActMaybe

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
badQuery = rawQuery (Query "SELECT definitely_missing_column FROM circus_acts") []

findCircusAct :: Int32 -> DBScript SimpleDb (Maybe CircusAct)
findCircusAct actId = find (CircusActId actId :: CircusActId)

deleteCircusAct :: Int32 -> DBScript SimpleDb ()
deleteCircusAct actId = delete (CircusActId actId :: CircusActId)

updateCircusAct :: CircusActT Maybe -> Int32 -> DBScript SimpleDb [CircusAct]
updateCircusAct patch actId = update patch (CircusActId actId :: CircusActId)

isReadOnlyViolation :: Selector DbError
isReadOnlyViolation DbReadOnlyViolation = True
