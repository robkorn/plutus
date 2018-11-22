-- File auto generated by purescript-bridge! --
module Wallet.Emulator.Types where

import Data.Lens (Iso', Lens', Prism', lens, prism')
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype)
import Data.Symbol (SProxy(SProxy))
import Prim (Int)

import Prelude
import Data.Generic (class Generic)

newtype Wallet =
    Wallet Int

derive instance genericWallet :: Generic Wallet
derive instance newtypeWallet :: Newtype Wallet _

--------------------------------------------------------------------------------
_Wallet :: Iso' Wallet Int
_Wallet = _Newtype
--------------------------------------------------------------------------------