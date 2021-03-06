{-# LANGUAGE CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |  GraphQL Wai Server Applications
module Data.Morpheus.Server
  ( webSocketsApp,
    httpPubApp,
    ServerConstraint,
    httpPlayground,
    compileTimeSchemaValidation,
  )
where

import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.IO.Unlift
  ( MonadUnliftIO,
    withRunInIO,
  )
-- MORPHEUS

import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.Morpheus.Core
  ( App,
    runApp,
  )
import Data.Morpheus.Server.Deriving.Schema
  ( compileTimeSchemaValidation,
  )
import Data.Morpheus.Server.Playground
  ( httpPlayground,
  )
import Data.Morpheus.Types.IO (MapAPI (..))
import Data.Morpheus.Types.Internal.Resolving
  ( Event,
  )
import Data.Morpheus.Types.Internal.Subscription
  ( Input (..),
    Scope (..),
    Store (..),
    WS,
    acceptApolloRequest,
    connectionThread,
    initDefaultStore,
    publishEventWith,
    runStreamHTTP,
    streamApp,
  )
import Network.WebSockets
  ( Connection,
    ServerApp,
    receiveData,
    sendTextData,
  )
import qualified Network.WebSockets as WS

type ServerConstraint e m =
  ( MonadIO m,
    MonadUnliftIO m
  )

-- support old version of Websockets
pingThread :: Connection -> IO () -> IO ()

#if MIN_VERSION_websockets(0,12,6)
pingThread connection = WS.withPingThread connection 30 (return ())
#else
pingThread connection = (WS.forkPingThread connection 30 >>)
#endif

defaultWSScope :: MonadIO m => Store e m -> Connection -> Scope WS e m
defaultWSScope Store {writeStore} connection =
  ScopeWS
    { listener = liftIO (receiveData connection),
      callback = liftIO . sendTextData connection,
      update = writeStore
    }

httpPubApp ::
  ( MonadIO m,
    MapAPI a b
  ) =>
  [e -> m ()] ->
  App e m ->
  a ->
  m b
httpPubApp [] app = runApp app
httpPubApp callbacks app =
  mapAPI $
    runStreamHTTP ScopeHTTP {httpCallback}
      . streamApp app
      . Request
  where
    httpCallback e = traverse_ (e &) callbacks

-- | Wai WebSocket Server App for GraphQL subscriptions
webSocketsApp ::
  ( MonadUnliftIO m,
    Eq channel
  ) =>
  App (Event channel cont) m ->
  m (ServerApp, Event channel cont -> m ())
webSocketsApp app =
  do
    store <- initDefaultStore
    wsApp <- webSocketsWrapper store (connectionThread app)
    pure
      ( wsApp,
        publishEventWith store
      )

webSocketsWrapper ::
  (MonadUnliftIO m, MonadIO m) =>
  Store e m ->
  (Scope WS e m -> m ()) ->
  m ServerApp
webSocketsWrapper store handler =
  withRunInIO $
    \runIO ->
      pure $
        \pending -> do
          conn <- acceptApolloRequest pending
          pingThread
            conn
            $ runIO (handler (defaultWSScope store conn))
