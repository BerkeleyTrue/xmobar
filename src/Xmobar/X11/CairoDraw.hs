------------------------------------------------------------------------------
-- |
-- Module: Xmobar.X11.CairoDraw
-- Copyright: (c) 2022 Jose Antonio Ortega Ruiz
-- License: BSD3-style (see LICENSE)
--
-- Maintainer: jao@gnu.org
-- Stability: unstable
-- Portability: unportable
-- Created: Fri Sep 09, 2022 02:03
--
-- Drawing the xmobar contents using Cairo and Pango
--
--
------------------------------------------------------------------------------

module Xmobar.X11.CairoDraw (drawInPixmap) where

import Prelude hiding (lookup)
import Data.Map (lookup)

import Control.Monad.IO.Class
import Control.Monad.Reader

import Graphics.X11.Xlib hiding (Segment)
import Graphics.Rendering.Cairo.Types
import qualified Graphics.Rendering.Cairo as C
import qualified Graphics.Rendering.Pango as P

import qualified Data.Colour.SRGB as SRGB
import qualified Data.Colour.Names as CNames

import Xmobar.Run.Parsers ( Segment, Widget(..), TextRenderInfo (..)
                          , colorComponents)
import Xmobar.Config.Types
import Xmobar.Text.Pango (fixXft)
import Xmobar.X11.Types
import qualified Xmobar.X11.Bitmap as B
import Xmobar.X11.XRender (drawBackground)
import Xmobar.X11.CairoSurface

type Renderinfo = (Segment, Surface -> Double -> Double -> IO (), Double)
type BitmapDrawer = Double -> Double -> String -> IO ()
type Actions = [ActionPos]

data DrawContext = DC { dcBitmapDrawer :: BitmapDrawer
                      , dcBitmapLookup :: String -> Maybe B.Bitmap
                      , dcConfig :: Config
                      , dcWidth :: Double
                      , dcHeight :: Double
                      , dcSegments :: [[Segment]]
                      }

readColourName :: String -> (SRGB.Colour Double, Double)
readColourName str =
  case CNames.readColourName str of
    Just c -> (c, 1.0)
    Nothing -> case SRGB.sRGB24reads str of
                 [(c, "")] -> (c, 1.0)
                 [(c,d)] -> (c, read ("0x" ++ d))
                 _ ->  (CNames.white, 1.0)

renderBackground :: Display -> Pixmap -> Config -> Dimension -> Dimension -> IO ()
renderBackground d p conf w h = do
  let c = bgColor conf
      (_, a) = readColourName c
      a' = min (round $ 255 * a) (alpha conf)
  drawBackground d p c a' (Rectangle 0 0 w h)

drawInPixmap :: GC -> Pixmap -> [[Segment]] -> X Actions
drawInPixmap gc p s = do
  xconf <- ask
  let disp = display xconf
      vis = defaultVisualOfScreen (defaultScreenOfDisplay disp)
      (Rectangle _ _ w h) = rect xconf
      dw = fromIntegral w
      dh = fromIntegral h
      conf = (config xconf)
      dc = DC (drawXBitmap xconf gc p) (lookupXBitmap xconf) conf dw dh s
      render = renderSegments dc
  liftIO $ renderBackground disp p conf w h
  liftIO $ withXlibSurface disp p vis (fromIntegral w) (fromIntegral h) render

lookupXBitmap :: XConf -> String -> Maybe B.Bitmap
lookupXBitmap xconf path = lookup path (iconCache xconf)

drawXBitmap :: XConf -> GC -> Pixmap -> BitmapDrawer
drawXBitmap xconf gc p h v path = do
  let disp = display xconf
      conf = config xconf
      fc = fgColor conf
      bc = bgColor conf
      bm = lookupXBitmap xconf path
  liftIO $ maybe (return ()) (B.drawBitmap disp p gc fc bc (round h) (round v)) bm

segmentMarkup :: Config -> Segment -> String
segmentMarkup conf (Text txt, info, idx, _actions) =
  let fnt = fixXft $ indexedFont conf idx
      (fg, bg) = colorComponents conf (tColorsString info)
      attrs = [P.FontDescr fnt, P.FontForeground fg]
      attrs' = if bg == bgColor conf then attrs else P.FontBackground bg:attrs
  in P.markSpan attrs' $ P.escapeMarkup txt
segmentMarkup _ _ = ""

withRenderinfo :: P.PangoContext -> DrawContext -> Segment -> IO Renderinfo
withRenderinfo ctx dctx seg@(Text _, inf, idx, a) = do
  let conf = dcConfig dctx
  lyt <- P.layoutEmpty ctx
  mk <- P.layoutSetMarkup lyt (segmentMarkup conf seg) :: IO String
  (_, P.PangoRectangle o u w h) <- P.layoutGetExtents lyt
  let voff' = fromIntegral $ indexedOffset conf idx
      voff = voff' + (dcHeight dctx - h + u) / 2.0
      wd = w - o
      slyt s off mx = do
        when (off + w > mx) $ do
          P.layoutSetEllipsize lyt P.EllipsizeEnd
          P.layoutSetWidth lyt (Just $ mx - off)
        C.renderWith s $ C.moveTo off voff >> P.showLayout lyt
  return ((Text mk, inf, idx, a), slyt, wd)

withRenderinfo _ _ seg@(Hspace w, _, _, _) = do
  return (seg, \_ _ _ -> return (), fromIntegral w)

withRenderinfo _ dctx seg@(Icon p, _, _, _) = do
  let bm = dcBitmapLookup dctx p
      wd = maybe 0 (fromIntegral . B.width) bm
      ioff = iconOffset (dcConfig dctx)
      vpos = dcHeight dctx / 2  + fromIntegral ioff
      draw _ off mx = when (off + wd <= mx) $ dcBitmapDrawer dctx off vpos p
  return (seg, draw, wd)

renderSegmentBackground ::
  DrawContext -> Surface -> TextRenderInfo -> Double -> Double -> IO ()
renderSegmentBackground dctx surf info xbeg xend =
  when (bg /= bgColor conf && (top >= 0 || bot >= 0)) $
    C.renderWith surf $ do
      setSourceColor (readColourName bg)
      C.rectangle xbeg top (xend - xbeg) (dcHeight dctx - bot - top)
      C.fillPreserve
  where conf = dcConfig dctx
        (_, bg) = colorComponents conf (tColorsString info)
        top = fromIntegral $ tBgTopOffset info
        bot = fromIntegral $ tBgBottomOffset info

renderSegment :: DrawContext -> Surface -> Double
              -> (Double, Actions) -> Renderinfo -> IO (Double, Actions)
renderSegment dctx surface maxoff (off, acts) (segment, render, lwidth) = do
  let end = min maxoff (off + lwidth)
      (_, info, _, a) = segment
      acts' = case a of Just as -> (as, round off, round end):acts; _ -> acts
  renderSegmentBackground dctx surface info off end
  render surface off maxoff
  return (off + lwidth, acts')

setSourceColor :: (SRGB.Colour Double, Double) -> C.Render ()
setSourceColor (colour, alph) =
  C.setSourceRGBA r g b alph
  where rgb = SRGB.toSRGB colour
        r = SRGB.channelRed rgb
        g = SRGB.channelGreen rgb
        b = SRGB.channelBlue rgb

drawRect :: String -> Double -> (Double, Double, Double, Double) -> C.Render()
drawRect name wd (x0, y0, x1, y1) = do
  setSourceColor (readColourName name)
  C.setLineWidth wd
  C.rectangle x0 y0 x1 y1
  C.strokePreserve

outerBorder :: Config -> Double -> Double -> C.Render ()
outerBorder conf w h =  do
  let r = case border conf of
            TopB -> (0, 0, w - 1, 0)
            BottomB -> (0, h - 1, w - 1, h - 1)
            FullB -> (0, 0, w - 1, h - 1)
            TopBM m -> (0, fi m, w - 1, fi m)
            BottomBM m -> (0, h - fi m, w - 1, h - fi m)
            FullBM m -> (fi m, fi m, w - fi m - 1, h - fi m - 1)
            NoBorder -> (-1, -1, -1, -1)
  drawRect (borderColor conf) (fi (borderWidth conf)) r
  where fi = fromIntegral

renderBorder :: Config -> Double -> Double -> Surface -> IO ()
renderBorder conf w h surf =
  case border conf of
    NoBorder -> return ()
    _ -> C.renderWith surf (outerBorder conf w h)

layoutsWidth :: [Renderinfo] -> Double
layoutsWidth = foldl (\a (_,_,w) -> a + w) 0

renderSegments :: DrawContext -> Surface -> IO Actions
renderSegments dctx surface = do
  let [left, center, right] = take 3 $ dcSegments dctx
      dh = dcHeight dctx
      dw = dcWidth dctx
      conf = dcConfig dctx
  ctx <- P.cairoCreateContext Nothing
  llyts <- mapM (withRenderinfo ctx dctx) left
  rlyts <- mapM (withRenderinfo ctx dctx) right
  clyts <- mapM (withRenderinfo ctx dctx) center
  (lend, as) <- foldM (renderSegment dctx surface dw) (0, []) llyts
  let rw = layoutsWidth rlyts
      rstart = max (lend + 1) (dw - rw - 1)
      cmax = rstart - 1
      cw = layoutsWidth clyts
      cstart = lend + 1 + max 0 (dw - rw - lend - cw) / 2.0
  (_, as') <- foldM (renderSegment dctx surface cmax) (cstart, as) clyts
  (_, as'') <- foldM (renderSegment dctx surface dw) (rstart, as') rlyts
  when (borderWidth conf > 0) (renderBorder conf dw dh surface)
  return as''