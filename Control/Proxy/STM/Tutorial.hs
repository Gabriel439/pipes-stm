{-| This module provides a tutorial for the @pipes-concurrency@ library.

    This tutorial assumes that you have read the @pipes@ tutorial in
    @Control.Proxy.Tutorial@.
-}

module Control.Proxy.STM.Tutorial (
    -- * Introduction
    -- $intro

    -- * Work Stealing
    -- $steal

    -- * Termination
    -- $termination

    -- * Buffer Sizes
    -- $buffer

    -- * Callbacks
    -- $callback

    -- * Safety
    -- $safety

    -- * Conclusion
    -- $conclusion
    ) where

import Control.Exception (BlockedIndefinitelyOnSTM)
import Control.Proxy
import Control.Proxy.STM

{- $intro
    The @pipes-concurrency@ library provides a simple interface for
    communicating between concurrent pipelines.  Use this library if you want
    to:

    * merge multiple streams into a single stream,

    * stream data from a callback \/ continuation,

    * implement a work-stealing setup, or

    * implement basic functional reactive programming (FRP).

    For example, let's say that we design a simple game with a single unit's
    health as the global state and define an event handler that modifies the
    unit's health in response to events:

> import Control.Monad
> import Control.Proxy
> import Control.Proxy.Trans.Maybe
> import Control.Proxy.Trans.State
> 
> data Event = Harm Integer | Heal Integer | Quit
> 
> type Health = Integer
> 
> handler :: (Proxy p) => () -> Consumer (StateP Health (MaybeP p)) Event IO r
> handler () = forever $ do
>     event <- request ()
>     case event of
>         Harm n -> modify (subtract n)
>         Heal n -> modify (+        n)
>         Quit   -> mzero
>     health <- get
>     lift $ putStrLn $ "Health = " ++ show health

    However, we have two concurrent event sources that we wish to hook up to our
    event handler.  One translates user input to game events:

> user :: (Proxy p) => () -> Producer p Event IO ()
> user () = runIdentityP $ forever $ do
>     command <- lift getLine
>     case command of
>         "potion" -> respond (Heal 10)
>         "quit"   -> respond  Quit
>         _        -> lift $ putStrLn "Invalid command"

    ... while the other creates inclement weather:

> import Control.Concurrent
>
> acidRain :: (Proxy p) => () -> Producer p Event IO r
> acidRain () = runIdentityP $ forever $ do
>     respond (Harm 1)
>     lift $ threadDelay 2000000

    To merge these sources, we 'spawn' a new FIFO buffer which we will use to
    merge the two streams of asynchronous events:

> spawn :: Size -> IO (Input a, Output a)

    'spawn' takes a buffer 'Size' as an argument, and we specify that we want
    our buffer to store an 'Unbounded' number of message.  'spawn' creates
    this buffer in the background and then returns two values:

    * an @(Input a)@ that we use to add messages of type @a@ in the buffer

    * an @(Output a)@ that we use to consume messages of type @a@ from the
      buffer

> import Control.Proxy.STM
>
> main = do
>     (input, output) <- spawn Unbounded
>     ...

    We will be streaming @Event@s through our buffer, so our @input@ has type
    @(Input Event)@ and our @output@ has type @(Output Event)@.

    To stream @Event@s into the buffer, we use 'sendD', which writes values to
    the buffer's 'Input' end:

> sendD :: (Proxy p) => Input a -> x -> p x a x a IO ()

    We can concurrently forward multiple streams to the same 'Input', which
    asynchronously merges their messages into the same buffer:

>     ...
>     forkIO $ do runProxy $ acidRain >-> sendD input
>                 performGC  -- I'll explain 'performGC' below
>     forkIO $ do runProxy $ user     >-> sendD input
>                 performGC
>     ...

    To stream @Event@s out of the buffer, we use 'recvS', which reads values
    from the buffer's 'Output' end:

> recvS :: (Proxy p) => Output a -> () -> Producer p a IO ()

    We will forward our merged stream to our @handler@ so that it can listen to
    both @Event@ sources:

>     ...
>     runProxy $ runMaybeK $ evalStateK 100 $ recvS output >-> handler

    Our final @main@ becomes:

> main = do
>     (input, output) <- spawn Unbounded
>     forkIO $ runProxy $ acidRain >-> sendD input
>     forkIO $ runProxy $ user     >-> sendD input
>     runProxy $ runMaybeK $ evalStateK 100 $ recvS output >-> handler

    ... and when we run it we get the desired concurrent behavior:

> $ ./game
> Health = 99
> Health = 98
> potion<Enter>
> Health = 108
> Health = 107
> Health = 106
> potion<Enter>
> Health = 116
> Health = 115
> quit<Enter>
> $
-}

{- $steal
    You can also have multiple pipes reading from the same 'Buffer'.  Messages
    get split between listening pipes on a first-come first-serve basis.

    For example, we'll define a \"worker\" that takes a one-second break each
    time it receives a new job:

> import Control.Concurrent
> import Control.Monad
> import Control.Proxy
> 
> worker :: (Proxy p, Show a) => Int -> () -> Consumer p a IO r
> worker i () = runIdentityP $ forever $ do
>     a <- request ()
>     lift $ threadDelay 1000000  -- 1 second
>     lift $ putStrLn $ "Worker #" ++ show i ++ ": Processed " ++ show a

    Fortunately, these workers are cheap, so we can assign several of them to
    the same job:

> import Control.Concurrent.Async
> import Control.Proxy.STM
> 
> main = do
>     (input, output) <- spawn Unbounded
>     as <- forM [1..3] $ \i ->
>           async $ do runProxy $ recvS output >-> worker i
>                      performGC
>     a  <- async $ do runProxy $ fromListS [1..10] >-> sendD input
>                      performGC
>     mapM_ wait (a:as)

    The above example uses @Control.Concurrent.Async@ from the @async@ to fork
    each thread and wait for all of them to terminate:

> $ ./work
> Worker #2: Processed 3
> Worker #1: Processed 2
> Worker #3: Processed 1
> Worker #3: Processed 6
> Worker #1: Processed 5
> Worker #2: Processed 4
> Worker #2: Processed 9
> Worker #1: Processed 8
> Worker #3: Processed 7
> Worker #2: Processed 10
> $

    What if we replace 'fromListS' with a different source that reads lines from
    user input until the user types \"quit\":

> user :: (Proxy p) => () -> Producer p String IO ()
> user = stdinS >-> takeWhileD (/= "quit")
> 
> main = do
>     (input, output) <- spawn Unbounded
>     as <- forM [1..3] $ \i ->
>           async $ do runProxy $ recvS output >-> worker i
>                      performGC
>     a  <- async $ do runProxy $ user >-> sendD input
>                      performGC
>     mapM_ wait (a:as)

    This still produces the correct behavior:

> $ ./work
> Test<Enter>
> Worker #1: Processed "Test"
> Apple<Enter>
> Worker #2: Processed "Apple"
> 42<Enter>
> Worker #3: Processed "42"
> A<Enter>
> B<Enter>
> C<Enter>
> Worker #1: Processed "A"
> Worker #2: Processed "B"
> Worker #3: Processed "C"
> quit<Enter>
> $
-}

{- $termination

    Wait...  How do the workers know when to stop listening for data?  After
    all, anything that has a reference to 'Input' could potentially add more
    data to the buffer.

    It turns out that 'recvS' is smart and only terminates when the upstream
    'Input' is garbage collected.  'recvS' builds on top of the more primitive
    'recv' command, which returns a 'Nothing' when the 'Input' is garbage
    collected:

> recv :: Output a -> STM (Maybe a)

    Otherwise, 'recv' blocks if the buffer is empty since it assumes that if the
    'Input' has not been garbage collected then somebody might still produce
    more data.

    Does it work the other way around?  What happens if the workers go on strike
    before processing the entire data set?

> -- Each worker refuses to process more than two values
> worker :: (Proxy p, Show a) => Int -> () -> Consumer p a IO ()
> worker i () = runIdentityP $ replicateM_ 2 $ do
>     a <- request ()
>     lift $ threadDelay 1000000
>     lift $ putStrLn $ "Worker #" ++ show i ++ ": Processed " ++ show a

> $ ./work
> How<Enter>
> Worker #1: Processed "How"
> many<Enter>
> roads<Enter>
> Worker #2: Processed "many"
> Worker #3: Processed "roads"
> must<Enter>
> a<Enter>
> man<Enter>
> Worker #1: Processed "must"
> Worker #2: Processed "a"
> Worker #3: Processed "man"
> walk<Enter>
> $

    'sendD' similarly shuts down when the 'Output' is garbage collected,
    preventing the user from submitting new values.  'sendD' builds on top of
    the more primitive 'send' command, which returns a 'False' when the 'Output'
    is garbage collected:

> send :: Input a -> a -> STM Bool

    Otherwise, 'send' blocks if the buffer is full, since it assumes that if the
    'Output' has not been garbage collected then somebody could still consume a
    value from the buffer, making room for a new value.

    This is why we have to insert 'performGC' calls whenever we release a
    reference to either the 'Input' or 'Output'.  Without these calls we cannot
    guarantee that the garbage collector will trigger and notify the opposing
    end if the last reference was released.
-}

{- $buffer
    So far we haven't observed 'send' blocking because we only 'spawn'ed
    'Unbounded' buffers.  However, we can control the size of the buffer to tune
    the coupling between the 'Input' and the 'Output' ends.

    If we set the buffer 'Size' to 'Single', then the buffer holds exactly one
    message, forcing synchronization between 'send's and 'recv's.  Let's
    observe this by sending an infinite stream of values, logging all values to
    'stdout':

> main = do
>     (input, output) <- spawn Single
>     as <- forM [1..3] $ \i ->
>           async $ do runProxy $ recvS output >-> worker i
>                      performGC
>     a  <- async $ do runProxy $ enumFromS 1 >-> printD >-> sendD input
>                      performGC
>     mapM_ wait (a:as)

    The 7th value gets stuck in the buffer, and the 8th value blocks because the
    buffer never clears the 7th value:

> $ ./work
> 1
> 2
> 3
> 4
> 5
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 6
> 7
> 8
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> $

    Contrast this with an 'Unbounded' buffer for the same program, which keeps
    accepting values until downstream finishes processing the first six values:

> $ ./work
> 1
> 2
> 3
> 4
> 5
> 6
> 7
> 8
> 9
> ...
> 487887
> 487888
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 487889
> 487890
> ...
> 969188
> 969189
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> 969190
> 969191
> $

    You can also choose something in between by using a 'Bounded' buffer which
    caps the buffer size to a fixed value.  Use 'Bounded' when you want mostly
    loose coupling but still want to guarantee bounded memory usage:

> main = do
>     (input, output) <- spawn (Bounded 100)
>     ...

> $ ./work
> ...
> 103
> 104
> Worker #3: Processed 3
> Worker #2: Processed 2
> Worker #1: Processed 1
> 105
> 106
> 107
> Worker #1: Processed 6
> Worker #2: Processed 5
> Worker #3: Processed 4
> $
-}

{- $callback
    @pipes-concurrency@ also solves the common problem of getting data out of a
    callback-based framework into @pipes@.

    For example, suppose that we have the following callback-based function:

> import Control.Monad
> 
> onLines :: (String -> IO a) -> IO b
> onLines callback = forever $ do
>     str <- getLine
>     callback str

    We use 'send' to free the data from the callback and retrieve the data on
    the outside using 'recvS':

> import Control.Proxy
> import Control.Proxy.STM
> 
> onLines' :: (Proxy p) => () -> Producer p String IO ()
> onLines' () = runIdentityP $ do
>     (input, output) <- lift $ spawn Single
>     lift $ forkIO $ onLines (\str -> atomically $ send input str)
>     recvS output ()
> 
> main = runProxy $ onLines' >-> takeWhileD (/= "quit) >-> stdoutD

    Now we can stream from the callback as if it were an ordinary 'Producer':

> $ ./callback
> Test<Enter>
> Test
> Apple<Enter>
> Apple
> quit<Enter>
> $

-}

{- $safety
    'STM' veterans will notice that @pipes-concurrency@ never throws a
    'BlockedIndefinitelyOnSTM' exception, or any other concurrency exception.
    @pipes-concurrency@ protects against these exceptions by guaranteeing that
    'send' and 'recv' never throw them.  This safe-guard eliminates the largest
    class of 'STM' programming bugs.

    @pipes-concurrency@ safely protects against even the most pathological use
    cases, including:

    * multiple readers and multiple writers to the same buffer,

    * large graphs of connected buffers,

    * dynamically adding or removing buffers, and

    * dynamically adding or removing references to buffers.
-}

{- $conclusion
    Like all coroutines, @pipes@ are a form of deterministic concurrency, and in
    any given pipeline you can only have one active stage at all times.
    @pipes-concurrency@ adds an asynchronous dimension to @pipes@ by allowing
    you to fork one pipeline per concurrent behavior and seamlessly communicate
    between them.
-}
