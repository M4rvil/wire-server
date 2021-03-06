{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns        #-}

module Ropes.Nexmo
    ( -- * Types
      ApiKey (..)
    , ApiSecret (..)
    , ApiEndpoint (..)
    , Credentials
    , ParseError (..)
    , Charset (..)

      -- * SMS
    , MessageErrorResponse (..)
    , MessageErrorStatus (..)
    , Message (..)
    , MessageId
    , MessageResponse

      -- * Call
    , Call (..)
    , CallId
    , CallErrorResponse (..)
    , CallErrorStatus (..)

      -- * Functions
    , sendCall
    , sendMessage
    , sendMessages
    , sendFeedback

    , msgIds
    ) where

import Control.Applicative
import Control.Exception
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid ((<>))
import Data.Text (Text, toLower, unpack)
import Data.Text.Encoding (decodeLatin1, decodeUtf8)
import Data.Time (UTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Traversable (forM)
import Data.Typeable
import Network.HTTP.Client hiding (Response)
import Network.HTTP.Types
import Prelude hiding (head, length)

import qualified Data.List.NonEmpty as N

-- * Types

newtype ApiKey = ApiKey ByteString
newtype ApiSecret = ApiSecret ByteString
data ApiEndpoint = Production | Sandbox
    deriving (Show)

instance FromJSON ApiEndpoint where
    parseJSON = withText "NexmoApiEndpoint" $ \s ->
        case toLower s of
            "sandbox" -> pure Sandbox
            "production" -> pure Production
            other -> fail $ "Unsupported Nexmo environment: " ++ unpack other

data Charset = GSM7 | GSM8 | UCS2 deriving (Eq, Show)

type Credentials = (ApiKey, ApiSecret)

-- * SMS related
newtype MessageId = MessageId { messageIdText :: Text } deriving (Eq, Show)

data Message = Message
    { msgFrom :: !Text
    , msgTo   :: !Text
    , msgText :: !Text
    , msgType :: !Charset
    } deriving (Eq, Show)

newtype MessageResponse = MessageResponse { msgIds :: NonEmpty MessageId }
    deriving (Eq, Show)

data MessageErrorStatus = MessageThrottled
                        | MessageInternal
                        | MessageUnroutable
                        | MessageNumBarred
                        | MessagePartnerAccountBarred
                        | MessagePartnerQuotaExceeded
                        | MessageTooLong
                        | MessageCommunicationFailed
                        | MessageInvalidSenderAddress
                        | MessageFacilityNotAllowed
                        | MessageInvalidMessageClass
                        | MessageOther
                        deriving (Eq, Show)

instance FromJSON MessageErrorStatus where
    parseJSON "1"  = return MessageThrottled
    parseJSON "5"  = return MessageInternal
    parseJSON "6"  = return MessageUnroutable
    parseJSON "7"  = return MessageNumBarred
    parseJSON "8"  = return MessagePartnerAccountBarred
    parseJSON "9"  = return MessagePartnerQuotaExceeded
    parseJSON "12" = return MessageTooLong
    parseJSON "13" = return MessageCommunicationFailed
    parseJSON "15" = return MessageInvalidSenderAddress
    parseJSON "19" = return MessageFacilityNotAllowed
    parseJSON "20" = return MessageInvalidMessageClass
    parseJSON _    = return MessageOther

data MessageErrorResponse = MessageErrorResponse
    { erStatus    :: !MessageErrorStatus
    , erErrorText :: !(Maybe Text)
    } deriving (Eq, Show, Typeable)

instance Exception MessageErrorResponse

instance FromJSON MessageErrorResponse where
    parseJSON = withObject "message-error-response" $ \o ->
        MessageErrorResponse <$> o .:  "status"
                             <*> o .:? "error-text"

newtype ParseError = ParseError String
    deriving (Eq, Show, Typeable)

instance Exception ParseError

instance FromJSON MessageId where
    parseJSON = withText "MessageId" $ return . MessageId

instance ToJSON MessageId where
    toJSON = String . messageIdText

instance FromJSON Charset where
    parseJSON "text"    = return GSM7
    parseJSON "binary"  = return GSM8
    parseJSON "unicode" = return UCS2
    parseJSON x         = fail $ "Unsupported charset " <> (show x)

instance ToJSON Charset where
    toJSON GSM7 = "text"
    toJSON GSM8 = "binary"
    toJSON UCS2 = "unicode"

-- * Internal message parsers

parseMessageFeedback :: Value -> Parser (Either MessageErrorResponse MessageId)
parseMessageFeedback j@(Object o) = do
    st <- o .: "status"
    case (st :: Text) of
      "0" -> Right <$> parseMessageId j
      _   -> Left  <$> parseJSON j
parseMessageFeedback _ = fail "Ropes.Nexmo: message should be an object"

parseMessageId :: Value -> Parser MessageId
parseMessageId = withObject "message-response" (.: "message-id")

parseMessageResponse :: Value -> Parser (Either MessageErrorResponse MessageResponse)
parseMessageResponse = withObject "nexmo-response" $ \o -> do
    xs <- o .: "messages"
    ys <- sequence <$> mapM parseMessageFeedback xs
    case ys of
      Left  e      -> return $ Left e
      Right (f:fs) -> return $ Right $ MessageResponse (f :| fs)
      Right _      -> fail "Must have at least one message-id"

-- * Call related

newtype CallId = CallId { callIdText :: Text } deriving (Eq, Show)

data Call = Call
    { callFrom   :: !(Maybe Text)
    , callTo     :: !Text
    , callText   :: !Text
    , callLang   :: !(Maybe Text)
    , callRepeat :: !(Maybe Int)
    }

data CallErrorStatus = CallThrottled
                     | CallInternal
                     | CallDestinationNotPermitted
                     | CallDestinationBarred
                     | CallPartnerQuotaExceeded
                     | CallInvalidDestinationAddress
                     | CallUnroutable
                     | CallOther
                     deriving (Eq, Show)

instance FromJSON CallErrorStatus where
    parseJSON "1"  = return CallThrottled
    parseJSON "5"  = return CallInternal
    parseJSON "6"  = return CallDestinationNotPermitted
    parseJSON "7"  = return CallDestinationBarred
    parseJSON "9"  = return CallPartnerQuotaExceeded
    parseJSON "15" = return CallInvalidDestinationAddress
    parseJSON "17" = return CallUnroutable
    parseJSON _    = return CallOther

data CallErrorResponse = CallErrorResponse
    { caStatus    :: !CallErrorStatus
    , caErrorText :: !(Maybe Text)
    } deriving (Eq, Show, Typeable)

instance Exception CallErrorResponse

instance FromJSON CallErrorResponse where
    parseJSON = withObject "call-error-response" $ \o ->
        CallErrorResponse <$> o .:  "status"
                          <*> o .:? "error-text"

-- * Internal call parsers

parseCallId :: Value -> Parser CallId
parseCallId = withObject "call-response" $ \o ->
    CallId <$> o .: "call_id"

parseCallResponse :: Value -> Parser (Either CallErrorResponse CallId)
parseCallResponse j@(Object o) = do
    st <- o .: "status"
    case (st :: Text) of
      "0" -> Right <$> parseCallId j
      _   -> Left  <$> parseJSON j
parseCallResponse _ = fail "Ropes.Nexmo: response should be an object"

-- * Feedback related

data Feedback = Feedback
    { feedbackId        :: !(Either CallId MessageId)
    , feedbackTime      :: !UTCTime
    , feedbackDelivered :: !Bool
    } deriving (Eq, Show)

data FeedbackErrorResponse = FeedbackErrorResponse Text
    deriving (Eq, Show)

instance Exception FeedbackErrorResponse

-- * Functions

sendCall :: Credentials -> Manager -> Call -> IO CallId
sendCall cr mgr call = httpLbs req mgr >>= parseResult
  where
    parseResult res = case parseEither parseCallResponse =<< eitherDecode (responseBody res) of
        Left  e -> throwIO $ ParseError e
        Right r -> either throwIO return r

    req = defaultRequest
        { method         = "POST"
        , host           = "api.nexmo.com"
        , secure         = True
        , port           = 443
        , path           = "/tts/json"
        , requestBody    = RequestBodyLBS $ encode body
        , requestHeaders = [(hContentType, "application/json")]
        }

    (ApiKey key, ApiSecret secret) = cr

    body = object
         [ "api_key"    .= decodeLatin1 key
         , "api_secret" .= decodeLatin1 secret
         , "from"       .= callFrom call
         , "to"         .= callTo call
         , "text"       .= callText call
         , "repeat"     .= callRepeat call
         , "lg"         .= callLang call
         ]

sendFeedback :: Credentials -> Manager -> Feedback -> IO ()
sendFeedback cr mgr fb = httpLbs req mgr >>= parseResponse
  where
    req = defaultRequest
        { method         = "POST"
        , host           = "api.nexmo.com"
        , secure         = True
        , port           = 443
        , path           = either
                            (const "/conversions/voice")
                            (const "/conversions/sms")
                            (feedbackId fb)
        , requestBody    = RequestBodyLBS $ encode body
        , requestHeaders = [(hContentType, "application/json")]
        }

    (ApiKey key, ApiSecret secret) = cr

    body = object
       [ "api_key"    .= decodeLatin1 key
       , "api_secret" .= decodeLatin1 secret
       , "message-id" .= either callIdText messageIdText (feedbackId fb)
       , "delivered"  .= feedbackDelivered fb
       , "timestamp"  .= nexmoTimeFormat (feedbackTime fb)
       ]

    -- Format as specified https://docs.nexmo.com/api-ref/conversion-api/request
    -- Note that the claim that "If you do not set this parameter, the Cloud
    -- Communications Platform uses the time it recieves this request." is false
    -- You must _always_ specify a timestamp
    nexmoTimeFormat = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S"

    parseResponse res = unless (responseStatus res == status200) $
        throwIO $ FeedbackErrorResponse (decodeUtf8 . toStrict . responseBody $ res)

sendMessage :: Credentials -> ApiEndpoint -> Manager -> Message -> IO MessageResponse
sendMessage cr env mgr msg = N.head <$> sendMessages cr env mgr (msg :| [])

sendMessages :: Credentials -> ApiEndpoint -> Manager -> NonEmpty Message -> IO (NonEmpty MessageResponse)
sendMessages cr env  mgr msgs = forM msgs $ \m -> httpLbs (req m) mgr >>= parseResult
  where
    parseResult res = case parseEither parseMessageResponse =<< eitherDecode (responseBody res) of
        Left  e -> throwIO $ ParseError e
        Right r -> either throwIO return r

    req m = defaultRequest
          { method         = "POST"
          , host           = case env of
                               Production -> "rest.nexmo.com"
                               Sandbox    -> "rest-sandbox.nexmo.com"
          , secure         = True
          , port           = 443
          , path           = "/sms/json"
          , requestBody    = RequestBodyLBS $ encode (body m)
          , requestHeaders = [(hContentType, "application/json")]
          }

    (ApiKey key, ApiSecret secret) = cr

    body m = object
           [ "api_key"    .= decodeLatin1 key
           , "api_secret" .= decodeLatin1 secret
           , "from"       .= msgFrom m
           , "to"         .= msgTo m
           , "text"       .= msgText m
           , "type"       .= msgType m
           ]
