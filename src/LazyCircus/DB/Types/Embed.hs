{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

--   PURPOSE: Define the reusable timestamp column fragment for UTC timestamps shared by backend Beam record types.
--   SCOPE: Export the embeddable timestamp record together with helpers that construct concrete or optional timestamp pairs.
--   DEPENDS: none

-- | Shared UTC timestamp fragment used by Beam record types.
module LazyCircus.DB.Types.Embed (
  Timestamps (..),
  stampsFromTime,
  stampsMfromTime,
  fromTimestamps,
) where

import Database.Beam
import RIO
import RIO.Time

-- import RIO.Time.Format.ISO8601

-- | Reusable created-at and updated-at UTC timestamp columns for Beam records.
data Timestamps f = Timestamps
  { tsCreatedAt :: Columnar f UTCTime
  , tsUpdatedAt :: Columnar f UTCTime
  }
  deriving (Generic, Beamable)

deriving instance Show (Timestamps Identity)
deriving instance Eq (Timestamps Identity)

deriving instance Show (Timestamps Maybe)
deriving instance Eq (Timestamps Maybe)

{- | Build a concrete timestamp pair by copying one UTC time into both fields.
PRE-CONTRACT: Accepts any UTC timestamp value.
POST-CONTRACT: Returns 'Timestamps' where both 'tsCreatedAt' and 'tsUpdatedAt' equal the input time.
-}
stampsFromTime :: UTCTime -> Timestamps Identity
stampsFromTime time =
  Timestamps
    { tsCreatedAt = time
    , tsUpdatedAt = time
    }

{- | Build an optional timestamp pair by wrapping one UTC time into both fields.
PRE-CONTRACT: Accepts any UTC timestamp value.
POST-CONTRACT: Returns 'Timestamps' where both fields are 'Just' the input time.
-}
stampsMfromTime :: UTCTime -> Timestamps Maybe
stampsMfromTime time =
  Timestamps
    { tsCreatedAt = Just time
    , tsUpdatedAt = Just time
    }

{- | Lift a concrete timestamp pair into its optional representation.
PRE-CONTRACT: Accepts a fully populated 'Timestamps' value.
POST-CONTRACT: Returns 'Timestamps' with the same times wrapped in 'Just'.
-}
fromTimestamps :: Timestamps Identity -> Timestamps Maybe
fromTimestamps Timestamps{..} =
  Timestamps
    { tsCreatedAt = Just tsCreatedAt
    , tsUpdatedAt = Just tsUpdatedAt
    }
