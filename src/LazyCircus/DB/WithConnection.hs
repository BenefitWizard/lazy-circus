{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Wrapper for injecting a specific database connection into an application environment.
module LazyCircus.DB.WithConnection (
    AppWithConnection (..),
    appConn,
    underlyingApp,
) where

import Database.PostgreSQL.Simple (Connection)
import LazyCircus.AI (HasAIMethods (..))
import LazyCircus.App.Default (HasBotEnvs (..), HasExtraContext (..), HasJWTSettings (..), HasMailCreds (..), HasMainDb (..))
import LazyCircus.App.Log (HasLogQueue (..), HasLoggingContext (..))
import LazyCircus.AsyncWorker.Types (HasScheduledActions (..))
import LazyCircus.DB.Class (HasPgConnection (..), HasPgConnectionReadOnly (..))
import LazyCircus.Scene.DB.Class (HasDbConnection (..))
import LazyCircus.Script (Script)
import RIO
import RIO.Process (HasProcessContext (..))

{- | Wrapper that pairs a specific database connection with an underlying application environment.
Used by interpreters to inject either read-write or read-only connections.
-}
data AppWithConnection app = AppWithConnection
    { _appConn :: Connection
    , _underlyingApp :: app
    }

appConn :: Lens' (AppWithConnection app) Connection
appConn = lens _appConn (\x y -> x{_appConn = y})

underlyingApp :: Lens' (AppWithConnection app) app
underlyingApp = lens _underlyingApp (\x y -> x{_underlyingApp = y})

-- | The injected connection is the active connection for DB interpreters.
instance HasPgConnection (AppWithConnection app) where
    postgresL = appConn

-- | The injected connection is also used by the generic DBScript performer.
instance HasDbConnection (AppWithConnection app) where
    dbConnectionL = appConn

-- | Nested read-only requests still delegate to the underlying environment capability.
instance (HasPgConnectionReadOnly app) => HasPgConnectionReadOnly (AppWithConnection app) where
    postgresReadOnlyL = underlyingApp . postgresReadOnlyL

instance (HasLogFunc app) => HasLogFunc (AppWithConnection app) where
    logFuncL = underlyingApp . logFuncL

instance (HasGLogFunc app) => HasGLogFunc (AppWithConnection app) where
    type GMsg (AppWithConnection app) = GMsg app
    gLogFuncL = underlyingApp . gLogFuncL

instance (HasProcessContext app) => HasProcessContext (AppWithConnection app) where
    processContextL = underlyingApp . processContextL

instance (HasMainDb app) => HasMainDb (AppWithConnection app) where
    mainDbL = underlyingApp . mainDbL

instance (HasBotEnvs app) => HasBotEnvs (AppWithConnection app) where
    botEnvsL = underlyingApp . botEnvsL

instance (HasExtraContext app) => HasExtraContext (AppWithConnection app) where
    extraContextL = underlyingApp . extraContextL

instance (HasMailCreds app) => HasMailCreds (AppWithConnection app) where
    mailCredsL = underlyingApp . mailCredsL

instance (HasJWTSettings app) => HasJWTSettings (AppWithConnection app) where
    jwtSettingsL = underlyingApp . jwtSettingsL

instance (HasLogQueue app) => HasLogQueue (AppWithConnection app) where
    logQueueL = underlyingApp . logQueueL

instance (HasLoggingContext app) => HasLoggingContext (AppWithConnection app) where
    logContextL = underlyingApp . logContextL

instance (HasScheduledActions Script app) => HasScheduledActions Script (AppWithConnection app) where
    scheduledActionsL = underlyingApp . scheduledActionsL

instance (HasAIMethods app) => HasAIMethods (AppWithConnection app) where
    aiMethodsL = underlyingApp . aiMethodsL
