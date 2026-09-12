-- | Smoke test proving the scaffolded package and its hspec harness are wired correctly.
module LazyCircus.Testing.SmokeSpec
    ( spec
    ) where

import Test.Hspec

-- | Trivial spec: the suite must be green from the first scaffold commit.
spec :: Spec
spec =
    describe "lazy-circus-testing scaffold" $
        it "boots the test harness" $ True `shouldBe` True
