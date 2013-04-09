{-| This module provides a tutorial for the @pipes-stm@ library.

    This tutorial assumes that you have read the @pipes@ tutorial in
    @Control.Proxy.Tutorial@.
-}

module Control.Proxy.STM.Tutorial (
    -- * Introduction
    -- $intro
    ) where

import Control.Proxy.STM

{- $intro
    The @pipes-stm@ library provides a simple interface for communicating
    between concurrent pipelines.  Use this library if you want to:

    * merge multiple streams into a single stream, or

    * implement work-stealing, or

    * build a functional reactive programming (FRP) system.

    For example, let's say that we design a primitive game with a single unit
    and define a primitive event handler:

> import Control.Proxy
> import Control.Proxy.Trans.State
> 
> data Event = Harm Integer | Heal Integer
> 
> type Health = Integer
> 
> handler :: (Proxy p) => () -> Consumer (StateP Health p) Event IO r
> handler () = forever $ do
>     event <- request ()
>     case event of
>         Harm n -> modify (subtract n)
>         Heal n -> modify (+        n)
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

> main = do
>     (input, output) <- spawn Unbounded
>     ...

    We will be streaming @Event@s through our buffer, so our @input@ has type
    @(Input Event)@ and our @output@ has type @(Output Event)@.

    To stream @Event@s into the buffer, we use 'sendD', which writes values to
    the buffer's 'Input' end:

> sendD :: (Proxy p) => Input a -> x -> p x a x a IO ()

    We can concurrently forward multiple streams to the same 'Input', which
    merges their messages into the buffer on a first-come first-serve basis:

>     ...
>     forkIO $ runProxy $ acidRain >-> sendD input
>     forkIO $ runProxy $ user     >-> sendD input
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
> quit<Enter>
> $
-}
