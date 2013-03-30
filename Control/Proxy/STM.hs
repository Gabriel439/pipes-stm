-- | Asynchronous communication between concurrent pipelines

module Control.Proxy.STM (
    -- * Spawn Inputs and Outputs
    spawn,
    Buffer(..),
    Input,
    Output,

    -- * Send and receive messages
    send,
    recv,

    -- * Proxy utilities
    sendD,
    runS
    ) where

import Control.Applicative ((<|>), (<*), pure)
import Control.Monad.Trans.Class (lift)
import qualified Control.Concurrent.STM as S
import qualified Control.Proxy as P
import Data.IORef (newIORef, readIORef, mkWeakIORef, IORef)

{-| Spawn an 'Input' \/ 'Output' pair that communicate using the specified
    'Buffer'
-}
spawn :: Buffer -> IO (Input a, Output a)
spawn buffer = spawnWith $ case buffer of
    Bounded n -> do
        q <- S.newTBQueueIO n
        let read = do
                ma <- S.readTBQueue q
                case ma of
                    Nothing -> S.unGetTBQueue q ma
                    _       -> return ()
                return ma
        return (read, S.writeTBQueue q)
    Unbounded -> do
        q <- S.newTQueueIO
        let read = do
                ma <- S.readTQueue q
                case ma of
                    Nothing -> S.unGetTQueue q ma
                    _       -> return ()
                return ma
        return (read, S.writeTQueue q)
    Single    -> do
        m <- S.newEmptyTMVarIO
        let read = do
                ma <- S.takeTMVar m
                case ma of
                    Nothing -> S.putTMVar m ma
                    _       -> return ()
                return ma
        return (read, S.putTMVar m)

spawnWith
    :: IO (S.STM (Maybe a), Maybe a -> S.STM ()) -> IO (Input a, Output a)
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
            return False
        continue a = do
            write (Just a)
            return True
        _send a = S.atomically (quit <|> continue a) <* readIORef rUp
        _recv = S.atomically read <* readIORef rDn
    return (Input _send , Output _recv)

{-| 'Buffer' specifies how many messages to buffer between the 'Input' and
    'Output' before 'send' blocks.
-}
data Buffer
    -- | Store an unlimited number of messages
    = Unbounded
    -- | Store a finite number of messages specified by the 'Int' argument
    | Bounded Int
    -- | Store only a single message (like @Bounded 1@, but more efficient)
    | Single

-- | Receives messages for the associated 'Output'
newtype Input a = Input {
    {-| Send a message to the 'Input' end, blocking if the 'Buffer' is full

        Returns 'False' if the associated 'Output' is garbage collected, 'True'
        otherwise
    -}
    send :: a -> IO Bool }

-- | Produces all messages sent to the associated 'Input'
newtype Output a = Output {
    {-| Receive a message from the 'Output' end, blocking while the 'Buffer' is
        empty

        Returns 'Nothing' if the 'Input' end has been garbage collected
    -}
    recv :: IO (Maybe a) }

{-| Writes all messages flowing \'@D@\'ownstream to the given 'Input'

    'sendD' terminates when the corresponding 'Output' is garbage collected.
-}
sendD :: (P.Proxy p) => Input a -> x -> p x a x a IO ()
sendD mailbox = P.runIdentityK loop
  where
    loop x = do
        a <- P.request x
        alive <- lift $ send mailbox a
        if alive
            then do
                x2 <- P.respond a
                loop x2
            else return ()

{-| Convert an 'Output' to a 'P.Producer'

    'runS' terminates when the corresponding 'Input' is garbage collected.
-}
runS :: (P.Proxy p) => Output a -> () -> P.Producer p a IO ()
runS process () = P.runIdentityP go
  where
    go = do
        ma <- lift $ recv process
        case ma of
            Nothing -> return ()
            Just a  -> do
                P.respond a
                go
