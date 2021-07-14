{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Desktop.Crypto.BIP where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Primitive (PrimMonad (PrimState, primitive))
import Control.Monad.Reader
import Control.Monad.Ref (MonadRef, MonadAtomicRef)
import Data.Aeson (ToJSON(..), FromJSON(..))
import Data.Aeson.GADT.TH
import Data.Bits ((.|.))
import Data.ByteString (ByteString)
import Data.Coerce (coerce)
import Data.Constraint.Extras.TH
import Data.GADT.Compare.TH
import Data.GADT.Show.TH
import Data.Text (Text)
import qualified Data.Text as T
import Data.Universe.Some.TH
import Language.Javascript.JSaddle (MonadJSM)
import Obelisk.Route.Frontend
import Pact.Server.ApiClient (HasTransactionLogger)
import Pact.Types.Util (parseB16TextOnly)
import Reflex.Dom hiding (fromJSString)
import Reflex.Host.Class (MonadReflexCreateTrigger)

import qualified Cardano.Crypto.Wallet as Crypto
import qualified Control.Newtype.Generics as Newtype
import qualified Data.Text.Encoding as T
import qualified Pact.Types.Crypto as PactCrypto
import qualified Pact.Types.Hash as Pact

import Frontend.Crypto.Ed25519
import Frontend.Crypto.Class
import Frontend.Crypto.Signature
import Frontend.Foundation
import Frontend.Storage

-- Right now we have a restriction where this BIPStorage
-- can never actually change.
--
-- This feels like a good thing, because our frontend schema is pretty
-- locked into the Crypto key type not being upgradeable, and we really
-- want to store all of the frontend state in frontend. This spot for
-- the root key should be a special case and stay static, I hope.
--
-- I think that we should wait till we figure out what we want from web
-- and whether we can simplify the split before we do anything too crazy here.
-- Hopefully that happens before we have to modify this storage!
data BIPStorage a where
  BIPStorage_RootKey :: BIPStorage Crypto.XPrv
deriving instance Show (BIPStorage a)

bipMetaPrefix :: StoreKeyMetaPrefix
bipMetaPrefix = StoreKeyMetaPrefix "BIPStorage_Meta"

-- | Check the validity of the password by signing and verifying a message
passwordRoundTripTest :: Crypto.XPrv -> Text -> Bool
passwordRoundTripTest xprv pass = Crypto.verify (Crypto.toXPub xprv) msg $ Crypto.sign (T.encodeUtf8 pass) xprv msg
  where
    msg :: ByteString
    msg = "the quick brown fox jumps over the lazy dog"

concat <$> traverse ($ ''BIPStorage)
  [ deriveGShow
  , deriveGEq
  , deriveGCompare
  , deriveUniverseSome
  , deriveArgDict
  , deriveJSONGADT
  ]

-- This transformer has access to the current root key and login password
newtype BIPCryptoT t m a = BIPCryptoT
  { unBIPCryptoT :: ReaderT (Behavior t (Crypto.XPrv, Text)) m a
  } deriving
    ( Functor, Applicative, Monad
    , MonadFix, MonadIO, MonadRef, MonadAtomicRef
    , DomBuilder t, NotReady t, MonadHold t, MonadSample t
    , TriggerEvent t, PostBuild t, HasJS x
    , MonadReflexCreateTrigger t, MonadQuery t q, Requester t
    , HasStorage, HasDocument
    , Routed t r, RouteToUrl r, SetRoute t r, EventWriter t w
    , DomRenderHook t
    , HasConfigs, HasTransactionLogger
    )

bipCryptoGenPair :: Crypto.XPrv -> Text -> Int -> (Crypto.XPrv, PublicKey)
bipCryptoGenPair root pass i =
  let xprv = Crypto.deriveXPrv scheme (T.encodeUtf8 pass) root (mkHardened $ fromIntegral i)
  in (xprv, unsafePublicKey $ Crypto.xpubPublicKey $ Crypto.toXPub xprv)
  where
    scheme = Crypto.DerivationScheme2
    mkHardened = (0x80000000 .|.)

instance (MonadSample t m, MonadJSM m) => HasCrypto Crypto.XPrv (BIPCryptoT t m) where
  cryptoSign bs xprv = BIPCryptoT $ do
    (_, pass) <- sample =<< ask
    pure $ Newtype.pack $ Crypto.unXSignature $ Crypto.sign (T.encodeUtf8 pass) xprv bs
  cryptoVerify bs sig (PublicKey pub) = BIPCryptoT $ do
    pure $ PactCrypto.verify
      (PactCrypto.toScheme PactCrypto.ED25519)
      (Pact.Hash bs)
      (PactCrypto.PubBS pub)
      (PactCrypto.SigBS $ unSignature sig)
  cryptoGenKey i = BIPCryptoT $ do
    (root, pass) <- sample =<< ask
    liftIO $ putStrLn $ "Deriving key at index: " <> show i
    pure $ bipCryptoGenPair root pass i
  -- This assumes that the secret is already base16 encoded (being pasted in, so makes sense)
  cryptoGenPubKeyFromPrivate pkScheme sec = pure $ do
    secBytes <- parseB16TextOnly sec
    somePactKey <- importKey pkScheme Nothing secBytes
    pure $ PactKey pkScheme (unsafePublicKey $ PactCrypto.getPublic somePactKey) secBytes
  cryptoSignWithPactKey bs pk = do
    let someKpE = importKey
          (_pactKey_scheme pk)
          (Just $ Newtype.unpack $ _pactKey_publicKey pk)
          $ _pactKey_secret pk

    case someKpE of
      Right someKp -> liftIO $ Newtype.pack <$> PactCrypto.sign someKp (Pact.Hash bs)
      Left e -> error $ "Error importing pact key from account: " <> e
  cryptoSignWithPactKeyEither bs pk = do
    let someKpE = importKey
          (_pactKey_scheme pk)
          (Just $ Newtype.unpack $ _pactKey_publicKey pk)
          $ _pactKey_secret pk

    case someKpE of
      Right someKp -> liftIO $ (Right . Newtype.pack) <$> PactCrypto.sign someKp (Pact.Hash bs)
      Left e -> pure $ Left $ "Error importing pact key from account: " <> T.pack e

importKey :: PactCrypto.PPKScheme -> Maybe ByteString -> ByteString -> Either String PactCrypto.SomeKeyPair
importKey pkScheme mPubBytes secBytes = PactCrypto.importKeyPair
  (PactCrypto.toScheme pkScheme)
  (PactCrypto.PubBS <$> mPubBytes)
  (PactCrypto.PrivBS secBytes)


instance PerformEvent t m => PerformEvent t (BIPCryptoT t m) where
  type Performable (BIPCryptoT t m) = BIPCryptoT t (Performable m)
  performEvent_ = BIPCryptoT . performEvent_ . fmap unBIPCryptoT
  performEvent = BIPCryptoT . performEvent . fmap unBIPCryptoT

instance PrimMonad m => PrimMonad (BIPCryptoT t m) where
  type PrimState (BIPCryptoT t m) = PrimState m
  primitive = lift . primitive

instance HasJSContext m => HasJSContext (BIPCryptoT t m) where
  type JSContextPhantom (BIPCryptoT t m) = JSContextPhantom m
  askJSContext = BIPCryptoT askJSContext
#if !defined(ghcjs_HOST_OS)
instance MonadJSM m => MonadJSM (BIPCryptoT t m)
#endif

instance MonadTrans (BIPCryptoT t) where
  lift = BIPCryptoT . lift

instance (Adjustable t m, MonadHold t m, MonadFix m) => Adjustable t (BIPCryptoT t m) where
  runWithReplace a0 a' = BIPCryptoT $ runWithReplace (unBIPCryptoT a0) (fmapCheap unBIPCryptoT a')
  traverseDMapWithKeyWithAdjust f dm0 dm' = BIPCryptoT $ traverseDMapWithKeyWithAdjust (coerce . f) dm0 dm'
  traverseDMapWithKeyWithAdjustWithMove f dm0 dm' = BIPCryptoT $ traverseDMapWithKeyWithAdjustWithMove (coerce . f) dm0 dm'
  traverseIntMapWithKeyWithAdjust f im0 im' = BIPCryptoT $ traverseIntMapWithKeyWithAdjust (coerce f) im0 im'

instance (Prerender js t m, Monad m, Reflex t) => Prerender js t (BIPCryptoT t m) where
  type Client (BIPCryptoT t m) = BIPCryptoT t (Client m)
  prerender a b = BIPCryptoT $ prerender (unBIPCryptoT a) (unBIPCryptoT b)

runBIPCryptoT :: Behavior t (Crypto.XPrv, Text) -> BIPCryptoT t m a -> m a
runBIPCryptoT b (BIPCryptoT m) = runReaderT m b
