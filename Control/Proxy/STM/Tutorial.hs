{-| This module provides a tutorial for the @pipes-stm@ library.

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
    ) where

import Control.Proxy.STM

{- $intro
    The @pipes-stm@ library provides a simple interface for communicating
    between concurrent pipelines.  Use this library if you want to:

    * merge multiple streams into a single stream,

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
>     lift $ threadDelay 1000000
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

>>> main
Worker #2: Processed 3
Worker #1: Processed 2
Worker #3: Processed 1
Worker #3: Processed 6
Worker #1: Processed 5
Worker #2: Processed 4
Worker #2: Processed 9
Worker #1: Processed 8
Worker #3: Processed 7
Worker #2: Processed 10
>>>

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

>>> main
Test<Enter>
Worker #1: Processed "Test"
Apple<Enter>
Worker #2: Processed "Apple"
42<Enter>
Worker #3: Processed "42"
A<Enter>
B<Enter>
C<Enter>
Worker #1: Processed "A"
Worker #2: Processed "B"
Worker #3: Processed "C"
quit<Enter>
>>>
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

>>> main
How<Enter>
Worker #1: Processed "How"
many<Enter>
roads<Enter>
Worker #2: Processed "many"
Worker #3: Processed "roads"
must<Enter>
a<Enter>
man<Enter>
Worker #1: Processed "must"
Worker #2: Processed "a"
Worker #3: Processed "man"
walk<Enter>
>>>

-}

{- $send
-}

{- Works with any number of readers and writers and won't throw exceptions -}

{- getting data out of callbacks -}
