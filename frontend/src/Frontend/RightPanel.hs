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

module Frontend.RightPanel where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad.State.Strict
import           Data.Aeson                  as Aeson (Object, encode, fromJSON, Result(..))
import qualified Data.ByteString.Lazy        as BSL
import           Data.Foldable
import qualified Data.HashMap.Strict         as H
import qualified Data.List                   as L
import qualified Data.List.Zipper            as Z
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Maybe
import           Data.Semigroup
import           Data.Sequence               (Seq)
import qualified Data.Sequence               as S
import           Data.Set                    (Set)
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import           Reflex
import           Reflex.Dom.ACE.Extended
import           Reflex.Dom.Contrib.Utils
import           Reflex.Dom.Core
import           Reflex.Dom.SemanticUI       hiding (mainWidget)
------------------------------------------------------------------------------
import qualified Pact.Compile                as Pact
import qualified Pact.Parse                  as Pact
import           Pact.Repl
import           Pact.Repl.Types
import           Pact.Types.Lang
import           Obelisk.Generated.Static
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Foundation
import           Frontend.Ide
import           Frontend.JsonData
import           Frontend.UI.Button
import           Frontend.UI.Dialogs.DeployConfirmation
import           Frontend.UI.JsonData
import           Frontend.UI.Repl
import           Frontend.UI.Wallet
import           Frontend.Wallet
import           Frontend.Widgets
------------------------------------------------------------------------------


selectionToText :: EnvSelection -> Text
selectionToText = \case
  EnvSelection_Repl -> "REPL"
  EnvSelection_Env -> "Env"
  EnvSelection_Msgs -> "Messages"
  EnvSelection_Functions -> "Functions"
  EnvSelection_ModuleExplorer -> "Module Explorer"

tabIndicator :: MonadWidget t m => EnvSelection -> Dynamic t Bool -> m (Event t ())
tabIndicator tab isSelected = do
  let f sel = if sel then ("class" =: "active") else mempty
  (e,_) <- elDynAttr' "button" (f <$> isSelected) $ text $ selectionToText tab
  return $ domEvent Click e

mkTab
    :: (MonadWidget t m)
    => Dynamic t EnvSelection
    -> EnvSelection
    -> m (Event t EnvSelection)
mkTab currentTab t = do
    e <- tabIndicator t ((==t) <$> currentTab)
    return (t <$ e)

tabBar :: (MonadWidget t m) => EnvSelection -> [EnvSelection] -> m (Dynamic t EnvSelection)
tabBar initialSelected initialTabs = do
  elAttr "div" ("id" =: "control-nav") $ do
    rec let tabFunc = mapM (mkTab currentTab)
        foo <- widgetHoldHelper tabFunc initialTabs never
        let bar = switch $ fmap leftmost $ current foo
        currentTab <- holdDyn initialSelected bar
    return currentTab

rightTabBar :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
rightTabBar ideL = do
  let curSelection = _ide_envSelection ideL
  let tabs = [ EnvSelection_Env, EnvSelection_Repl, EnvSelection_Msgs, EnvSelection_ModuleExplorer ]
  curSelection <- tabBar EnvSelection_Env tabs
  tabPane mempty curSelection EnvSelection_Env envTab
  tabPane ("class" =: "control-block repl-output") curSelection EnvSelection_Repl $ replWidget ideL
  tabPane mempty curSelection EnvSelection_Msgs msgsTab
  tabPane mempty curSelection EnvSelection_ModuleExplorer explorerTab
  return mempty

envTab :: MonadWidget t m => m ()
envTab = do
  divClass "control-block" $
    el "h2" $ el "button" $
      imgWithAlt (static @"img/arrow-down.svg") "Expand" $ text "Data"
  divClass "control-block" $
    el "h2" $ el "button" $
      imgWithAlt (static @"img/arrow-down.svg") "Expand" $ text "Keys"

msgsTab :: MonadWidget t m => m ()
msgsTab = text "Messages tab"

explorerTab :: MonadWidget t m => m ()
explorerTab = text "Explorer tab"
