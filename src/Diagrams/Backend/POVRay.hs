-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Backend.POVRay
-- Copyright   :  (c) 2011 Diagrams-povray team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- An experimental backend for three-dimensional diagrams.
--
-----------------------------------------------------------------------------
module Diagrams.Backend.POVRay

  ( POVRay(..)       -- backend token

  , Options(..)      -- rendering options specific to POV-Ray
  ) where

import Graphics.Rendering.Diagrams.Transform

import Diagrams.Prelude
import Diagrams.ThreeD.Shapes

data POVRay = POVRay
  deriving (Eq,Ord,Read,Show,Typeable)

instance Monoid (Render POVRay R3) where
  mempty  = P $ return ()
  (P r1) `mappend` (P r2) = P (r1 >> r2)

type PMonad a = Identity a

instance Backend POVRay R3 where
  data Render  POVRay R3 = P (PMonad ())
  type Result  POVRay R3 = String
  data Options POVRay R2 = POVRayOptions

  withStyle _ s t (C r) = C $ do
    C.save
    r
    cairoTransf t
    cairoStyle s
    C.stroke
    C.restore

  doRender _ options (C r) = (renderIO, r)
    where renderIO = do
            let surfaceF s = C.renderWith s r
                file = fileName options
            case outputFormat options of
              PNG (w,h) ->
                C.withImageSurface C.FormatARGB32 w h $ \surface -> do
                  surfaceF surface
                  C.surfaceWriteToPNG surface file
              PS  (w,h) -> C.withPSSurface  file w h surfaceF
              PDF (w,h) -> C.withPDFSurface file w h surfaceF
              SVG (w,h) -> C.withSVGSurface file w h surfaceF

  -- Set the line width to 0.01 and line color to black (in case they
  -- were not set), freeze the diagram in its final form, and then do
  -- final adjustments to make it fit the requested size.
  adjustDia _ opts d = d' # lw 0.01 # lc black # freeze
                          # scale s
                          # translate tr
    where d'      = reflectY d   -- adjust for cairo's upside-down coordinate system
          (w,h)   = getSize $ outputFormat opts
          (wd,hd) = size2D d'
          xscale  = w / wd
          yscale  = h / hd
          s       = let s' = min xscale yscale
                    in  if isInfinite s' then 1 else s'
          tr      = (0.5 *. P (w,h)) .-. (s *. center2D d')

          getSize (PNG (pw,ph)) = (fromIntegral pw, fromIntegral ph)
          getSize (PS  sz) = sz
          getSize (PDF sz) = sz
          getSize (SVG sz) = sz

renderC :: (Renderable a Cairo, V a ~ R2) => a -> C.Render ()
renderC a = case (render Cairo a) of C r -> r

cairoStyle :: Style -> C.Render ()
cairoStyle s = sequence_
             . catMaybes $ [ handle fColor
                           , handle lColor  -- see Note [color order]
                           , handle lWidth
                           , handle lCap
                           , handle lJoin
                           , handle lDashing
                           ]
  where handle :: (AttributeClass a) => (a -> C.Render ()) -> Maybe (C.Render ())
        handle f = f `fmap` getAttr s
        fColor c = do
          let (r,g,b,a) = colorToRGBA . getFillColor $ c
          let a' = case getOpacity <$> getAttr s of
                     Nothing -> a
                     Just d  -> a * d
          C.setSourceRGBA r g b a'
          C.fillPreserve
        lColor c = do
          let (r,g,b,a) = colorToRGBA . getLineColor $ c
          let a' = case getOpacity <$> getAttr s of
                     Nothing -> a
                     Just d  -> a * d
          C.setSourceRGBA r g b a'
        lWidth = C.setLineWidth . getLineWidth
        lCap   = C.setLineCap . fromLineCap . getLineCap
        lJoin  = C.setLineJoin . fromLineJoin . getLineJoin
        lDashing (getDashing -> Dashing ds offs) =
          C.setDash ds offs

cairoTransf :: Transformation R2 -> C.Render ()
cairoTransf t = C.transform m
  where m = CM.Matrix a1 a2 b1 b2 c1 c2
        (a1,a2) = apply t (1,0)
        (b1,b2) = apply t (0,1)
        (c1,c2) = transl t

{- ~~~~ Note [color order]

   It's important for the line and fill colors to be handled in the
   given order (fill color first, then line color) because of the way
   Cairo handles them (both are taken from the sourceRGBA).
-}

fromLineCap :: LineCap -> C.LineCap
fromLineCap LineCapButt   = C.LineCapButt
fromLineCap LineCapRound  = C.LineCapRound
fromLineCap LineCapSquare = C.LineCapSquare

fromLineJoin :: LineJoin -> C.LineJoin
fromLineJoin LineJoinMiter = C.LineJoinMiter
fromLineJoin LineJoinRound = C.LineJoinRound
fromLineJoin LineJoinBevel = C.LineJoinBevel

instance Renderable Ellipse Cairo where
  render _ ell = C $ do
    let P (xc,yc) = ellipseCenter ell
        (xs,ys)   = ellipseScale ell
        Rad th    = ellipseAngle ell
    C.newPath
    C.save
    C.translate xc yc
    C.rotate th
    C.scale xs ys
    C.arc 0 0 1 0 (2*pi)
    C.closePath
    C.restore

instance Renderable (Segment R2) Cairo where
  render _ (Linear v) = C $ uncurry C.relLineTo v
  render _ (Cubic (x1,y1) (x2,y2) (x3,y3)) = C $ C.relCurveTo x1 y1 x2 y2 x3 y3

instance Renderable (Trail R2) Cairo where
  render _ (Trail segs c) = C $ do
    mapM_ renderC segs
    when c C.closePath

instance Renderable (Path R2) Cairo where
  render _ (Path trs) = C $ C.newPath >> F.mapM_ renderTrail trs
    where renderTrail (P p, tr) = do
            uncurry C.moveTo p
            renderC tr