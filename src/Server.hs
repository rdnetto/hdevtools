module Server where

import Control.Exception (bracket, finally, handleJust, tryJust)
import Control.Monad (guard)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import GHC.IO.Exception (IOErrorType(ResourceVanished))
import Network (PortID(UnixSocket), Socket, accept, listenOn, sClose)
import System.Directory (removeFile)
import System.Exit (ExitCode(ExitSuccess))
import System.IO (Handle, hClose, hFlush, hGetLine, hPutStrLn)
import System.IO.Error (ioeGetErrorType, isAlreadyInUseError, isDoesNotExistError)

import CommandLoop (newCommandLoopState, Config, updateConfig, startCommandLoop)
import Types (ClientDirective(..), Command, CommandExtra(..), ServerDirective(..))
import Util (readMaybe)

createListenSocket :: FilePath -> IO Socket
createListenSocket socketPath = do
    r <- tryJust (guard . isAlreadyInUseError) $ listenOn (UnixSocket socketPath)
    case r of
        Right socket -> return socket
        Left _ -> do
            removeFile socketPath
            listenOn (UnixSocket socketPath)

startServer :: FilePath -> Maybe Socket -> CommandExtra -> IO ()
startServer socketPath mbSock cmdExtra = do
    case mbSock of
        Nothing -> bracket (createListenSocket socketPath) cleanup go
        Just sock -> (go sock) `finally` (cleanup sock)
    where
    cleanup :: Socket -> IO ()
    cleanup sock = do
        sClose sock
        removeSocketFile

    go :: Socket -> IO ()
    go sock = do
        state <- newCommandLoopState
        currentClient <- newIORef Nothing
        configRef <- newIORef Nothing
        config <- updateConfig Nothing cmdExtra
        startCommandLoop state (clientSend currentClient) (getNextCommand currentClient sock configRef) config Nothing

    removeSocketFile :: IO ()
    removeSocketFile = do
        -- Ignore possible error if socket file does not exist
        _ <- tryJust (guard . isDoesNotExistError) $ removeFile socketPath
        return ()

clientSend :: IORef (Maybe Handle) -> ClientDirective -> IO ()
clientSend currentClient clientDirective = do
    mbH <- readIORef currentClient
    case mbH of
        Just h -> ignoreEPipe $ do
            hPutStrLn h (show clientDirective)
            hFlush h
        Nothing -> return ()
    where
    -- EPIPE means that the client is no longer there.
    ignoreEPipe = handleJust (guard . isEPipe) (const $ return ())
    isEPipe = (==ResourceVanished) . ioeGetErrorType

getNextCommand :: IORef (Maybe Handle) -> Socket -> IORef (Maybe Config) -> IO (Maybe (Command, Config))
getNextCommand currentClient sock config = do
    checkCurrent <- readIORef currentClient
    case checkCurrent of
        Just h -> hClose h
        Nothing -> return ()
    (h, _, _) <- accept sock
    writeIORef currentClient (Just h)
    msg <- hGetLine h -- TODO catch exception
    let serverDirective = readMaybe msg
    case serverDirective of
        Nothing -> do
            clientSend currentClient $ ClientUnexpectedError $
                "The client sent an invalid message to the server: " ++ show msg
            getNextCommand currentClient sock config
        Just (SrvCommand cmd cmdExtra) -> do
            curConfig <- readIORef config
            config' <- updateConfig curConfig cmdExtra
            writeIORef config (Just config')
            return $ Just (cmd, config')
        Just SrvStatus -> do
            mapM_ (clientSend currentClient) $
                [ ClientStdout "Server is running."
                , ClientExit ExitSuccess
                ]
            getNextCommand currentClient sock config
        Just SrvExit -> do
            mapM_ (clientSend currentClient) $
                [ ClientStdout "Shutting down server."
                , ClientExit ExitSuccess
                ]
            -- Must close the handle here because we are exiting the loop so it
            -- won't be closed in the code above
            hClose h
            return Nothing
