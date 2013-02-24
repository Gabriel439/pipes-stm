module Control.Proxy.TQueue where

import Control.Monad
import Control.Proxy
import Control.Monad.STM
import Control.Concurrent.STM.TBQueue
import Control.Concurrent.STM.TQueue
import Control.Proxy.Safe
import Data.Maybe

chanProducer 
    :: (Proxy p)
    => chan                    -- ^ The channel.
    -> (chan -> IO (Maybe a))  -- ^ The 'read' function.
    -> (chan -> IO ())         -- ^ The 'close' function.
    -> () -> Producer (ExceptionP p) a SafeIO r
chanProducer ch readfn closefn () = finally id close produce
  where
    produce = forever $ do 
      item <- tryIO $ readfn ch
      unless (isNothing item) $ respond (fromJust item)

    close = closefn ch
{-# INLINE chanProducer #-}


chanConsumer
    :: (Proxy p)
    => chan                    -- ^ The channel.
    -> (chan -> a -> IO ())    -- ^ The 'write' function.
    -> (chan -> IO ())         -- ^ The 'close' function.
    -> () -> Consumer (ExceptionP p) a SafeIO r
chanConsumer ch writfn closefn () = finally id close consume
    where
      consume = forever $ do
        input <- request ()
        tryIO $ writfn ch input
      close = closefn ch
{-# INLINE chanConsumer #-}


-- | A simple wrapper around a TBQueue. As data is pushed into the channel, the
--   source will read it and pass it down the pipeline. When the
--   channel is closed, the source will close also.
--
--   If the channel fills up, the pipeline will stall until values are read.
sourceTBQueue :: (Proxy p) => TBQueue a -> () -> Producer (ExceptionP p) a SafeIO r
sourceTBQueue ch = chanProducer ch (atomically . tryReadTBQueue) doNothing
{-# INLINE sourceTBQueue #-}


-- | A simple wrapper around a TQueue. As data is pushed into the channel, the
--   source will read it and pass it down the pipeline. When the
--   channel is closed, the source will close also.
sourceTQueue :: (Proxy p) => TQueue a -> () -> Producer (ExceptionP p) a SafeIO r
sourceTQueue ch = chanProducer ch (atomically . tryReadTQueue) doNothing
{-# INLINE sourceTQueue #-}


-- | A simple wrapper around a TBQueue. As data is pushed into the sink, it
--   will magically begin to appear in the channel. If the channel is full,
--   the sink will block until space frees up. When the sink is closed, the
--   channel will close too.
sinkTBQueue :: (Proxy p) => TBQueue a -> () ->  Consumer (ExceptionP p) a SafeIO ()
sinkTBQueue ch = chanConsumer ch (\a -> atomically . writeTBQueue a) doNothing
{-# INLINE sinkTBQueue #-}


-- | A simple wrapper around a TQueue. As data is pushed into this sink, it
--   will magically begin to appear in the channel. When the sink is closed,
--   the channel will close too.
sinkTQueue :: (Proxy p) => TQueue a -> () -> Consumer (ExceptionP p) a SafeIO ()
sinkTQueue ch = chanConsumer ch (\a -> atomically . writeTQueue a) doNothing
{-# INLINE sinkTQueue #-}


doNothing :: b -> IO ()
doNothing = const $ return ()
{-# INLINE doNothing #-}
