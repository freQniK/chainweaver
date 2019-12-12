{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
-- | Dialog for displaying account information required for receiving transfers
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
module Frontend.UI.Dialogs.Receive
  ( uiReceiveModal
  ) where

import Control.Applicative (liftA2, liftA3)
import Control.Lens ((^.), (<>~), _1, _2, _3, view)
import Control.Monad (void, (<=<))
import Control.Error (hush, headMay)

import Data.Bifunctor (first)
import Data.Either (isLeft,rights)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Map as Map
import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Lazy as HM

import Reflex
import Reflex.Dom

import Kadena.SigningApi (DappCap (..))
import Pact.Types.Capability (SigCapability (..))
import Pact.Types.Term (QualifiedName (..), KeySet (..), Name (..), BareName (..))
import Pact.Types.ChainId (ChainId(..))
import Pact.Types.ChainMeta (PublicMeta (..), TTLSeconds)
import Pact.Types.PactValue (PactValue (..))
import Pact.Types.Exp (Literal (LString, LDecimal))
import Pact.Types.Runtime (GasLimit, GasPrice (..))
import Pact.Parse (ParsedDecimal (..))
import qualified Pact.Types.Scheme as PactScheme

import Language.Javascript.JSaddle.Types (MonadJSM)

import Frontend.Crypto.Class (PactKey (..), HasCrypto, cryptoGenPubKeyFromPrivate)
import Common.Wallet (parsePublicKey,toPactPublicKey)

import Frontend.Foundation
import Frontend.KadenaAddress
import Frontend.Network
import Frontend.UI.Dialogs.NetworkEdit

import Frontend.UI.Dialogs.DeployConfirmation (CanSubmitTransaction, TransactionSubmitFeedback (..), submitTransactionWithFeedback)

import Frontend.UI.DeploymentSettings (uiMetaData, defaultGASCapability)

import Frontend.UI.Modal
import Frontend.UI.Widgets
import Frontend.UI.Widgets.AccountName (uiAccountNameInput)
import Frontend.Wallet

data NonBIP32TransferInfo = NonBIP32TransferInfo
  { _legacyTransferInfo_account :: AccountName
  , _legacyTransferInfo_amount :: GasPrice
  , _legacyTransferInfo_pactKey :: PactKey
  }

uiDisplayAddress
  :: ( MonadJSM (Performable m)
     , DomBuilder t m
     , PostBuild t m
     , PerformEvent t m
     )
  => Text
  -> m ()
uiDisplayAddress address = do
  elClass "h2" "heading heading_type_h2" $ text "Kadena Address"
  divClass "group" $ do
    -- Kadena Address
    divClass "segment segment_type_tertiary labeled-input account-details__kadena-address-wrapper" $ do
      void $ uiInputElement $ def
        & initialAttributes <>~ ("disabled" =: "true" <> "class" =: "account-details__kadena-address labeled-input__input")
        & inputElementConfig_initialValue .~ address
      void $ copyButton (def
        & uiButtonCfg_class .~ constDyn "account-details__copy-btn button_type_confirm"
        & uiButtonCfg_title .~ constDyn (Just "Copy")
        ) $ pure address
      pure ()

uiReceiveFromLegacyAccount
  :: ( MonadWidget t m
     , HasWallet model key t
     , HasCrypto key (Performable m)
     )
  => model
  -> m (Dynamic t (Maybe NonBIP32TransferInfo))
uiReceiveFromLegacyAccount model = do
  mAccountName <- uiAccountNameInput (model ^. wallet) (pure Nothing)

  onKeyPair <- divClass "account-details__private-key" $
    _inputElement_input <$> mkLabeledInput True "Private Key" uiInputElement def

  (deriveErr, okPair) <- fmap fanEither . performEvent $ deriveKeyPair <$> onKeyPair

  _ <- widgetHold blank $ leftmost
    [ text <$> deriveErr
    , blank <$ okPair
    ]

  keyPair <- holdDyn Nothing $ Just <$> okPair

  amount <- view _2 <$> mkLabeledInput True "Amount" uiGasPriceInputField def

  pure $ (liftA3 . liftA3) NonBIP32TransferInfo mAccountName amount keyPair
  where
    deriveKeyPair :: (HasCrypto key m, MonadJSM m) => Text -> m (Either Text PactKey)
    deriveKeyPair = fmap (first T.pack) . cryptoGenPubKeyFromPrivate PactScheme.ED25519

uiReceiveModal
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , Flattenable mConf t
     , HasCrypto key m
     , HasCrypto key (Performable m)
     )
  => model
  -> Account key
  -> Maybe ChainId
  -> Event t ()
  -> m (mConf, Event t ())
uiReceiveModal model account mchain _onClose = do
  onClose <- modalHeader $ text "Receive"
  (conf, closes) <- fmap splitDynPure $ workflow $ uiReceiveModal0 model account mchain onClose
  mConf <- flatten =<< tagOnPostBuild conf
  let close = switch $ current closes
  pure (mConf, close)

uiReceiveModal0
  :: ( MonadWidget t m
     , Monoid mConf
     , HasNetwork model t
     , HasNetworkCfg mConf t
     , HasWallet model key t
     , HasCrypto key (Performable m)
     , HasCrypto key m
     )
  => model
  -> Account key
  -> Maybe ChainId
  -> Event t ()
  -> Workflow t m (mConf, Event t ())
uiReceiveModal0 model account mchain onClose = Workflow $ do
  let
    netInfo = do
      nodes <- model ^. network_selectedNodes
      meta <- model ^. network_meta
      let networkId = hush . mkNetworkName . nodeVersion <=< headMay $ rights nodes
      pure $ (nodes, meta, ) <$> networkId

    displayText lbl v cls =
      let
        attrFn cfg = uiInputElement $ cfg
          & initialAttributes <>~ ("disabled" =: "true" <> "class" =: (" " <> cls))
      in
        mkLabeledInputView True lbl attrFn $ pure v

  (showingAddr, chain, (conf, ttl, gaslimit, transferInfo)) <- divClass "modal__main account-details" $ do
    rec
      showingKadenaAddress <- toggle True $ onAddrClick <> onReceiClick

      elClass "h2" "heading heading_type_h2" $ text "Destination"
      chain <- divClass "group" $ do
        -- Network
        void $ mkLabeledClsInput True "Network" $ \_ -> do
          stat <- queryNetworkStatus (model ^. network_networks) $ pure $ _account_network account
          uiNetworkStatus "signal__left-floated" stat
          text $ textNetworkName $ _account_network account
        -- Chain id
        case mchain of
          Nothing -> userChainIdSelect model
          Just cid -> (pure $ Just cid) <$ displayText "Chain ID" (_chainId cid) "account-details__chain-id"

      (onAddrClick, ((), ())) <- controlledAccordionItem showingKadenaAddress mempty (text "Option 1: Copy and share Kadena Address")
        $ do
        dyn_ $ ffor chain $ uiDisplayAddress  . \case
          Nothing -> "Please select a chain"
          Just cid -> textKadenaAddress $ accountToKadenaAddress account cid

      (onReceiClick, results) <- controlledAccordionItem (not <$> showingKadenaAddress) "account-details__legacy-send"
        (text "Option 2: Transfer from non-Chainweaver Account") $ do
        elClass "h2" "heading heading_type_h2" $ text "Sender Details"
        transferInfo0 <- divClass "group" $ uiReceiveFromLegacyAccount model
        elClass "h2" "heading heading_type_h2" $ text "Transaction Settings"
        (conf0, ttl0, gaslimit0) <- divClass "group" $ uiMetaData model Nothing Nothing
        pure (conf0, ttl0, gaslimit0, transferInfo0)

    pure (showingKadenaAddress, chain, snd results)

  let isDisabled = liftA2 (&&) (isNothing <$> transferInfo) (not <$> showingAddr)

  doneNext <- modalFooter $ uiButtonDyn
    (def
     & uiButtonCfg_class <>~ "button_type_confirm"
     & uiButtonCfg_disabled .~ isDisabled
    )
    $ dynText (bool "Submit Transfer" "Close" <$> showingAddr)

  let
    done = gate (current showingAddr) doneNext
    deploy = gate (not <$> current showingAddr) doneNext
    ap2' = (liftA2 . liftA2) (&)

  pure ( (conf, onClose <> done)
       , receiveFromLegacySubmit onClose account
         & (pure . Just)
         & ap2' chain
         & ap2' (fmap Just ttl)
         & ap2' (fmap Just gaslimit)
         & ap2' netInfo
         & ap2' transferInfo
         & current
         & flip tagMaybe deploy
       )

receiveFromLegacySubmit
  :: ( Monoid mConf
     , CanSubmitTransaction t m
     , HasCrypto key m
     )
  => Event t ()
  -> Account key
  -> ChainId
  -> TTLSeconds
  -> GasLimit
  -> ([Either a NodeInfo], PublicMeta, NetworkName)
  -> NonBIP32TransferInfo
  -> Workflow t m (mConf, Event t ())
receiveFromLegacySubmit onClose account chain ttl gasLimit netInfo transferInfo = Workflow $ do
  let
    sender = _legacyTransferInfo_account transferInfo
    senderKey = _legacyTransferInfo_pactKey transferInfo
    senderPubKey = _pactKey_publicKey senderKey
    amount = _legacyTransferInfo_amount transferInfo
    accCreated = accountIsCreated account

    unpackGasPrice (GasPrice (ParsedDecimal d)) = d

    code = T.unwords $
      [ "(coin." <> case accCreated of
          AccountCreated_No -> "transfer-create"
          AccountCreated_Yes -> "transfer"
      , tshow $ unAccountName $ sender
      , tshow $ unAccountName $ _account_name account
      , case accCreated of
          AccountCreated_No -> "(read-keyset 'key)"
          AccountCreated_Yes -> mempty
      , tshow amount
      , ")"
      ]

    transferSigCap = SigCapability
      { _scName = QualifiedName
        { _qnQual = "coin"
        , _qnName = "TRANSFER"
        , _qnInfo = def
        }
      , _scArgs =
        [ PLiteral $ LString $ unAccountName sender
        , PLiteral $ LString $ unAccountName $ _account_name account
        , PLiteral $ LDecimal (unpackGasPrice amount)
        ]
      }

    dat = case accountIsCreated account of
      AccountCreated_No
        | Right pk <- parsePublicKey (unAccountName $ _account_name account)
        -> HM.singleton "key" $ Aeson.toJSON $ KeySet [toPactPublicKey pk] (Name $ BareName "keys-all" def)
      _ -> mempty

    pkCaps = Map.singleton senderPubKey [_dappCap_cap defaultGASCapability, transferSigCap]

    pm = (netInfo ^. _2)
      { _pmChainId = chain
      , _pmSender = unAccountName sender
      , _pmGasLimit = gasLimit
      , _pmTTL = ttl
      }

  cmd <- buildCmdWithPactKey
    senderKey
    Nothing
    (netInfo ^. _3)
    pm
    [KeyPair (_pactKey_publicKey senderKey) Nothing]
    []
    code
    dat
    pkCaps

  txnSubFeedback <- elClass "div" "modal__main transaction_details" $
    submitTransactionWithFeedback cmd chain (netInfo ^. _1)

  let isDisabled = maybe True isLeft <$> _transactionSubmitFeedback_message txnSubFeedback

  done <- modalFooter $ uiButtonDyn
    (def & uiButtonCfg_class .~ "button_type_confirm" & uiButtonCfg_disabled .~ isDisabled)
    (text "Done")

  pure
    ( (mempty, done <> onClose)
    , never
    )
