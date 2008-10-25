{-# LANGUAGE 
BangPatterns,
GeneralizedNewtypeDeriving #-}

module Main where

import System.IO
import System.Exit
import System.Random
import System.Environment
import Network

import Control.Monad
import Control.Monad.STM
import Control.Monad.State
import Control.Monad.Trans
import Control.Monad.Error
import Control.Applicative
import Control.Arrow hiding (loop)

import Control.Concurrent
import Control.Concurrent.STM.TChan

import Data.List
import Data.Char
import Data.Maybe

import Base
import Ship


readerThread :: ClientId -> Handle -> MasterChannel -> IO ()
readerThread c h chan = forever $ do
                          catch (hGetLine h >>= \s ->
                                     atomically $ writeTChan chan (Message (c,s)))
                                (const $ hClose h >> putDisconnect c chan)


writerThread :: ClientId -> Handle -> TChan String -> MasterChannel -> IO ()
writerThread c h chan mchan 
    = forever $ do
        s <- atomically $ readTChan chan
        catch (hPutStrLn h s >> hFlush h)
              (const $ hClose h >> putDisconnect c mchan)


putDisconnect :: ClientId -> MasterChannel -> IO ()
putDisconnect c chan = do
  putStrLn $ "Disconnecting client " ++ show c
  atomically $ writeTChan chan (Disconnect c)



-----------------------------------------
-------------   commands    -------------
-----------------------------------------

commands :: Poss Command
commands = [(cmd_turn     , ["turn","come"])
           ,(cmd_rudder   , ["rudder"])
           ]


parser :: (ClientId,String) -> P ()
parser (c,[]) = return ()  -- do nothing on empty string
parser (c,s)  = case words (map toLower s) of
                  []     -> return () -- do nothing again
                  (w:ws) -> do
                    x <- runParse (tryParse w commands >>= \f -> f c (w:ws))
                    case x of
                      Left e  -> to c $ "Error: " ++ e
                      Right _ -> return ()


parseArg :: a -> Poss a -> [String] -> a
parseArg d p xs = maybe d id $ collapseMaybes $ map (flip maybeParse p) xs


dirs  = [(   -1, ["left","port","aport"])
        ,(    1, ["right","starboard","stbd","astarboard","astbd"])]

rates = [(    1, ["soft","gentle","softly","gently","slow","slowly","light","slight"])
        ,(    3, ["hard","fast","quick","quickly"])]
          

cmd_turn :: Command
cmd_turn c (cmd:as) = do
  liftP $ turn c dir rate hdg absol
  s <- ship <$> liftP (findClient c)
  liftP $ to c $ turnReport s
    where absls = [(True , ["to"]), (False, ["by"])]
          dir   = parseArg 0 dirs  as
          rate  = parseArg 2 rates as
          hdg   = maybe 0 id $ collapseMaybes $ (map maybeRead as :: [Maybe Int])
          absol = parseArg (cmd=="turn") absls as

turn :: ClientId -> Int -> Rudder -> Int -> Bool -> P ()
turn c d r h a = withShip c $ \s -> s { rudder  = d*r
                                      , orCourse = if a 
                                                   then Just $ fi h 
                                                   else Just $ course s + (fi $ h * d )
                                      }


cmd_rudder :: Command
cmd_rudder c (cmd:as) = do
  liftP $ withShip c $ \s -> s { rudder = r, orCourse = Nothing }
  liftP $ to c $ "Rudder " ++ rudderReport r ++", aye Cap'n"
    where dir  = parseArg 0 dirs  as
          rate = parseArg 2 rates as
          r    = dir*rate



------------------------------------------------
-------------- server functions ----------------
------------------------------------------------


runP :: PState -> P a -> IO (a, PState)
runP st (P a) = runStateT a st


tick :: Int -> P ()
tick x = do
    -- advance all ships by the right amount of movement
    cs <- gets clients
    (ws,wh) <- gets wind
    cs' <- mapM (\c -> tickShip ws wh (cid c) (ship c) >>= \s -> return c { ship = s }) cs
    tickWind
          

tickWind :: P ()
tickWind = return ()   -- TODO: to be defined
  


loop :: MasterChannel -> P ()
loop chan = forever $ do
              e <- io $ atomically $ readTChan chan
              case e of
                Message cs -> parser cs
                NewClient c -> do
                        st <- get
                        let cs = clients st
                        put $ st { clients = c:cs }
                Disconnect c -> do
                        st <- get
                        let cs = clients st
                        case break ((==c).cid) cs of
                          (_,[]) -> return () -- do nothing, client already gone
                          (pre,d:post) -> do
                                  io $ killThread $ writer d
                                  tid <- io $ myThreadId
                                  if reader d == tid
                                    then return () -- do nothing.
                                    else io $ killThread $ reader d
                                  put st { clients = pre ++ post }
                                  toAll $ "System: Client Disconnected: " ++ show (cid d)
                NewReader c t -> updateClient c $ \c -> c { reader = t }
                Tick x -> tick x


main = do
  args <- getArgs
  case args of
    (port:_) -> do
              chan <- atomically newTChan
              tid  <- forkIO $ runP (PState [] chan (0,0)) (loop chan) >> return ()
              sock <- listenOn (PortNumber (fromIntegral ((read port)::Int)))
              tickt<- forkIO $ tickerThread 0 chan
              serverLoop chan sock tid 0
    [] -> putStrLn "Usage: pirateserver <port>"


tickerThread :: Int -> MasterChannel -> IO ()
tickerThread !x chan = do
  atomically $ writeTChan chan (Tick x)
  threadDelay 1000000
  tickerThread (x+1) chan


serverLoop :: MasterChannel -> Socket -> ThreadId -> ClientId -> IO ()
serverLoop chan s tid c = do
  (h,_,_) <- accept s
  nc <- atomically newTChan
  putStrLn $ "New client! Assigning cid "++ show c
  wid <- forkIO $ writerThread c h nc chan
  atomically $ writeTChan chan $ NewClient (Client {
                                              cid    = c
                                            , socket = h
                                            , chan   = nc
                                            , reader = tid
                                            , writer = wid
                                            , ship   = tpFrigate
                                            })
  rid <- forkIO $ readerThread c h chan
  atomically $ writeTChan chan (NewReader c rid)
  serverLoop chan s tid $! c+1



