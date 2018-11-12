{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ExtendedDefaultRules   #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RecursiveDo            #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}

-- |
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.ReplGhcjs where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad.State.Strict
import           Data.Foldable
import qualified Data.Map                    as Map
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Data.Traversable            (for)
import           Reflex
import           Reflex.Dom.ACE.Extended
import           Reflex.Dom.SemanticUI       hiding (mainWidget)
------------------------------------------------------------------------------
import           Pact.Repl
import           Pact.Repl.Types
import           Pact.Types.Lang
import           Obelisk.Generated.Static
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Foundation
import           Frontend.Ide
import           Frontend.JsonData
import           Frontend.UI.RightPanel
import           Frontend.UI.Button
import           Frontend.UI.Modal
import           Frontend.UI.Widgets
------------------------------------------------------------------------------

data ClickState = DownAt (Int, Int) | Clicked | Selected
  deriving (Eq,Ord,Show,Read)

app :: MonadWidget t m => m ()
app = void . mfix $ \ cfg -> do
  ideL <- makeIde cfg

  controlCfg <- controlBar
  mainCfg <- elAttr "main" ("id" =: "main" <> "class" =: "flexbox even") $ do
    editorCfg <- codePanel ideL
    envCfg <- elAttr "div" ("class" =: "flex" <> "id" =: "control-ui") $ do
      rightTabBar ideL
    pure $ editorCfg <> envCfg

  modalCfg <- showModal ideL

  pure $ mconcat
    [ controlCfg
    , mainCfg
    , modalCfg
    ]

-- | Code editing (left hand side currently)
codePanel :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
codePanel ideL = do
  elAttr "div" ("class" =: "flex" <> "id" =: "main-wysiwyg") $
    divClass "wysiwyg" $ do
      onNewCode <- tagOnPostBuild $ _ide_code ideL
      onUserCode <- codeWidget "" onNewCode

      pure $ mempty & ideCfg_setCode .~ onUserCode

functionsList :: MonadWidget t m => Ide t -> BackendUri -> [PactFunction] -> m ()
functionsList ideL backendUri functions = divClass "ui very relaxed list" $ do
  for_ functions $ \(PactFunction (ModuleName moduleName) name _ mdocs funType) -> divClass "item" $ do
    (e, _) <- elClass' "a" "header" $ do
      text name
      text ":"
      text $ tshow $ _ftReturn funType
      text " "
      elAttr "span" ("class" =: "description" <> "style" =: "display: inline") $ do
        text "("
        text $ T.unwords $ tshow <$> _ftArgs funType
        text ")"
    for_ mdocs $ divClass "description" . text
    open <- toggle False $ domEvent Click e
    dyn_ $ ffor open $ \case
      False -> pure ()
      True -> segment def $ form def $ do
        inputs <- for (_ftArgs funType) $ \arg -> field def $ do
          el "label" $ text $ "Argument: " <> tshow arg
          case _aType arg of
            TyPrim TyInteger -> fmap value . input def $ inputElement $ def
              & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                [ ("type", "number")
                , ("step", "1")
                , ("placeholder", _aName arg)
                ]
            TyPrim TyDecimal -> do
              ti <- input def $ inputElement $ def
                & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                  [ ("type", "number")
                  , ("step", "0.0000000001") -- totally arbitrary
                  , ("placeholder", _aName arg)
                  ]
              pure $ (\x -> if T.isInfixOf "." x then x else x <> ".0") <$> value ti
            TyPrim TyTime -> do
              i <- input def $ inputElement $ def
                & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                  [ ("type", "datetime-local")
                  , ("step", "1") -- 1 second step
                  ]
              pure $ (\x -> "(time \"" <> x <> "Z\")") <$> value i
            TyPrim TyBool -> do
              d <- dropdown def (pure False) $ TaggedStatic $ Map.fromList
                [(True, text "true"), (False, text "false")]
              pure $ T.toLower . tshow . runIdentity <$> value d
            TyPrim TyString -> do
              ti <- input def $ textInput (def & textInputConfig_placeholder .~ pure (_aName arg))
              pure $ tshow <$> value ti -- TODO better escaping
            TyPrim TyKeySet -> do
              d <- dropdown (def & dropdownConfig_placeholder .~ "Select a keyset") Nothing $ TaggedDynamic $ ffor (_jsonData_keysets $ _ide_jsonData ideL) $
                Map.mapWithKey (\k _ -> text k)
              pure $ maybe "" (\x -> "(read-keyset \"" <> x <> "\")") <$> value d
            _ -> fmap value . input def $
              textInput (def & textInputConfig_placeholder .~ pure (_aName arg))
        let buttonConfig = def
              & buttonConfig_type .~ SubmitButton
              & buttonConfig_emphasis .~ Static (Just Primary)
        submit <- button buttonConfig $ text "Call function"
        let args = tag (current $ sequence inputs) submit
            callFun = ffor args $ \as -> mconcat ["(", moduleName, ".", name, " ", T.unwords as, ")"]
        -- for debugging: widgetHold blank $ ffor callFun $ label def . text
        let ed = ideL ^. ide_jsonData . jsonData_data
        deployedResult <- backendRequest (ideL ^. ide_wallet) $
          ffor (attach (current ed) callFun) $ \(cEd, c) ->
            BackendRequest
              { _backendRequest_code = c
              , _backendRequest_data = either mempty id cEd
              , _backendRequest_backend = backendUri
              , _backendRequest_signing = Set.empty
              }
              -- FIXME Probably bad...need to pop up the deploy confirmation dialog
        widgetHold_ blank $ ffor deployedResult $ \(_uri, x) -> case x of
          Left err -> message (def & messageConfig_type .~ Static (Just (MessageType Negative))) $ do
            text $ prettyPrintBackendError err
          Right v -> message def $ text $ tshow v

codeWidget
  :: MonadWidget t m
  => Text -> Event t Text
  -> m (Event t Text)
codeWidget iv sv = do
    let ac = def { _aceConfigMode = Just "ace/mode/pact"
                 , _aceConfigElemAttrs = "class" =: "ace-code ace-widget"
                 }
    ace <- resizableAceWidget mempty ac (AceDynConfig Nothing) never iv sv
    return $ _extendedACE_onUserChange ace


controlBar :: forall t m. MonadWidget t m => m (IdeCfg t)
controlBar = do
    elAttr "header" ("id" =: "header") $ do
      divClass "flexbox even" $ do
        ideCfgL <- controlBarLeft
        controlBarRight
        return ideCfgL

controlBarLeft :: MonadWidget t m => m (IdeCfg t)
controlBarLeft = do
    divClass "flex left-nav" $ do
      el "h1" $ do
        imgWithAlt (static @"img/pact-logo.svg") "PACT" blank
        ver <- getPactVersion
        elClass "span" "version" $ text $ "v" <> ver
      elAttr "div" ("id" =: "header-project-loader") $ do
        onLoad <- uiButtonSimple "Load into REPL"

        onDeployClick <- uiButtonSimple "Deploy"

        let
          reqConfirmation = Modal_DeployConfirmation <$ onDeployClick
          lcfg = mempty
            & ideCfg_load .~ onLoad
            & ideCfg_reqModal .~ reqConfirmation
        pure lcfg

getPactVersion :: MonadWidget t m => m Text
getPactVersion = do
    is <- liftIO $ initReplState StringEval
    Right (TLiteral (LString ver) _) <- liftIO $ evalStateT (evalRepl' "(pact-version)") is
    return ver

controlBarRight :: MonadWidget t m => m ()
controlBarRight = do
    elAttr "div" ("class" =: "flex right" <> "id" =: "header-links") $ do
      elAttr "a" ( "href" =: "http://pact-language.readthedocs.io"
                <> "class" =: "documents" <> "target" =: "_blank"
                 ) $ do
        imgWithAlt (static @"img/document.svg") "Documents" blank
        text "Docs"
      elAttr "a" ( "href" =: "http://kadena.io"
                <> "class" =: "documents" <> "target" =: "_blank") $
        imgWithAlt (static @"img/gray-kadena-logo.svg") "Kadena" blank
