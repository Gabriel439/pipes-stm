-- | Asynchronous communication between proxies

{-# LANGUAGE Trustworthy #-}
{- 'unsafeIOToSTM' requires the Trustworthy annotation.

    I use 'unsafeIOToSTM' to touch an IORef to mark it as still alive. This
    action satisfies the necessary safety requirements because:

    * You can safely repeat it if the transaction rolls back

    * It does not acquire any resources

    * It does not leak any inconsistent view of memory to the outside world

    It appears to be unnecessary to read the IORef to keep it from being garbage
    collected, but I wanted to be absolutely certain since I cannot be sure that
    GHC won't optimize away the reference to the IORef.

    The other alternative was to make 'send' and 'recv' use the 'IO' monad
    instead of 'STM', but I felt that it was important to preserve the ability
    to combine them into larger transactions.
-}

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
    recvS
    ) where

import Control.Applicative ((<|>), (<*), pure)
import Control.Monad.Trans.Class (lift)
import qualified Control.Concurrent.STM as S
import qualified Control.Proxy as P
import Data.IORef (newIORef, readIORef, mkWeakIORef, IORef)
import GHC.Conc.Sync (unsafeIOToSTM)

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

    {- Use an IORef to keep track of whether the 'Input' end has been garbage
       collected and run a finalizer when the collection occurs

       The finalizer cannot anticipate how many listeners there are, so it only
       writes a single 'Nothing' and trusts that the supplied 'read' action
       will not consume the 'Nothing'.

       The 'write' must be protected with the @pure ()@ fallback so that it does
       not trigger an 'IndefinitelyBlockedOnSTM' exception if the 'Output' end
       has also been garbage collected.
    -}
    rUp  <- newIORef ()
    mkWeakIORef rUp (S.atomically $ write Nothing <|> pure ())

    {- Use an IORef to keep track of whether the 'Output' end has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rDn  <- newIORef ()
    done <- S.newTVarIO False
    mkWeakIORef rDn (S.atomically $ S.writeTVar done True)

    let quit = do
            b <- S.readTVar done
            S.check b
            return False
        continue a = do
            write (Just a)
            return True
        {- The '_send' action aborts if the 'Output' has been garbage collected,
           since there is no point wasting memory if nothing can empty the
           'Buffer'. This protects against careless users not checking send's
           return value, especially if they use an 'Unbounded' buffer.

           The '_send' action prevents 'rUp' from being garbage collected, thus
           delaying the 'Input' finalization until no more references to
           '_send' are available. The '_recv' action, 'rDn' and 'Output' are
           related in the same way.
        -}
        _send a = (quit <|> continue a) <* unsafeIOToSTM (readIORef rUp)
        _recv = read <* unsafeIOToSTM (readIORef rDn)
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
    {-| Send a message to the 'Input' end

        * Retries if the 'Buffer' is full and the associated 'Output' hasn't
          been garbage collected.

        * Succeeds and returns 'True' if the 'Buffer' is not full.

        * Fails and returns 'False' if the 'Output' has been garbage collected.
    -}
    send :: a -> S.STM Bool }

-- | Produces all messages sent to the associated 'Input'
newtype Output a = Output {
    {-| Receive a message from the 'Output' end

        * Retries if the 'Buffer' is empty and the associated 'Input' hasn't been
          garbage collected.

        * Succeeds and returns a 'Just' if the 'Buffer' is not empty.

        * Fails and returns 'Nothing' if the 'Input' has been garbage collected.
    -}
    recv :: S.STM (Maybe a) }

{-| Writes all messages flowing \'@D@\'ownstream to the given 'Input'

    'sendD' terminates when the corresponding 'Output' has been garbage collected.
-}
sendD :: (P.Proxy p) => Input a -> x -> p x a x a IO ()
sendD mailbox = P.runIdentityK loop
  where
    loop x = do
        a <- P.request x
        alive <- lift $ S.atomically $ send mailbox a
        if alive
            then do
                x2 <- P.respond a
                loop x2
            else return ()

{-| Convert an 'Output' to a 'P.Producer'

    'recvS' terminates when the corresponding 'Input' is garbage collected.
-}
recvS :: (P.Proxy p) => Output a -> () -> P.Producer p a IO ()
recvS process () = P.runIdentityP go
  where
    go = do
        ma <- lift $ S.atomically $ recv process
        case ma of
            Nothing -> return ()
            Just a  -> do
                P.respond a
                go
