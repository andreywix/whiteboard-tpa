{-# LANGUAGE OverloadedStrings #-}

module Api (ServerError (..), apiApp) where

import User
import WixInstance
import qualified Drawing
import qualified Board
import qualified PdfGenerator
import Realtime (numClientsBoard, ServerState)
import Control.Concurrent (MVar, newMVar, modifyMVar_, readMVar, forkIO)


import DrawingProgress
import DbConnect (dbConnectInfo)
import ServerError

import Control.Applicative
import Control.Monad
import Control.Monad.Error
import Control.Monad.IO.Class (liftIO)

import Data.List
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Text.Lazy.Encoding as TL
import qualified Data.ByteString.Lazy.Char8 as BLC8
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Data.Acid as Acid
import Web.Scotty.Trans
import Data.Aeson (ToJSON, toJSON, object, (.=), encode)
import Database.PostgreSQL.Simple
import Network.Wai.Middleware.Static
import Network.Wai.Middleware.RequestLogger
import Network.Wai.Middleware.Gzip

import qualified Network.HTTP.Types as HttpType





data WidgetJson = WidgetJson Board.Board [Drawing.DrawingInfo] deriving Show

data SettingsPanelJson = SettingsPanelJson Board.Board Bool deriving Show


instance ToJSON WidgetJson where
    toJSON (WidgetJson ss submitted) =
        object [ "settings" .= ss
               , "submitted" .= submitted ]

instance ToJSON SettingsPanelJson where
    toJSON (SettingsPanelJson ss empty) =
        object [ "settings" .= ss
               , "empty" .= empty ]



getWixWidget :: Monad m => ActionT ServerError m (Maybe Board.WixWidget)
getWixWidget = do
    componentId <- param "compId"
    wixInstance <- header "X-Wix-Instance"
    let wixInstance' = fmap TL.encodeUtf8 wixInstance
    let widget = wixInstance' >>= parseInstance (BLC8.pack "e5e44072-34f2-43cc-ba7d-82962348d57f")
    return $ fmap (Board.WixWidget componentId) widget


maxPaintersPerBoard = 20

apiApp :: (Monad m, MonadIO m) => Acid.AcidState BoardsState -> MVar ServerState -> ScottyT ServerError m ()
apiApp acid clientState = do

    middleware $ gzip $ def { gzipFiles = GzipCompress }
    middleware $ staticPolicy (noDots >-> addBase "public-dev")
    middleware logStdoutDev

    defaultHandler handleEx

    get "/" $ do
        widget <- getWixWidget
        case widget of
            Just w -> text $ TL.pack $ show w
            Nothing -> raise $ ServerError "invalid wix instance" HttpType.badRequest400


    post "/api/board/:bid/new_drawing" $ do
        bid <- param "bid"
        userInfo <- jsonData
        case userInfo of
          Just usr@(User{}) -> do
              cdb <- liftIO $ connect dbConnectInfo
              d   <- liftIO $ Drawing.create cdb usr bid
              case d of
                  Just drawing -> do
                    numPs <- liftIO $ Acid.query acid (GetNPaintersBoard bid)
                    liftIO $ print numPs
                    if numPs > maxPaintersPerBoard
                        then do { status tooManyPainters; json $ Drawing.toDrawingInfo drawing }
                        else json $ Drawing.toDrawingInfo drawing
                  Nothing -> raise $ ServerError "cannot create drawing" HttpType.internalServerError500
          _ -> raise $ ServerError "invalid message format" HttpType.badRequest400


    post "/api/board/:bid/resume_drawing" $ do
        bid <- param "bid"
        drawingInfo <- jsonData
        case drawingInfo of
          Just info@(Drawing.DrawingInfo{}) -> do
              cdb <- liftIO $ connect dbConnectInfo
              d   <- liftIO $ Drawing.get cdb info bid
              case d of
                  Just drawing -> do
                    numPs <- liftIO $ Acid.query acid (GetNPaintersBoard bid)
                    liftIO $ print numPs
                    if numPs > maxPaintersPerBoard
                        then do { status tooManyPainters; json tooManyPainters }
                        else do
                            let strokes = fromMaybe [] (Drawing.strokes drawing)
                            liftIO $ Acid.update acid $ AddNewStrokes bid info strokes
                            json HttpType.ok200
                  Nothing -> raise $ ServerError "invalid drawing info" HttpType.internalServerError500
          _ -> raise $ ServerError "invalid message format" HttpType.badRequest400



    put "/api/board/:bid/submit_drawing" $ do
            bid <- param "bid"
            ss  <- jsonData
            cdb <- liftIO $ connect dbConnectInfo
            d   <- liftIO $ Drawing.submit cdb ss bid
            case d of
                Just drawing  -> do
                    liftIO $ Acid.update acid $ RemoveDrawing (Drawing.boardId drawing) (Drawing.toDrawingInfo drawing)
                    json HttpType.ok200
                Nothing -> raise $ ServerError "cannot find drawing" HttpType.badRequest400

    get "/api/board/:compId/drawings" $ do
        bid <- param "boardId"
        widget <- getWixWidget
        cdb   <- liftIO $ connect dbConnectInfo

        case widget of
            Just w -> do
                drawings <- liftIO $ Drawing.getSubmittedByBoard cdb bid
                json $ map Drawing.toDrawingInfo drawings
            Nothing -> raise $ ServerError "invalid instance" HttpType.badRequest400


    put "/api/board/:compId/drawings/deleteByIds" $ do
        bid <- param "boardId"
        widget <- getWixWidget
        drawingIds  <- jsonData
        cdb   <- liftIO $ connect dbConnectInfo

        case widget of
            Just w -> do
                drawings <- liftIO $ Drawing.removeStrokesByIds cdb drawingIds bid
                if length drawingIds == length drawings
                    then json HttpType.ok200
                    else json (ServerError "cannot delete drwaings' strokes" HttpType.badRequest400)
            Nothing -> raise $ ServerError "invalid instance" HttpType.badRequest400


    get "/api/board/:compId" $ do
        widget <- getWixWidget
        cdb   <- liftIO $ connect dbConnectInfo
        board <- liftIO $ case widget of
            Just w -> Board.getOrCreate cdb Board.defaultSettings w
            Nothing -> return Nothing

        case board of
            Just b -> do
                drawings <- liftIO $ Drawing.getSubmittedByBoard cdb (Board.boardId b)
                online   <- liftIO $ Acid.query acid (GetDrawings (Board.boardId b))
                json $ WidgetJson b $ unionBy (\(Drawing.DrawingInfo x _ _ _) (Drawing.DrawingInfo y _ _ _) -> x == y) online (fmap Drawing.toDrawingInfo drawings)
            Nothing -> raise $ ServerError "cannot get board" HttpType.internalServerError500


    get "/api/board/:compId/settings" $ do
        widget <- getWixWidget
        cdb   <- liftIO $ connect dbConnectInfo
        board <- liftIO $ case widget of
            Just w -> Board.get cdb w
            Nothing -> return Nothing
        case board of
            Just b -> do
                num <- liftIO $ Drawing.countAllByBoard cdb (Board.boardId b)
                json $ SettingsPanelJson b (num == 0)
            Nothing -> raise $ ServerError "cannot get board" HttpType.internalServerError500


    put "/api/board/:compId/settings" $ do
        widget <- getWixWidget
        bs  <- jsonData
        cdb   <- liftIO $ connect dbConnectInfo
        board <- liftIO $ case widget of
            Just w -> Board.update cdb bs w
            Nothing -> return Nothing
        case board of
            Just _  -> json HttpType.ok200
            Nothing -> raise $ ServerError "cannot update drawing" HttpType.internalServerError500



    get "/api/board/:bid/download" $ do
        bid   <- param "bid"
        cdb   <- liftIO $ connect dbConnectInfo
        board <- liftIO $ Board.getById cdb (read bid :: Int)
        case board of
            Just b -> do
                drawings <- liftIO $ Drawing.getSubmittedByBoard cdb (Board.boardId b)
                boardPdf <- liftIO $ PdfGenerator.getPdf (Board.settings b) drawings
                setHeader "Content-Type" "application/pdf"
                setHeader "Content-Disposition" "attachment; filename=\"Whiteboard.pdf\""
                setHeader "Set-Cookie" "fileDownload=true; path=/"
                raw boardPdf
            Nothing -> raise $ ServerError "cannot download board" HttpType.internalServerError500


    notFound $ raise $ ServerError "resource not found" HttpType.notFound404
