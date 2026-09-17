-- | Generic pure list helpers shared by every layer of the framework and its consumers.

module LazyCircus.List
    ( exactlyOne
    ) where

import RIO
import RIO.Text qualified as T

{- | Extract the only element of a list or fail with a count-bearing diagnostic.
PRE-CONTRACT: @what@ names the expected element for the error message (the caller composes context into it, e.g. @"users row for tg_id=42"@).
POST-CONTRACT: Returns the single element of a singleton list; fails with @"\<what\>: got none"@ for the empty list and with @"\<what\>: got \<N\>"@ for N > 1 elements.
NOTE: Pure and effect-free — requires only a 'MonadFail' instance. Inside a DB @runQuery@ the 'fail' surfaces as a thrown @SomeException@ at the scenario layer.
-}
exactlyOne :: (MonadFail m) => Text -> [a] -> m a
exactlyOne _ [x] = pure x
exactlyOne what [] = fail (T.unpack (what <> ": got none"))
exactlyOne what xs = fail (T.unpack (what <> ": got " <> tshow (length xs)))
