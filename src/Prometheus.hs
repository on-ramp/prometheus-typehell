{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Prometheus
    -- * Basic metric types
  ( counter
  , gauge
  , histogram
  , summary
    -- * Operations on metric types
    -- ** Construction/Teardown
  , Registrable(..)
  , GenericRegistrable
  , genericRegister
  , Extractable(..)
  , Prometheus.export
  , GenericExportable
  , genericExport
    -- ** Collecting data
  , Incrementable(..)
  , Decrementable(..)
  , Settable(..)
  , Observable(..)
    -- * Vector
  , vector
  , withLabel
    -- * Additional operations
  , time
  , push
    -- * Additional types
  , Info(..)
  , infoM
    -- * Re-exports
  , module Data.Default
  , module Prometheus.Primitive
  , module Prometheus.Vector
  , NoIdentity
  , Metric
  ) where

import           Prometheus.Internal.Base    hiding (genericExport)
import qualified Prometheus.Internal.Base    as Base
import           Prometheus.Internal.Pure    (Bucket, Label, NoIdentity, Quantile)
import           Prometheus.Primitive
import           Prometheus.Vector

import           Protolude

import           Control.Retry
import           Data.Default
import           Data.Time.Clock
import           Network.HTTP.Client.Conduit
import           Network.HTTP.Simple
import           Network.HTTP.Types

-- | A [monotonically increasing counter](https://prometheus.io/docs/concepts/metric_types/#counter).
--
--   Member of typeclass 'Incrementable'.
--
--   Note: '.=.' only updates the counter if the new value is larger than
--   the previous one. Do __not__ use '.+.' with negative values when using counters,
--   [it makes kittens cry](https://prometheus.io/docs/instrumenting/writing_clientlibs/#counter)
counter :: Info -> Metric Counter
counter = construct . (, ())

-- | A [freely shiftable gauge](https://prometheus.io/docs/concepts/metric_types/#gauge).
--
--   Member of typeclasses 'Incrementable' and 'Shiftable'.
gauge :: Info -> Metric Gauge
gauge = construct . (, ())

-- | A [simple cumulative histogram](https://prometheus.io/docs/concepts/metric_types/#histogram)
--
--   Member of typeclass 'Observable'.
histogram :: Info -> [Bucket] -> Metric Histogram
histogram = curry construct

-- | A [complicated φ-quantile summary](https://prometheus.io/docs/concepts/metric_types/#summary)
--
--   Member of typeclass 'Observable'.
summary :: Info -> [Quantile] -> Metric Summary
summary = curry construct

export :: Exportable a => a -> IO LByteString
export = fmap template . Base.export

-- | Convert any 'Generic' metric datatype into a Prometheus-compatible 'LByteString'
genericExport :: GenericExportable f => f Identity -> IO LByteString
genericExport = fmap (mconcat . fmap template) . Base.genericExport

-- | A 'Vector' is an array of similar metrics that differ only in labels.
vector ::
     ( Label l
     , Glue s ~ Metric' o Identity i
     , Glue (Vector l s) ~ Metric' (l, o) (Map l) i
     )
  => l
  -> Metric s
  -> Metric (Vector l s)
vector = curry construct

-- | The only way to use a vector.
--
--   If basic metrics are used as e.g.
--
--   > metric `observe` 2.6
--
--   then the 'withLabel' usage looks like
--
--   > withLabel "label" metric (`observe` 2.6)
withLabel :: Label l => l -> Vector l s -> ((l, Vector l s) -> t) -> t
withLabel l v a = a (l, v)

-- | Measure the time it takes for the action to process, then passes time to the action
--   in a separate thread.
--
--   The first argument is either 'liftIO' in case of 'MonadIO' or 'identity' in case of 'IO'
time :: Monad m => (forall b. IO b -> m b) -> (Double -> IO ()) -> m a -> m a
time toIO f action = do
  t <- toIO getCurrentTime
  result <- action
  t' <- toIO getCurrentTime
  _thread <- toIO . forkIO . f . realToFrac $ diffUTCTime t' t
  return result

-- | Pushes metrics to a server.
--
--   Will definitely return 'InvalidUrlException' if the provided address is inaccessible
--   or a matching 'SomeException' if the push fails.
push ::
     IO LByteString
  -> [Char] -- ^ Server to push to
  -> IO (Either SomeException (Response ByteString))
push exportfunc mayAddress =
  case parseRequest mayAddress of
    Left ex -> return $ Left ex
    Right address -> do
      exported <- exportfunc
      makePost $
        (try $ httpBS . setRequestMethod "POST" . setRequestBodyLBS exported $ address)

makePost :: IO (Either SomeException (Response ByteString)) -> IO (Either SomeException (Response ByteString))
makePost = retrying retryDefPolicy shouldRetry . const

shouldRetry :: Monad m => p -> Either SomeException (Response body) -> m Bool
shouldRetry _ = fmap not . isOk

isOk :: Monad m => Either SomeException (Response body) -> m Bool
isOk (Left _) = return False
isOk (Right response) =
  return $ any ((==) . statusCode . responseStatus $ response) [200 .. 299]

retryDefPolicy :: RetryPolicy
retryDefPolicy = exponentialBackoff 200000 <> limitRetries threshold

threshold :: Int
threshold = 5
