{-# OPTIONS -Wall #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}







module PlutusCore.EvaluatorTypes where

import Utils.Env
-- import Utils.Names
import PlutusCore.Term
import PlutusShared.Qualified

import qualified Data.ByteString.Lazy as BS







newtype TransactionInfo = TransactionInfo BS.ByteString

newtype Petrol = Petrol Int
  deriving (Show,Num,Eq,Ord)

type QualifiedEnv = Env QualifiedName Term