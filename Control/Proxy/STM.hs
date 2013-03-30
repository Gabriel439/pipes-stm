-- | Actor-style communication between concurrent pipelines

{-# LANGUAGE PolymorphicComponents #-}

module Control.Proxy.STM (
    -- * Common API
    Process(..),
    Mailbox(..),
    sendD,

    -- * Implementations
    spawnBounded,
    spawnUnbounded,
    spawnSingle
    ) where

import Control.Applicative ((<|>), (<*), pure)
import Control.Monad.Trans.Class (lift)
import qualified Control.Concurrent.STM as S
import qualified Control.Proxy as P
import Data.IORef (newIORef, readIORef, mkWeakIORef, IORef)

-- | A 'Process' produces all values sent to its associated 'Mailbox'
newtype Process a = Process
    { run :: forall p . (P.Proxy p) => () -> P.Producer p a IO () }

-- | 'send' values to a 'Mailbox' to deliver them to the corresponding 'Process'
newtype Mailbox a = Mailbox { send :: a -> IO Bool }

-- | Writes all values flowing \'@D@\'ownstream to the given 'Mailbox'
sendD :: (P.Proxy p) => Mailbox a -> x -> p x a x a IO ()
sendD mailbox = P.runIdentityK loop
  where
    loop x = do
        a <- P.request x
        done <- lift $ send mailbox a
        if done
            then return ()
            else do
                x2 <- P.respond a
                loop x2

spawnWith
    :: IO (S.STM (Maybe a), Maybe a -> S.STM ()) -> IO (Mailbox a, Process a)
spawnWith create = do
    (read, write) <- create
    rUp  <- newIORef ()  -- Keep track of whether upstream pipes are still live
    rDn  <- newIORef ()  -- Keep track of whether the downstream pipe is live
    done <- S.newTVarIO False
    mkWeakIORef rUp (S.atomically $ write Nothing <|> pure ())
    mkWeakIORef rDn (S.atomically $ S.writeTVar done True)
    let quit = do
            b <- S.readTVar done
            S.check b
            return True
        continue a = do
            write (Just a)
            return False
        _send a = S.atomically (quit <|> continue a) <* readIORef rUp
    return (Mailbox _send , Process (sourceWith read rDn))

sourceWith
    :: (P.Proxy p) => S.STM (Maybe a) -> IORef () -> () -> P.Producer p a IO ()
sourceWith read rDn () = P.runIdentityP go
  where
    go = do
        ma <- lift $ S.atomically read
        lift $ readIORef rDn
        case ma of
            Nothing -> return ()
            Just a  -> do
                P.respond a
                go

{-| Spawn an associated 'Mailbox' and 'Process' that communicate using a
    'TBQueue'

    The 'Int' parameter specifies the size of the 'TBQueue'
-}
spawnBounded :: Int -> IO (Mailbox a, Process a)
spawnBounded n = spawnWith $ do
    q <- S.newTBQueueIO n
    return (S.readTBQueue q, S.writeTBQueue q)

{-| Spawn an associated 'Mailbox' and 'Process' that communicate using a
    'TQueue'
-}
spawnUnbounded :: IO (Mailbox a, Process a)
spawnUnbounded = spawnWith $ do
    q <- S.newTQueueIO
    return (S.readTQueue q, S.writeTQueue q)

{-| Spawn an associated 'Mailbox' and 'Process' that communicate using a 'TMVar'
-}
spawnSingle :: IO (Mailbox a, Process a)
spawnSingle = spawnWith $ do
    m <- S.newEmptyTMVarIO
    return (S.takeTMVar m, S.putTMVar m)
