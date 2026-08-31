{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the Gherkin subset parser ('parseFeature').
--
-- Covers the feature header and description, tags, @And@\/@But@ keyword
-- inheritance (as stored resolved in the AST), @Scenario Outline:@ +
-- @Examples:@ expansion with name and step substitution, comment and blank
-- line handling, every error case with its line number, and parser purity.
module Bdd.GherkinSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import LazyCircus.Testing.Bdd.Gherkin
import Test.Hspec

spec :: Spec
spec = do
    describe "parseFeature" $ do
        describe "feature header" $ do
            it "parses the feature name" $
                parseFeature "Feature: Login flow\n" `shouldBe`
                    Right (GherkinFeature "Login flow" [] [] [])

            it "collects description lines until the first scenario" $
                parseFeature (T.unlines
                    [ "Feature: Drinking"
                    , "  Water is essential"
                    , ""
                    , "  More notes"
                    , "  Scenario: sip"
                    , "    Given a glass"
                    ]) `shouldBe`
                    Right
                        (GherkinFeature
                            "Drinking"
                            []
                            ["Water is essential", "More notes"]
                            [GherkinScenario "sip" [] [GherkinStep GivenKeyword "a glass" 6] 5])

            it "rejects a Feature line without a name" $
                parseFeature "Feature:\n" `shouldBe` Left (GherkinMissingFeatureName 1)

            it "rejects a document without a Feature line at line 1" $
                errLine (parseFeature "some junk\n") `shouldBe` Just 1

        describe "tags" $ do
            it "parses several tags above Feature:" $
                parseFeature (T.unlines
                    [ "@core @slow"
                    , "@manual"
                    , "Feature: T"
                    ]) `shouldBe`
                    Right (GherkinFeature "T" ["@core", "@slow", "@manual"] [] [])

            it "parses tags above a scenario, separate from feature tags" $
                case parseFeature (T.unlines
                    [ "@core"
                    , "Feature: T"
                    , "  @wip"
                    , "  Scenario: S"
                    , "    Given x"
                    ]) of
                    Right f@GherkinFeature{gherkinFeatureScenarios = [s]} -> do
                        gherkinFeatureTags f `shouldBe` ["@core"]
                        gherkinScenarioTags s `shouldBe` ["@wip"]
                    other -> expectationFailure ("unexpected parse result: " <> show other)

            it "rejects a word without '@' on a tag line" $
                errLine (parseFeature "@core plain\nFeature: T\n") `shouldBe` Just 1

        describe "steps" $ do
            it "parses Given/When/Then with resolved keywords and line numbers" $
                case parseFeature (T.unlines
                    [ "Feature: F"
                    , "  Scenario: S"
                    , "    Given a user"
                    , "    When they act"
                    , "    Then outcome"
                    ]) of
                    Right GherkinFeature{gherkinFeatureScenarios = [s]} ->
                        gherkinScenarioSteps s `shouldBe`
                            [ GherkinStep GivenKeyword "a user" 3
                            , GherkinStep WhenKeyword "they act" 4
                            , GherkinStep ThenKeyword "outcome" 5
                            ]
                    other -> expectationFailure ("unexpected parse result: " <> show other)

            it "resolves And/But to the previous keyword in the AST" $
                case parseFeature (T.unlines
                    [ "Feature: And inheritance"
                    , "  Scenario: chained steps"
                    , "    Given a user"
                    , "    And another user"
                    , "    When they act"
                    , "    And again"
                    , "    But not twice"
                    , "    Then outcome"
                    , "    And verifiable"
                    ]) of
                    Right GherkinFeature{gherkinFeatureScenarios = [s]} ->
                        gherkinScenarioSteps s `shouldBe`
                            [ GherkinStep GivenKeyword "a user" 3
                            , GherkinStep GivenKeyword "another user" 4
                            , GherkinStep WhenKeyword "they act" 5
                            , GherkinStep WhenKeyword "again" 6
                            , GherkinStep WhenKeyword "not twice" 7
                            , GherkinStep ThenKeyword "outcome" 8
                            , GherkinStep ThenKeyword "verifiable" 9
                            ]
                    other -> expectationFailure ("unexpected parse result: " <> show other)

            it "restarts keyword resolution for each scenario" $
                parseFeature (T.unlines
                    [ "Feature: A"
                    , "  Scenario: first"
                    , "    Given x"
                    , "  Scenario: second"
                    , "    But y"
                    ]) `shouldBe` Left (GherkinAndButBeforeStep 5)

            it "rejects a step outside any scenario" $
                parseFeature (T.unlines
                    [ "Feature: S"
                    , "  Given x"
                    ]) `shouldBe` Left (GherkinStepOutsideScenario 2)

        describe "comments and blank lines" $ do
            it "ignores comments and empty lines everywhere, including inside Examples" $
                case parseFeature (T.unlines
                    [ "# leading comment"
                    , "Feature: C"
                    , "  # comment"
                    , "  Description line"
                    , ""
                    , "  Scenario Outline: S <a>"
                    , "    Given x"
                    , "    # between steps"
                    , ""
                    , "    Then y"
                    , "    Examples:"
                    , "      | a |"
                    , ""
                    , "      # row comment"
                    , "      | 1 |"
                    ]) of
                    Right f@GherkinFeature{gherkinFeatureScenarios = [s]} -> do
                        gherkinFeatureDescription f `shouldBe` ["Description line"]
                        s `shouldBe`
                            (GherkinScenario
                                "S 1"
                                []
                                [GherkinStep GivenKeyword "x" 7, GherkinStep ThenKeyword "y" 10]
                                6)
                    other -> expectationFailure ("unexpected parse result: " <> show other)

        describe "scenario outlines" $ do
            it "expands each Examples row into a scenario, substituting name and steps" $
                parseFeature (T.unlines
                    [ "Feature: Lunch"
                    , "  Scenario Outline: eating <fruit> <n> times"
                    , "    Given I eat <n> <fruit>"
                    , "    And I note <fruit>"
                    , "    Then full"
                    , "    Examples:"
                    , "      | fruit   | n |"
                    , "      | apples  | 3 |"
                    , "      | bananas | 5 |"
                    ]) `shouldBe`
                    Right
                        (GherkinFeature
                            "Lunch"
                            []
                            []
                            [ GherkinScenario
                                "eating apples 3 times"
                                []
                                [ GherkinStep GivenKeyword "I eat 3 apples" 3
                                , GherkinStep GivenKeyword "I note apples" 4
                                , GherkinStep ThenKeyword "full" 5
                                ]
                                2
                            , GherkinScenario
                                "eating bananas 5 times"
                                []
                                [ GherkinStep GivenKeyword "I eat 5 bananas" 3
                                , GherkinStep GivenKeyword "I note bananas" 4
                                , GherkinStep ThenKeyword "full" 5
                                ]
                                2
                            ])

            it "leaves placeholders without a matching header column untouched" $
                case parseFeature (T.unlines
                    [ "Feature: U"
                    , "  Scenario Outline: O <unknown>"
                    , "    Given x <missing>"
                    , "    Examples:"
                    , "      | a |"
                    , "      | 1 |"
                    ]) of
                    Right GherkinFeature{gherkinFeatureScenarios = [s]} -> do
                        gherkinScenarioName s `shouldBe` "O <unknown>"
                        gherkinScenarioSteps s `shouldBe` [GherkinStep GivenKeyword "x <missing>" 3]
                    other -> expectationFailure ("unexpected parse result: " <> show other)

            it "rejects an Examples block without a header row at the Examples line" $
                errLine (parseFeature (T.unlines
                    [ "Feature: E"
                    , "  Scenario Outline: O"
                    , "    Given x"
                    , "    Examples:"
                    , "  Scenario: B"
                    , "    Given y"
                    ])) `shouldBe` Just 4

            it "rejects a data row whose width differs from the header" $
                parseFeature (T.unlines
                    [ "Feature: W"
                    , "  Scenario Outline: O"
                    , "    Given x"
                    , "    Examples:"
                    , "      | a | b |"
                    , "      | 1 |"
                    ]) `shouldBe` Left (GherkinRowWidthMismatch 6)

            it "rejects a Scenario Outline without an Examples block at the outline line" $
                parseFeature (T.unlines
                    [ "Feature: Z"
                    , "  Scenario Outline: O"
                    , "    Given x"
                    , "  Scenario: B"
                    , "    Given y"
                    ]) `shouldSatisfy` isGherkinUnexpectedAt 2

            it "rejects an Examples block in a plain scenario" $
                errLine (parseFeature (T.unlines
                    [ "Feature: P"
                    , "  Scenario: S"
                    , "    Given x"
                    , "    Examples:"
                    , "      | a |"
                    ])) `shouldBe` Just 4

            it "rejects a table row outside an Examples block" $
                errLine (parseFeature (T.unlines
                    [ "Feature: R"
                    , "  Scenario: S"
                    , "    Given x"
                    , "    | a |"
                    ])) `shouldBe` Just 4

        describe "error cases" $ do
            it "rejects a Scenario line without a name at its line" $
                parseFeature (T.unlines
                    [ "Feature: M"
                    , "  Scenario:"
                    , "    Given x"
                    ]) `shouldBe` Left (GherkinMissingScenarioName 2)

            it "rejects a duplicate Feature line" $
                parseFeature (T.unlines
                    [ "Feature: one"
                    , "Feature: two"
                    ]) `shouldSatisfy` isGherkinUnexpectedAt 2

            it "rejects a Scenario before any Feature" $
                parseFeature "Scenario: early\n" `shouldSatisfy` isGherkinUnexpectedAt 1

            it "reports the line of junk text inside a scenario" $
                parseFeature (T.unlines
                    [ "Feature: J"
                    , "  Scenario: S"
                    , "    nonsense"
                    ]) `shouldSatisfy` isGherkinUnexpectedAt 3

            it "reports the line of a tag not attached to any Feature or Scenario" $
                errLine (parseFeature (T.unlines
                    [ "Feature: F"
                    , "  Scenario: S"
                    , "    Given x"
                    , "@stray"
                    ])) `shouldBe` Just 4

        describe "purity" $ do
            it "is a pure function Text -> Either GherkinParseError GherkinFeature with no IO" $ do
                let result = parseFeature "Feature: p" :: Either GherkinParseError GherkinFeature
                result `shouldSatisfy` isRight

-- | Extracts the line number of a parse failure, for line-number assertions.
-- POST-CONTRACT: Returns Nothing exactly when parsing succeeded.
errLine :: Either GherkinParseError a -> Maybe Int
errLine = either (Just . gherkinParseErrorLine) (const Nothing)

-- | Checks that parsing failed with 'GherkinUnexpected' at the given line.
isGherkinUnexpectedAt :: Int -> Either GherkinParseError a -> Bool
isGherkinUnexpectedAt n (Left (GherkinUnexpected m _)) = m == n
isGherkinUnexpectedAt _ _ = False
