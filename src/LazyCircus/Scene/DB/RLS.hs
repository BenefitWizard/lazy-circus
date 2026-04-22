{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module LazyCircus.Scene.DB.RLS (
    RLSContext,
    unRLSContext,
    noRLS,
    rlsQSId,
    rlsCircusId,
    RLSConfigError (..),
    setRLSContext,
) where

import Control.Exception qualified as CE
import Database.PostgreSQL.Simple (SqlError (..))
import Database.PostgreSQL.Simple qualified as Simple
import Database.PostgreSQL.Simple.Types (Only (..), Query (..))
import RIO

newtype RLSContext = RLSContext [(Text, Text)]
    deriving (Show, Eq, Semigroup, Monoid)

unRLSContext :: RLSContext -> [(Text, Text)]
unRLSContext (RLSContext pairs) = pairs

noRLS :: RLSContext
noRLS = mempty

rlsQSId :: Int32 -> RLSContext
rlsQSId qsId = RLSContext [("qs_id", tshow qsId)]

rlsCircusId :: Int32 -> RLSContext
rlsCircusId circusId = RLSContext [("circus_id", tshow circusId)]

data RLSConfigError = RLSConfigError
    { rlsConfigKey :: Text
    , rlsConfigMessage :: ByteString
    }
    deriving (Show)

instance Exception RLSConfigError

setRLSContext :: Simple.Connection -> Maybe RLSContext -> IO ()
setRLSContext _ Nothing = pure ()
setRLSContext conn (Just ctx) = for_ (unRLSContext ctx) $ \(k, v) -> do
    result <-
        CE.try $
            Simple.execute
                conn
                (Query $ encodeUtf8 $ "SET LOCAL rls." <> k <> " = ?")
                (Only v)
    case result of
        Left (e :: SqlError) ->
            throwIO $
                RLSConfigError
                    { rlsConfigKey = k
                    , rlsConfigMessage = sqlErrorMsg e
                    }
        Right _ -> pure ()
