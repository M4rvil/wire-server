{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}

module Galley.API.Clients
    ( getClients
    , addClient
    , rmClient
    ) where

import Data.Id
import Galley.App
import Galley.Types.Clients (clientIds, fromUserClients)
import Network.Wai
import Network.Wai.Predicate hiding (setStatus)
import Network.Wai.Utilities

import qualified Galley.Data         as Data
import qualified Galley.Intra.Client as Intra

getClients :: UserId -> Galley Response
getClients usr = do
    clts <- fromUserClients <$> Intra.lookupClients [usr]
    return . json $ clientIds usr clts

addClient :: UserId ::: ClientId -> Galley Response
addClient (usr ::: clt) = do
    Data.updateClient True usr clt
    return empty

rmClient :: UserId ::: ClientId -> Galley Response
rmClient (usr ::: clt) = do
    Data.updateClient False usr clt
    return empty
