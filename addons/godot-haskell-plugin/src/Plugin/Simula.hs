{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeFamilies #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Plugin.Simula (GodotSimula(..)) where

import           Plugin.Imports

import           Plugin.Input
import           Plugin.Input.Grab
import           Plugin.SimulaController
import           Plugin.SimulaViewSprite
import           Plugin.VR
import           Plugin.Types

import           Godot.Core.GodotGlobalConstants
import           Godot.Extra.Register
import           Godot.Nativescript
import qualified Godot.Gdnative.Internal.Api   as Api
import qualified Godot.Methods                 as G

import           Godot.Gdnative.Types
import           Godot.Api
import qualified Godot.Gdnative.Internal.Api   as Api
import qualified Godot.Methods                 as G
import           Godot.Internal.Dispatch                  ( (:<)
                                                          , safeCast
                                                          )
import           Godot.Gdnative.Internal                  ( GodotNodePath
                                                          , GodotObject
                                                          )


data GodotSimula = GodotSimula
  { _sObj      :: GodotObject
  , _sGrabState :: TVar GrabState
  }

instance GodotClass GodotSimula where
  godotClassName = "Simula"

instance ClassExport GodotSimula where
  classInit obj  = GodotSimula obj
    <$> newTVarIO NoGrab

  classExtends = "Node"
  classMethods =
    [ GodotMethod NoRPC "_ready" Plugin.Simula.ready
    , GodotMethod NoRPC "_process" Plugin.Simula.process
    , GodotMethod NoRPC "on_button_signal" Plugin.Simula.on_button_signal
    ]
  classSignals = []

instance HasBaseClass GodotSimula where
  type BaseClass GodotSimula = GodotNode
  super (GodotSimula obj _) = GodotNode obj


ready :: GFunc GodotSimula
ready self _ = do
  -- putStrLn "ready in Simula.hs"
  addSimulaServerNode

  -- OpenHMD is unfortunately not yet a working substitute for OpenVR
  -- https://github.com/SimulaVR/Simula/issues/72
  openVR >>= initVR (safeCast self) >>= \case
    InitVRSuccess -> do
      -- Add the VR origin node
      orig <- unsafeInstance GodotARVROrigin "ARVROrigin"
      G.add_child self (safeCast orig) True

      -- Add the HMD as a child of the origin node
      hmd <- unsafeInstance GodotARVRCamera "ARVRCamera"
      G.add_child orig (safeCast hmd) True

      -- Add two controllers and connect their button presses to the Simula
      -- node.
      let addCt = addSimulaController orig
      addCt "LeftController" 1 >>= connectController
      addCt "RightController" 2 >>= connectController

      return ()

    InitVRFailed  -> return ()

  retnil
 where
  -- Helper function for black texture debugging.
  --   From the internet:
  --   var img = Image()
  --   var tex = ImageTexture.new()
  --   img.load("image.png")
  --   tex.create_from_image(img)
  getTextureFromURL :: String -> IO (GodotTexture)
  getTextureFromURL urlStr = do
    -- instance new types
    godotImage <- unsafeInstance GodotImage "Image" :: IO GodotImage
    godotImageTexture <- unsafeInstance GodotImageTexture "ImageTexture"

    -- Get image from URL
    pngUrl <- toLowLevel (pack urlStr) :: IO GodotString
    exitCode <- G.load godotImageTexture pngUrl -- load :: GodotImageTexture -> GodotString -> IO Int
    -- Load image into texture
    G.create_from_image godotImageTexture godotImage 7 -- uses FLAGS_DEFAULT = 7

    return (safeCast godotImageTexture) -- NOTE: This [probably] leaks godotImage?

  -- Another helper function for black texture debugging (that uses
  -- getTextureFromURL).
  addDummySprite3D gss = do
    godotSprite3D <- unsafeInstance GodotSprite3D "Sprite3D"
    G.set_pixel_size godotSprite3D 0.001
    -- G.add_child gsvs (safeCast godotSprite3D) True
    G.set_flip_h godotSprite3D True

    G.set_name godotSprite3D =<< toLowLevel "DummySprite3D"
    addChild gss godotSprite3D -- Add as child to SimulaServer
    -- G.set_opacity ((safeCast godotSprite3D) GodotSpriteBase3D) (1 :: Float) -- Added from editor
    G.set_opacity godotSprite3D 1.0

    sampleTexture <- getTextureFromURL "res://twitter.png"
    G.set_texture godotSprite3D sampleTexture
    G.set_visible godotSprite3D True

    -- G.translate godotSprite3D =<< toLowLevel (V3 1 1 1)

    -- Print to console to verify we see a "DummySprite3D" in scenegraph
    G.print_tree ((safeCast gss) :: GodotNode)
    return ()

  addSimulaServerNode :: IO ()
  addSimulaServerNode = do
    gss <- "res://addons/godot-haskell-plugin/SimulaServer.gdns"
      & newNS'' GodotSpatial "Spatial" []

    G.set_name gss =<< toLowLevel "SimulaServer"
    G.add_child self (asObj gss) True
    -- G.print_tree ((safeCast gss) :: GodotNode) -- Print tree for debugging
    -- addDummySprite3D gss -- Test
    return ()

  connectController :: GodotSimulaController -> IO ()
  connectController ct = do
    -- putStrLn "connectController"
    argsPressed <- Api.godot_array_new
    Api.godot_array_append argsPressed =<< toLowLevel (toVariant $ asObj ct)
    Api.godot_array_append argsPressed =<< toLowLevel (toVariant True)

    argsReleased <- Api.godot_array_new
    Api.godot_array_append argsReleased =<< toLowLevel (toVariant $ asObj ct)
    Api.godot_array_append argsReleased =<< toLowLevel (toVariant False)

    btnSignal   <- toLowLevel "on_button_signal"
    btnPressed  <- toLowLevel "button_pressed"
    btnReleased <- toLowLevel "button_release"

    G.connect ct btnPressed (safeCast self) btnSignal argsPressed 0
    G.connect ct btnReleased (safeCast self) btnSignal argsReleased 0

    return ()


on_button_signal :: GFunc GodotSimula
on_button_signal self args = do
  -- putStrLn "on_button_signal in Simula.hs"
  case toList args of
    [buttonVar, controllerVar, pressedVar] -> do
      button <- fromGodotVariant buttonVar
      controllerObj <- fromGodotVariant controllerVar
      Just controller <- tryObjectCast controllerObj
      pressed <- fromGodotVariant pressedVar
      onButton self controller button pressed
    _ -> return ()
  toLowLevel VariantNil


onButton :: GodotSimula -> GodotSimulaController -> Int -> Bool -> IO ()
onButton self gsc button pressed = do
  -- putStrLn "onButton in Simula.hs"
  case (button, pressed) of
    (OVR_Button_Grip, False) -> -- Release grabbed
      readTVarIO gst
        >>= processGrabEvent gsc Nothing pressed
        >>= atomically
        .   writeTVar gst

    _ -> do
      let rc = _gscRayCast gsc
      whenM (G.is_colliding rc) $
        G.get_collider rc
          >>= tryObjectCast @GodotSimulaViewSprite
          >>= maybe (return ()) (onSpriteInput rc)
 where
  gst = _sGrabState self
  onSpriteInput rc sprite =
    G.get_collision_point rc >>= case button of
      OVR_Button_Trigger -> processClickEvent sprite (Button pressed BUTTON_LEFT)
      OVR_Button_AppMenu -> processClickEvent sprite (Button pressed BUTTON_RIGHT)
      OVR_Button_Grip    -> const $
        readTVarIO gst
          >>= processGrabEvent gsc (Just sprite) pressed
          >>= atomically
          .   writeTVar gst
      _                  -> const $ return ()


process :: GFunc GodotSimula
process self _ = do
  -- putStrLn "process in Simula.hs"
  let gst = _sGrabState self
  atomically (readTVar gst)
    >>= handleState
    >>= atomically . writeTVar gst

  toLowLevel VariantNil