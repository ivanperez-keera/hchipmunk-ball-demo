-- | An OpenGL based game loop.
--
-- Some ideas/code were taken from graphics-drawingcombinators (especially image
-- loading and font handling).
--

module Window (
    window
  , windowLoop
  , FrameHandler(..)
  , KeyHandler(..)
  , Key(..)
  , KeyState
  , Modifiers
  , WindowConfig(..)
  , MouseButton
  , MouseHandler(..)
  , MotionHandler(..)
  , Position(..)
  , Image(..)
  , loadImage
  , drawImage
  , text
  , openFont
  , textTTF
  , getTime
  , toVertex
) where

import Control.Concurrent
import Control.Monad
import Data.Bitmap.OpenGL
import Data.IORef
import Data.Time.Clock.POSIX (getPOSIXTime)
import Graphics.Rendering.FTGL
import Graphics.UI.GLUT hiding (Position, Font)
import qualified Codec.Image.STB as Image
import qualified Graphics.UI.GLUT as GLUT
import Unsafe.Coerce


data Image = Image { 
    getImage  :: IORef (Maybe TextureObject)
  , imagePath :: FilePath
}

newtype FrameHandler  = FrameHandler { getFrame :: IO () }

newtype KeyHandler    = KeyHandler { 
    getKeyHandler :: Key -> KeyState -> Modifiers -> IO () 
}

newtype MouseHandler  = MouseHandler { 
    getMouseHandler :: MouseButton -> Position -> IO () 
}

newtype MotionHandler = MotionHandler { 
    getMotionHandler :: Position -> IO () 
}

data Position = Position { 
    getPosition :: (GLdouble, GLdouble) 
} deriving (Show, Eq)


data WindowConfig = WindowConfig {
    frameHandler  :: FrameHandler
  , keyHandler    :: Maybe KeyHandler
  , mouseHandler  :: Maybe MouseHandler
  , motionHandler :: Maybe MotionHandler
  , title         :: String
  , size          :: Size
  , fps           :: Double
}


-- | Creates a new output window using the specified config.
--
window :: WindowConfig -> IO ()
window wc = forkOS (windowMain wc) >> return ()


windowLoop :: WindowConfig -> IO ()
windowLoop wc = do
    windowMain wc
    forever (return ())


-- | Shows the main window and initializes the fps-based loop.
windowMain :: WindowConfig -> IO ()
windowMain wc = do
    getArgsAndInitialize
    createWindow (title wc)
    perWindowKeyRepeat    $= PerWindowKeyRepeatOn
    initialDisplayMode    $= [DoubleBuffered]
    clearColor            $= Color4 1 1 (1 :: GLclampf) 1
    windowSize            $= size wc
    actionOnWindowClose   $= Exit
    keyboardMouseCallback $= Just (eventHandler wc)
    motionCallback        $= Just (motionEventHandler wc)

    -- For antialiasing.
    lineSmooth            $= Enabled
    lineWidth             $= 1.5
    hint LineSmooth       $= Nicest
    
    -- For texturing.
    texture Texture2D     $= Enabled
    blend                 $= Enabled
    blendFunc             $= (SrcAlpha, OneMinusSrcAlpha)

    -- Viewport is currently constant.
    displayCallback $= do
        clear [ColorBuffer]
        loadIdentity
        translate $ Vector3 (-1.0) (-1.0) (0.0 :: GLfloat) 
        scale (2/1.3) (2/1.0) (1.0 :: GLfloat)
        getFrame (frameHandler wc)
        swapBuffers
 
    gameLoop (fps wc)
    mainLoop


gameLoop :: Double -> IO ()
gameLoop fps_ = loop 
  where loop = do
            t1 <- getTime
            postRedisplay Nothing
            t2 <- getTime
            let twait  = t2 - t1
                tdelay = fromEnum $ (1/fps_ - twait) * 1000
            if twait < 1/fps_ 
                then addTimerCallback tdelay loop
                else loop

getTime :: IO Double
getTime = (fromRational . toRational) `fmap` getPOSIXTime


eventHandler :: WindowConfig -> Key -> KeyState -> Modifiers -> GLUT.Position 
  -> IO ()
eventHandler wc key state mods pos =
    case key of
       MouseButton b ->
           case mouseHandler wc of
               Nothing -> return ()
               Just ha -> getMouseHandler ha b (windowToReal wc pos)
       _             -> 
           case keyHandler wc of
               Nothing -> return ()
               Just h  -> getKeyHandler h key state mods


motionEventHandler :: WindowConfig -> GLUT.Position -> IO ()
motionEventHandler wc pos = 
   case motionHandler wc of
       Nothing -> return ()
       Just h  -> getMotionHandler h (windowToReal wc pos)


windowToReal :: WindowConfig -> GLUT.Position -> Position
windowToReal wc pos =
    let GLUT.Position i j = pos
        Size w h = size wc
        x        = 1.3 / fromIntegral w * fromIntegral i
        y        = 1.0 - 1.0 / fromIntegral h * fromIntegral j in
    Position (x,y)


-- | Dummy image loading. 
--
-- We delay real loading until the image is drawn.
loadImage :: FilePath -> IO Image
loadImage path = do
    img <- newIORef Nothing
    return Image {
        getImage  = img
      , imagePath = path
    }


-- | Load an image from disk.
--
-- First, decode the image format. Convert it to an OpenGL texture.
loadImage' :: FilePath -> IO TextureObject
loadImage' path = do
    img <- Image.loadImage path
    case img of
        Left msg -> error $ "Unable to load image " ++ path ++ ": " ++ msg
        Right i  -> makeSimpleBitmapTexture i


-- | Draw an Image on a Quad.
--
-- Quad has the dimension (0,0) .. (1,1), without scaling and translation.
-- z-plane is 0.0. This function is only useful for 2D graphics.
drawImage :: Image -> IO ()
drawImage (Image obj path) = do
    -- Dynamically load the image, if it has not yet been used. We need this
    -- approach to load the image in the correct OpenGL thread.
    img <- readIORef obj
    tobj <- case img of
        Nothing -> do 
            i <- loadImage' path
            writeIORef obj (Just i)
            return i
        Just o  -> return o

    old <- get (textureBinding Texture2D)
    textureBinding Texture2D $= Just tobj
    renderPrimitive Quads $ do
        texcoord (   0, 0)
        toVertex (   0, 1 :: Double)

        texcoord ( 1  , 0)
        toVertex ( 1.3, 1 :: Double)
        
        texcoord ( 1  , 1)
        toVertex ( 1.3, 0 :: Double)
        
        texcoord (   0, 1)
        toVertex (   0, 0 :: Double)
    textureBinding Texture2D $= old
  where texcoord :: (GLdouble, GLdouble) -> IO ()
        texcoord (x,y) = texCoord $ TexCoord2 x y


toVertex :: Num a => (a, a) -> IO () 
toVertex (x,y) = vertex $ Vertex2 (unsafeCoerce x :: GLdouble) (unsafeCoerce y)


text :: (GLfloat, GLfloat) -> [String] -> IO ()
text (x,y) ss' = do
    -- Handle different window sizes correctly by calculating the space between
    -- subsequent lines:
    Size _ wh <- get windowSize
    fs        <- (*1.0) `liftM` fontHeight Fixed9By15
    render (fs / fromIntegral wh) y ss'
  where render _ _ []      = return ()
        render h y' (s:ss) = do
            rasterPos $ Vertex3 x y' 0.0
            renderString Fixed8By13 s
            render h (y'-h) ss


openFont :: String -> IO Font
openFont path = do
    font <- createPolygonFont path
    _ <- setFontFaceSize font 96 96 
    return font


textTTF :: Font -> String -> IO ()
textTTF font str = do
    let f = 1/1000.0 :: GLdouble
    scale f f 1
    renderFont font str All


