{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications     #-}
{-# OPTIONS -fplugin Language.PlutusTx.Plugin -fplugin-opt Language.PlutusTx.Plugin:dont-typecheck #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Most tests for this functionality are in the plugin package, this is mainly just checking that the wiring machinery
-- works.
module Main (main) where

import           Common
import           PlcTestUtils

import           TestTH

import           Language.PlutusTx.TH
import qualified Language.PlutusTx.Builtins as Builtins
import           Language.PlutusTx.Prelude
import           Language.PlutusTx.Evaluation

import qualified Language.PlutusIR          as PIR

import           Language.PlutusCore.Pretty
import           Language.PlutusCore

import           Control.Monad.Except
import           Control.Exception

import Data.Text.Prettyprint.Doc
import           Test.Tasty

main :: IO ()
main = defaultMain $ runTestNestedIn ["test"] tests

instance GetProgram (CompiledCode a) where
    getProgram = catchAll . getPlc

goldenPir :: String -> CompiledCode a -> TestNested
goldenPir name value = nestedGoldenVsDoc name $ pretty $ getPir value

runPlcCek :: GetProgram a => [a] -> ExceptT SomeException IO EvaluationResult
runPlcCek values = do
     ps <- traverse getProgram values
     let p = foldl1 applyProgram ps
     ExceptT $ try @SomeException $ evaluate $ evaluateCek p

runPlcCekTrace :: GetProgram a => [a] -> ExceptT SomeException IO ([String], EvaluationResult)
runPlcCekTrace values = do
     ps <- traverse getProgram values
     let p = foldl1 applyProgram ps
     ExceptT $ try @SomeException $ evaluate $ evaluateCekTrace p

goldenEvalCek :: GetProgram a => String -> [a] -> TestNested
goldenEvalCek name values = nestedGoldenVsDocM name $ prettyPlcClassicDebug <$> (rethrow $ runPlcCek values)

goldenEvalCekLog :: GetProgram a => String -> [a] -> TestNested
goldenEvalCekLog name values = nestedGoldenVsDocM name $ (pretty . fst) <$> (rethrow $ runPlcCekTrace values)

tests :: TestNested
tests = testGroup "plutus-th" <$> sequence [
    goldenPir "simple" simple
    , goldenPir "power" powerPlc
    , goldenPir "and" andPlc
    , goldenEvalCek "convertString" [convertString]
    , goldenEvalCekLog "traceDirect" [traceDirect]
    , goldenEvalCekLog "tracePrelude" [tracePrelude]
    , goldenEvalCekLog "traceRepeatedly" [traceRepeatedly]
  ]

simple :: CompiledCode (Bool -> Int)
simple = $$(compile [|| \(x::Bool) -> if x then (1::Int) else (2::Int) ||])

-- similar to the power example for Feldspar - should be completely unrolled at compile time
powerPlc :: CompiledCode (Int -> Int)
powerPlc = $$(compile [|| $$(power (4::Int)) ||])

andPlc :: CompiledCode Bool
andPlc = $$(compile [|| $$(andTH) True False ||])

convertString :: CompiledCode Builtins.String
convertString = $$(compile [|| $$(toPlutusString) "test" ||])

traceDirect :: CompiledCode ()
traceDirect = $$(compile [|| Builtins.trace ($$(toPlutusString) "test") ||])

tracePrelude :: CompiledCode Int
tracePrelude = $$(compile [|| $$(trace) ($$(toPlutusString) "test") (1::Int) ||])

traceRepeatedly :: CompiledCode Int
traceRepeatedly = $$(compile
     [||
               -- This will in fact print the third log first, and then the others, but this
               -- is the same behaviour as Debug.trace
               let i1 = $$(traceH) "Making my first int" (1::Int)
                   i2 = $$(traceH) "Making my second int" (2::Int)
                   i3 = $$(traceH) "Adding them up" (i1 + i2)
              in i3
    ||])
