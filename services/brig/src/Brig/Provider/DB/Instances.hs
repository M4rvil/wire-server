{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE StandaloneDeriving         #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Brig.Provider.DB.Instances () where

import Brig.Provider.DB.Tag
import Brig.Types.Provider
import Cassandra.CQL
import Data.ByteString.Conversion
import Data.Id()
import Data.Int
import Data.Misc()
import Data.Range()
import Data.Text.Ascii()

deriving instance Cql ServiceToken

instance Cql ServiceStatus where
    ctype = Tagged IntColumn

    toCql Unverified = CqlInt 0
    toCql Verified   = CqlInt 1

    fromCql (CqlInt i) = case i of
        0 -> return Unverified
        1 -> return Verified
        n -> fail $ "unexpected service status: " ++ show n
    fromCql _ = fail "service status: int expected"

instance Cql ServiceTag where
    ctype = Tagged BigIntColumn

    fromCql (CqlBigInt i) = case intToTag i of
        Just  t -> return t
        Nothing -> fail $ "unexpected service tag: " ++ show i
    fromCql _ = fail "service tag: int expected"

    toCql = CqlBigInt . tagToInt

instance Cql ServiceKeyPEM where
    ctype = Tagged BlobColumn

    fromCql (CqlBlob b) = maybe (fail "service key pem: malformed key")
                                pure
                                (fromByteString' b)
    fromCql _ = fail "service key pem: blob expected"

    toCql = CqlBlob . toByteString

instance Cql ServiceKey where
    ctype = Tagged (UdtColumn "pubkey"
        [ ("typ",  IntColumn)
        , ("size", IntColumn)
        , ("pem",  BlobColumn)
        ])

    fromCql (CqlUdt fs) = do
        t <- required "typ"
        s <- required "size"
        p <- required "pem"
        case (t :: Int32) of
            0 -> return $! ServiceKey RsaServiceKey s p
            _ -> fail $ "Unexpected service key type: " ++ show t
      where
        required f = maybe (fail ("ServiceKey: Missing required field '" ++ show f ++ "'"))
                           fromCql
                           (lookup f fs)
    fromCql _ = fail "service key: udt expected"

    toCql (ServiceKey RsaServiceKey siz pem) = CqlUdt
        [ ("typ",  CqlInt 0)
        , ("size", toCql siz)
        , ("pem",  toCql pem)
        ]

