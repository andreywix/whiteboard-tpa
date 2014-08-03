module Editor where

import Dict
import Touch
import Window
import Debug
import Navigation (..)
import Canvas (..)
import Eraser (stepEraser)
import History (..)
import Api (..)
import JavaScript.Experimental as JS
import Json
import WebSocket


import Graphics.Input (..)
import Graphics.Input as Input




-- MODEL

data Action = Undo
            | ZoomIn
            | ZoomOut
            | NoOp
            | Touches [Touch.Touch]
            | View
            | Draw
            | Erase
            | FinishDrawing


data Mode = Drawing
          | Erasing
          | Viewing

type Input =
  { action     : Action
  , brush      : Brush
  , canvasDims : (Int, Int)
  , windowDims : (Int, Int)
  }

type Whiteboard =  Zoomable (Undoable Editor)

type Editor = { mode : Mode, canvas : Canvas }

type Realtime a = {a | lastMessage : ServerAction }

type OtherDrawings = Dict.Dict Int Drawing

defaultCanvas : Canvas
defaultCanvas =
  { drawing = Dict.empty
  , dimensions = (0, 0)
  }


defaultEditor : Realtime Whiteboard
defaultEditor =
  { canvas = defaultCanvas
  , mode = Viewing
  , history = Dict.empty
  , zoom = 1
  , minZoom = 1
  , maxZoom = 2 ^ 4
  , zoomOffset = (0, 0)
  , absPos = (0, 0)
  , windowDims = (0, 0)
  , lastPosition = Nothing
  , lastMessage = NoOpServer
  }


defaultOther : OtherDrawings
defaultOther = Dict.empty

-- INPUT

port brushPort : Signal { size : Float, color : { red : Int, green : Int, blue : Int, alpha : Float }  }
port actionPort : Signal String
port userInfoPort : Signal (Maybe { drawingId : Int, firstName : String, lastName : String})
port canvasSizePort : Signal { width : Int, height : Int }
port boardInfoPort : Signal {instance : String, componentId : String, boardId : Int}
port submittedDrawingsPort : Signal [{drawingId:Int, firstName:String, lastName:String, strokes:Maybe [{t0:Float,  points:[{ x:Int, y:Int }], brush:{ size:Float, color:{ red:Int, green:Int, blue:Int, alpha:Float }}}]}]

canvasSizePortToTuple : { width : Int, height : Int } -> (Int, Int)
canvasSizePortToTuple {width, height} = (width, height)


submittedDrawings : [DrawingInfo] -> Form
submittedDrawings ds =
  let
    getStrokes ds = case ds.strokes of
      Just ss -> ss
      Nothing -> []
    strokes = foldl (\d ss -> (getStrokes d) ++ ss) [] ds
  in renderStrokes <| sortBy .t0 strokes

portToAction : String -> Action
portToAction s =
  case s of
    "Draw"    -> Draw
    "View"    -> View
    "Erase"   -> Erase
    "Undo"    -> Undo
    "ZoomIn"  -> ZoomIn
    "ZoomOut" -> ZoomOut
    "NoOp"    -> NoOp
    "FinishDrawing" -> FinishDrawing


withinWindowDims : [Touch.Touch] -> (Int, Int) -> [Touch.Touch]
withinWindowDims ts (w, h) =
  let within t = t.x > 0 && t.x < w && t.y > 0 && t.y < h
  in filter within ts


serverToAction : String -> (ServerAction, DrawingInfo)
serverToAction r =
  case Json.fromString r of
    Just v  -> let
                 res = (JS.toRecord . JS.fromJson) v
               in case res.action of
                  "AddPoints"    -> (AddPoints res.element, res.drawing)
                  "AddStrokes"   -> (AddStrokes res.element, res.drawing)
                  "RemoveStroke" -> (RemoveStroke res.element, res.drawing)
                  _              -> (NoOpServer, res.drawing)
    Nothing -> (NoOpServer, {firstName = "", lastName = "", drawingId = 0, strokes = Nothing}) -- throw error instead


isNoOpServer : ServerAction -> Bool
isNoOpServer m = case m of
  NoOpServer -> True
  _          -> False


brodcast : Signal ServerAction
brodcast =  dropRepeats . dropIf isNoOpServer NewClient  <| .lastMessage  <~ editorState


userInfoPortToDrawingInfo : Maybe { drawingId : Int, firstName : String, lastName : String} -> Maybe DrawingInfo
userInfoPortToDrawingInfo user =
  case user of
    Just u -> Just {u | strokes = Nothing}
    Nothing -> Nothing

outgoing : Signal String
outgoing = dropRepeats (constructMessage <~ brodcast ~ (userInfoPortToDrawingInfo <~ userInfoPort) ~ boardInfoPort)


incoming : Signal String
incoming = WebSocket.connect "ws://localhost:9160" outgoing


serverMessage = dropRepeats (serverToAction <~ incoming)


--toolActions : Input Action
--toolActions = Input.input NoOp

actions : Signal Action
actions = merges [ Touches <~ (withinWindowDims <~ Touch.touches ~ Window.dimensions)
                 , portToAction <~ actionPort
                 --, toolActions.signal
                 ]


input : Signal Input
input = Input <~ actions
               ~ brushPort
               ~ (canvasSizePortToTuple <~ canvasSizePort)
               ~ Window.dimensions
-- OUTPUT


getDrawing : Realtime Whiteboard -> Maybe ({ absPos : (Float, Float), zoomOffset : (Float, Float), zoom : Float, dimensions : (Int, Int), windowDims : (Int, Int)
                                  , drawing : [{t0:Float, points:[{ x:Int, y:Int }], brush:{ size:Float, color:{ red:Int, green:Int, blue:Int, alpha:Float }}}]})
getDrawing {mode, canvas, absPos, zoomOffset, zoom, windowDims} =
  case mode of
    Viewing -> Just {drawing = Dict.values canvas.drawing, absPos = absPos, zoomOffset = zoomOffset, zoom = zoom, dimensions = canvas.dimensions, windowDims = windowDims}
    _ -> Nothing

port canvasOut : Signal (Maybe { absPos : (Float, Float), zoomOffset : (Float, Float), zoom : Float, dimensions : (Int, Int), windowDims : (Int, Int)
                        , drawing : [{t0:Float,  points:[{ x:Int, y:Int }], brush:{ size:Float, color:{ red:Int, green:Int, blue:Int, alpha:Float }}}]})
port canvasOut = getDrawing <~ editorState


-- UPDATE

getZoomable : Whiteboard -> Zoomable Editor
getZoomable w = { canvas = w.canvas
                , mode = w.mode
                , windowDims = w.windowDims
                , zoom = w.zoom
                , minZoom = w.minZoom
                , maxZoom = w.maxZoom
                , absPos = w.absPos
                , zoomOffset = w.zoomOffset
                , lastPosition = w.lastPosition }


stepMode : Action -> Mode -> Mode
stepMode action mode =
  case action of
    View  -> Viewing
    Draw  -> Drawing
    Erase -> Erasing
    _     -> mode



eraserBrush : Brush
eraserBrush = { size = 15, color = toRgb (rgba 0 0 0 0.1) }



stepEditor : Input -> Realtime Whiteboard -> Realtime Whiteboard
stepEditor {action, brush, canvasDims, windowDims}
           ({mode, canvas, history, zoom, absPos, zoomOffset} as editor) =
  let
    float (a, b) = (toFloat a, toFloat b)
    editor' = { editor | windowDims <- windowDims
                       , minZoom <- max 1 <| minScale (float windowDims) (float canvas.dimensions)
                       , canvas <- { canvas | dimensions <- canvasDims }
                       , lastMessage <- NoOpServer }
  in case action of
    Undo ->
      let (drawing', history', message) = stepUndo canvas.drawing history
      in { editor' | canvas <- { canvas | drawing <- drawing' }, history <- history', lastMessage <- message}

    ZoomIn ->
      let zoomed = stepZoom 2 <| getZoomable { editor' - lastMessage }
      in { editor' | zoom <- zoomed.zoom, zoomOffset <- zoomed.zoomOffset }

    ZoomOut ->
      let zoomed = stepZoom (1/2) <| getZoomable { editor' - lastMessage }
      in { editor' | zoom <- zoomed.zoom, zoomOffset <- zoomed.zoomOffset }

    View ->
      { editor' | mode <- Viewing }

    Draw ->
      { editor' | mode <- Drawing }

    Erase ->
      { editor' | mode <- Erasing }

    Touches ts ->
      let ps = map (touchToPoint . (scaleTouch absPos zoomOffset zoom)) ts
      in case mode of
        Drawing ->
          { editor' | canvas <- { canvas | drawing <- addN (applyBrush ps brush) canvas.drawing }
                    , history <- recordDrew ps history
                    , lastMessage <- AddPoints { brush = brush, points = ps } }

        Erasing ->
          let (drawing', history', message) = stepEraser (applyBrush ps eraserBrush) canvas.drawing history
          in { editor' | canvas <- { canvas | drawing <- drawing'} , history <- history', lastMessage <- message}

        Viewing ->
          let moved = withinBounds canvas.dimensions <| stepMove ts <| getZoomable { editor' - lastMessage }
          in { editor' | absPos <- moved.absPos, lastPosition <- moved.lastPosition }

    NoOp    -> editor'


editorState : Signal (Realtime Whiteboard)
editorState = foldp stepEditor defaultEditor input


stepOthers : (ServerAction, DrawingInfo) -> OtherDrawings -> OtherDrawings
stepOthers (a, d) c =
  let
    drawing = Dict.getOrElse Dict.empty d.drawingId c
    drawing' = case a of
      AddPoints ps   -> addN (applyBrush ps.points ps.brush) drawing
      AddStrokes ss  -> foldl (\s -> Dict.insert s.id { s - id }) drawing ss.strokes
      RemoveStroke s -> Dict.remove s.strokeId drawing
      _              -> drawing
  in Dict.insert d.drawingId drawing' c

othersState : Signal OtherDrawings
othersState = foldp stepOthers defaultOther serverMessage


-- VIEW



display : (Int, Int) -> Realtime Whiteboard -> OtherDrawings -> Form -> Element
display (w, h) ({canvas, history, zoom, absPos} as board) o submitted =
  let
    float (a, b) = (toFloat a, toFloat b)
    thisStrokes = renderStrokes <| Dict.values canvas.drawing
    --withOtherStrokes = sortBy .t0 <| foldl (\d ss -> (Dict.values d) ++ ss) strokes (Dict.values o)
    displayCanvas = group <| submitted :: thisStrokes :: (map (\d -> renderStrokes (Dict.values d)) (Dict.values o))
    toZero zoom (w, h) = (-w * zoom / 2, h * zoom / 2)
    toAbsPos (dx, dy) (x, y) = (x - dx * zoom, y + dy * zoom )
    pos = toAbsPos absPos <| toZero zoom (float (w, h))
  in collage w h [ scale zoom <| move pos displayCanvas ]



main = display <~ Window.dimensions
                ~ editorState
                ~ othersState
                ~ (submittedDrawings <~ dropRepeats submittedDrawingsPort)