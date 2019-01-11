{-# LANGUAGE ConstraintKinds        #-}
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

-- | Implementation of the Frontend.ModuleExplorer interface.
--
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.ModuleExplorer.Impl
  ( -- * Interface
    module API
    -- * Types
  , HasModuleExplorerModelCfg
    -- * Creation
  , makeModuleExplorer
  ) where

------------------------------------------------------------------------------
import qualified Bound
import Control.Monad.Except (throwError)
import Control.Monad (void, (<=<))
import           Control.Arrow               ((***), left)
import           Data.Bifunctor (second)
import           Control.Lens
import           Data.Aeson                  as Aeson (Result (..), fromJSON, FromJSON, Value)
import           Data.Default
import qualified Data.Map                    as Map
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Reflex
import           Reflex.Dom.Core             (HasJSContext, MonadHold,
                                              PostBuild, XhrResponse (..),
                                              newXMLHttpRequest, xhrRequest)
------------------------------------------------------------------------------
import qualified Pact.Compile                as Pact
import qualified Pact.Parse                  as Pact
import           Pact.Types.Lang
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Editor
import           Frontend.Foundation
import           Frontend.JsonData
import           Frontend.Messages
import           Frontend.ModuleExplorer     as API
import           Frontend.ModuleExplorer.Example
import           Frontend.Repl
import           Frontend.Wallet

type HasModuleExplorerModelCfg mConf t =
  ( Monoid mConf
  , HasEditorCfg mConf t
  , HasMessagesCfg mConf t
  , HasJsonDataCfg mConf t
  , HasReplCfg mConf t
  , HasBackendCfg mConf t
  )

type HasModuleExplorerModel model t =
  ( HasEditor model t
  , HasJsonData model t
  , HasBackend model t
  )


-- | Constraints needed by functions in this module.
type ReflexConstraints t m =
  ( MonadHold t m, TriggerEvent t m, Reflex t, PerformEvent t m
  , HasJSContext (Performable m) , MonadJSM (Performable m)
  , PostBuild t m, MonadFix m
  )


makeModuleExplorer
  :: forall t m cfg mConf model
  . ( ReflexConstraints t m
    , HasModuleExplorerCfg cfg t
    {- , HasModuleExplorerModel model t -}
    , HasModuleExplorerModelCfg mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> cfg
  -> m (mConf, ModuleExplorer t)
makeModuleExplorer m cfg = do
    selectedFile <- selectFile
      (cfg ^. moduleExplorerCfg_selectFile)
      (getFileModuleRef <$> cfg ^. moduleExplorerCfg_pushModule)

    (lFileCfg, loadedSource) <- loadToEditor
      (cfg ^. moduleExplorerCfg_loadFile)
      (cfg ^. moduleExplorerCfg_loadModule)

    (loadedCfg, loaded)     <- loadModule $ cfg ^. moduleExplorerCfg_loadModule
    (selectedCfg, selected) <- selectModule m $ cfg ^. moduleExplorerCfg_selModule
    let
      deployEdCfg = deployEditor m $ cfg ^. moduleExplorerCfg_deployEditor
      deployCodeCfg = deployCode m $ cfg ^. moduleExplorerCfg_deployCode

    pure
      ( mconcat [ lFileCfg ]
      , ModuleExplorer
          { _mod = undefined
          , _moduleExplorer_selectedModule = selected
          , _moduleExplorer_selectedFile = selectedFile 
          , _moduleExplorer_loaded = loadedSource
          }
      )

deployEditor
  :: forall t mConf model
  . ( Reflex t
    , HasModuleExplorerModelCfg  mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> Event t TransactionInfo
  -> mConf
deployEditor m = deployCode m . attach (current $ m ^. editor_code)

deployCode
  :: forall t mConf model
  . ( Reflex t
    , HasModuleExplorerModelCfg  mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> Event t (Text, TransactionInfo)
  -> mConf
deployCode m onDeploy =
  let
    mkReq :: Dynamic t ((Text, TransactionInfo) -> Maybe BackendRequest)
    mkReq = do
      ed      <- m ^. jsonData_data
      mbs     <- m ^. backend_backends
      pure $ \(code, info) -> do
        bs <- mbs
        b <- Map.lookup (_transactionInfo_backend info) bs
        d <- ed ^? _Right
        pure $ BackendRequest code d b (_transactionInfo_keys info)

    jsonError :: Dynamic t (Maybe Text)
    jsonError = do
      ed <- m ^. jsonData_data
      pure $ case ed of
        Left _  -> Just $ "Deploy not possible: JSON data was invalid!"
        Right _ -> Nothing

  in
    mempty
      & backendCfg_deployCode .~ attachWithMaybe ($) (current mkReq) onDeploy
      & messagesCfg_send .~ tagMaybe (current jsonError) onDeploy

-- | Takes care of loading a file/module into the editor.
loadToEditor
  :: forall m t mConf model
  . ( ReflexConstraints t m
    , HasModuleExplorerModelCfg  mConf t
    , HasModuleExplorerModel model t
    )
  => model
  -> Event t FileRef
  -> Event t ModuleRef
  -> m (mConf, MDynamic t ModuleSource)
loadToEditor m onFileRef onModRef = do
  let onFileModRef = fmapMaybe getFileModuleRef onModRef
  fileModRequested <- holdDyn Nothing $ Just <$> onFileModRef

  onFile <- fetchFile $ leftmost
    [ onFileRef
    , _moduleRef_source <$> onModRef
    ]
  let onFileRef = fst <$> onFile

  (modCfg, onMod)  <- loadModule $ fmapMaybe getDeployedModuleRef onModRef
  let onModRef = fst <$> onMod

  loaded <- holdDyn Nothing $ Just <$> leftmost 
    [ ModuleSource_File <$> onFileRef
    , _moduleRef_source <$> onModRef
    ]

  let
    onCode = fmap _unCode $ leftmost
      [ fmapMaybe id $ attachPromptlyWith getFileModuleCode fileModRequested onFile
      , snd <$> onFile
      , _mCode . snd <$> onMod
      ]

    getFileModuleCode :: ModuleRef -> (FileRef, PactFile) -> Maybe Code
    getFileModuleCode (ModuleRef _ n) =
      lookup n
      . map (\(m, _) -> (nameOfModule m, codeOfModule m))
      . parseFileModules
      . snd

  pure ( mconcat [modCfg, mempty & editorCfg_setCode .~ onCode]
       , loaded
       )


-- | Load a deployed module.
--
--   Loading errors will be reported to `Messages`.
loadModule
  :: forall m t mConf
  . ( ReflexConstraints t m
    , HasModuleExplorerModelCfg  mConf t
    )
  => Event t DeployedModuleRef
  -> m (mConf, Event t (DeployedModuleRef, Module))
loadModule onRef = do
  onErrModule <- fetchModule onRef
  let
    onErr    = (^. _2 . _Left)      <$> onErrModule
    onModule = (_2  %~ (^. _Right)) <$> onErrModule
  pure
    ( mempty & messagesCfg_send .~ onErr
    , onModule
    )

-- | Select a `PactFile`, note that a file gets also implicitely selected when
--   a module of a given file gets selected.
selectFile
  :: forall m t
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , HasJSContext (Performable m), TriggerEvent t m, MonadFix m
    )
  => Event t FileModuleRef
  -> Event t (Maybe FileRef)
  -> m (MDynamic t (FileRef, PactFile))
selectFile onModRef onMayFileRef = mdo

  onFileSelectByModule <- fetchFile $ _moduleRef_source <$> onModRef
  onFileSelect <- fetchFile $ fmapMaybe id onMayFileRef

  holdDyn Nothing $ leftmost
    [ Just    <$> onFileSelectedByModule
    , Just    <$> onFileSelect
    , Nothing <$  ffilter isNothing onMayFileRef
    ]


-- | Push/pop a module on the `_moduleExplorer_moduleStack`.
--
--   The returned Event triggers whenever the stack changes and signals a newly
--   selected module.
pushPopModule
  :: forall m t mConf model
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , HasJSContext (Performable m), TriggerEvent t m, MonadFix m
    , HasMessagesCfg  mConf t, Monoid mConf
    , HasBackend model t
    )
  => model
  -> Event t ModuleRef
  -> Event t ()
  -> m (Event t (Maybe ModuleRef), Dynamic t [(ModuleRef, Module)])
pushPopModule m onPush onPop = do
  stack <- foldDyn id [] $ leftmost
    [ (:) <$> onPush
    , tailSafe <$ onPop
    ]

  let onPopped = tagWith headMay stack onPop

  pure
    ( leftmost [ onPopped, onPush ]
    , stack
    )


-- | Select Example contract.
selectExample
  :: forall m t
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , HasJSContext (Performable m), TriggerEvent t m
    )
  => Event t ExampleModule
  -> m (Event t SelectedModule)
selectExample onSelReq = do
  onExampleRec <- fetchExample onSelReq
  let
    buildSelected :: ExampleModule -> Text -> SelectedModule
    buildSelected depl code =
      SelectedModule (ModuleSel_Example depl) code (listPactFunctions (Code code))

  pure $ uncurry buildSelected . second fst <$> onExampleRec


-- | Select a deployed contract.
--
--   For deployed contracts this loads its code & functions.
--
--   The returned Event fires once the loading is complete.
selectDeployed
  :: forall m t mConf
  . ( MonadHold t m, PerformEvent t m, MonadJSM (Performable m)
    , HasJSContext (Performable m), TriggerEvent t m
    , HasMessagesCfg  mConf t, Monoid mConf
    )
  => Event t DeployedModule
  -> m (mConf, Event t SelectedModule)
selectDeployed onSelReq = do
  onErrModule <- fetchDeployedModule onSelReq
  let
    onErr = fmapMaybe (^? _2 . _Left) onErrModule

    onRes :: Event t (DeployedModule, Module)
    onRes = fmapMaybe (traverse (^? _Right)) onErrModule

    buildSelected :: DeployedModule -> Module -> SelectedModule
    buildSelected depl m =
      SelectedModule
        (ModuleSel_Deployed depl)
        (_unCode $ _mCode m)
        (listPactFunctions (_mCode m))

  pure
    ( mempty
        & messagesCfg_send .~ fmap ("Loading functions failed: " <>) onErr
    , uncurry buildSelected <$> onRes
    )
