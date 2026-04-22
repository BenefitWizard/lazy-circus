{-# LANGUAGE RankNTypes #-}

--   PURPOSE: Define the shared rank-2 runner alias used to fold effect languages into concrete runtime interpreter monads.
--   SCOPE: Export only the Runner type alias that abstracts over natural transformations consumed by the interpreter facade and runtime helpers.
--   DEPENDS: none

-- | Shared runner alias for backend interpreter and worker helpers.
module LazyCircus.Performer.Common (
    Runner,
) where

-- | Rank-2 alias for natural transformations from an effect language into an interpreter monad.
type Runner r m = forall a. r a -> m a
