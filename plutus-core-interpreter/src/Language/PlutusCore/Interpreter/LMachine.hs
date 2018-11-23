-- | The L machine
-- A lazy machine based on the L machine of Friedman et al. [Improving the Lazy Krivine Machine]
-- For more details see the document in plutus/docs/fomega/lazy-machine
-- The code here's closely based on the CEK machine implementation.

-- The main difference from the CEK machine is that we have a heap
-- containing closures containing evaluated/unevaluated function
-- arguments, and environments mapping variable IDs to heap locations.
-- To evaluate [M N], we save a closure C containing N and the current
-- environment in a stack frame, then evaluate M to get a value
-- (lambda/builtin) like \x.e and an environment env.  We retrieve the
-- argument closure C from the stack, generate a new heap location l,
-- bind C (unevaluated) to l in the heap, then evaluate e in
-- env[x->l].  When we come across a use of x inside e, we look up l
-- in the heap to get N (inside the closure C): if it's Evaluated then
-- we continue immediately, using N instead of x. Otherwise we place
-- an update marker on the stack and evaluate N to get a new closure
-- C' containing a value V (and a possibly new environment): by
-- this time we should be back at the update marker containing l, and
-- we store Evaluated C back in the heap at l, then continue
-- evaluating e.


module Language.PlutusCore.Interpreter.LMachine
    ( LMachineException
    , EvaluationResultF (EvaluationSuccess, EvaluationFailure)
    , EvaluationResult
    , evaluateL
    , runL
    ) where

import           Language.PlutusCore
import           Language.PlutusCore.Constant
import           Language.PlutusCore.View
import           PlutusPrelude

import           Control.Monad.Identity
import           Data.IntMap                  (IntMap)
import qualified Data.IntMap                  as IntMap

type Plain f = f TyName Name ()

-- Let's just throw exceptions for the time being: error handling is changeable at the moment
-- FIXME: use the existing PLC exception infrastructure
data LMachineException =
    LMachineException String (Plain Term)
  | LMachineStringException String
    deriving (Show, Typeable)

instance Exception LMachineException

-- | A term together with an enviroment mapping free variables to heap locations
data Closure = Closure
    { _closureValue       :: Plain Term
    , _closureEnvironment :: Environment
    } deriving (Show)

-- | L machine environments
-- Each entry is a mapping from the 'Unique' representing a variable to a heap location
newtype Environment = Environment (IntMap HeapLoc)
    deriving (Show)

-- | Heap location. Int should always be big enough: maxBound::Int is 2^63-1
type HeapLoc = Int

-- | Heap entries: unevaluated and evaluated lazy function arguments.
data HeapEntry =
    Evaluated   Closure  -- The term in this closure should always be a value. It would be good if the type system could distiniguish these.
  | Unevaluated Closure

-- | The heap itself: a map from heap locations to
-- unevaluated/evaluated terms, together with an integer counter
-- @_top@ which serves as the current heap location.
data Heap = Heap {
      _heap :: IntMap HeapEntry
    , _top  :: Int
}

{- Environments map variable ids to locations, the heap maps locations
   to terms.  We really do require this indirection: there may be
   multiple objects in the heap corresponding to the same variable
   (during recursion, for example).  For the same reason we always
   work with closures instead of terms; this also makes it easier
   to ensure that we're using the correct environment. -}


-- | Stack frames.  These are effectively continuations: would using explicit CPS speed things up?
-- The spec also has a frame for n-ary built in application, but that's not in the AST yet
data Frame
    = FrameAppArg Closure                        -- ^ @[_ N]@       -- Tells the machine that we've got back to N after evaluating M in [M N]
    | FrameHeapUpdate HeapLoc                    -- ^ @(update l)@  -- Mark the stack for evaluation of a delayed argument
    | FrameTyInstArg (Type TyName ())            -- ^ @{_ A}@
    | FrameUnwrap                                -- ^ @(unwrap _)@
    | FrameWrap () (TyName ()) (Type TyName ())  -- ^ @(wrap α A _)@
      deriving (Show)

-- | A context is a stack of frames.
type EvaluationContext = [Frame]

-- | A local version of the EvaluationResult type using closures instead of values
data LMachineResult
    = Success Closure Heap  -- We need both the environment and the heap to see what the value "really" is.
    | Failure

emptyEnvironment :: Environment
emptyEnvironment = Environment IntMap.empty

-- | Extend an environment with a new binding
updateEnvironment :: Int -> HeapLoc -> Environment -> Environment
updateEnvironment index cl (Environment m) = Environment (IntMap.insert index cl m)

-- | Look up a heap location in an environment.
lookupHeapLoc :: Name () -> Environment -> HeapLoc
lookupHeapLoc name (Environment env) =
    case IntMap.lookup (unUnique $ nameUnique name) env of
      Nothing  -> throw $ LMachineStringException ("Name " ++ show (nameString name) ++ " missing from environment")
      Just loc -> loc

emptyHeap :: Heap
emptyHeap = Heap IntMap.empty 0

-- | Insert a new entry into a heap. The heap grows monotonically with no garbage collection or reuse of heap slots.
insertInHeap :: Closure -> Heap -> (HeapLoc, Heap)
insertInHeap cl (Heap h top) =
    let top' = top + 1
    in (top', Heap (IntMap.insert top' (Unevaluated cl) h) top')

-- | Replace the heap entry at a given location.
-- The old entry presumably persits in the old heap.
updateHeap :: HeapLoc -> HeapEntry -> Heap -> Heap
updateHeap l cl (Heap h top) =
    Heap (IntMap.insert l cl h) top
    -- insert seems to be faster than adjust (18s vs 28 s for fib 32) and also uses less memory.

lookupHeap :: HeapLoc -> Heap -> HeapEntry
lookupHeap l (Heap h _) =
    case IntMap.lookup l h of
      Just e  -> e
      Nothing -> throw $ LMachineStringException ("Missing heap location in lookupHeap: " ++ show l)  -- This should never happen


-- | The basic computation step of the L machine.  Search down the AST looking for a value, saving surrounding contexts on the stack.
computeL :: EvaluationContext -> Heap -> Closure -> LMachineResult
computeL ctx heap cl@(Closure term env) =
    case term of
      TyInst _ fun ty       -> computeL (FrameTyInstArg ty : ctx)                 heap (Closure fun env)
      Apply _ fun arg       -> computeL (FrameAppArg (Closure arg env) : ctx)     heap (Closure fun env)
      Wrap ann tyn ty term' -> computeL (FrameWrap ann tyn ty : ctx)              heap (Closure term' env)
      Unwrap _ term'        -> computeL (FrameUnwrap : ctx)                       heap (Closure term' env)
      TyAbs{}               -> returnL  ctx heap cl
      LamAbs{}              -> returnL  ctx heap cl
      Builtin{}             -> returnL  ctx heap cl
      Constant{}            -> returnL  ctx heap cl
      Error{}               -> Failure
      Var _ name            -> let l = lookupHeapLoc name env
                               in case lookupHeap l heap of
                                    Evaluated cl'   -> returnL ctx heap cl'
                                    Unevaluated cl' -> computeL (FrameHeapUpdate l : ctx) heap cl'


-- | Return a closure containing a value. Ideally the fact that we've
-- got a value would be enforced in the (Haskell) type. Values still
-- have to be contained in closures.  We could have something like
-- @v= \x.y@, where @y@ is bound in an environment.  If we ever go on
-- to apply @v@, we'll need the value of @y@.
returnL :: EvaluationContext -> Heap -> Closure -> LMachineResult
returnL [] heap res                                                        = Success res heap
returnL (FrameTyInstArg ty        : ctx) heap cl                           = instantiateEvaluate ctx heap ty cl
returnL (FrameAppArg argClosure   : ctx) heap cl                           = evaluateFun ctx heap cl argClosure
returnL (FrameWrap ann tyn ty     : ctx) heap (Closure v env)              = returnL ctx heap $ Closure (Wrap ann tyn ty v) env
returnL (FrameHeapUpdate l        : ctx) heap cl                           = returnL ctx heap' cl
                                                                                   where heap' = updateHeap l (Evaluated cl) heap
                                                                                      -- Leave this out to make the machine call-by-name (really slow)
returnL (FrameUnwrap              : ctx) heap (Closure (Wrap _ _ _ t) env) = returnL ctx heap (Closure t env)
returnL (FrameUnwrap              : _)      _ (Closure term _)             = throw $ LMachineException "Attemtping to unwrap non-wrapped term" term


-- | Apply a function to an argument and proceed.
-- If the function is a 'LamAbs', then extend the current environment with a new variable and proceed.
-- If the function is not a 'LamAbs', then 'Apply' it to the argument and view this
-- as an iterated application of a 'BuiltinName' to a list of 'Value's.
-- If succesful, proceed with either this same term or with the result of the computation
-- depending on whether 'BuiltinName' is saturated or not.

evaluateFun :: EvaluationContext -> Heap -> Closure -> Closure-> LMachineResult
evaluateFun ctx heap (Closure fun funEnv) argClosure =
    case fun of
      LamAbs _ var _ body ->
          let (l, heap') = insertInHeap argClosure heap
              env' = updateEnvironment (unUnique $ nameUnique var) l funEnv
          in  computeL ctx heap' (Closure body env')

      _ ->
          -- Not a lambda: look for evaluation of a built-in function, possibly with some args already supplied.
          -- We have to force the arguments, which means that we need to get the new heap back as well.
          -- This bit is messy but should be much easier when we have n-ary application for builtins.
          case computeL [] heap argClosure of
            -- Force the argument, but only at the top level.
            -- This is a bit of a hack.  We're not in the main compute/return process here.
            -- We're preserving ctx, the context at entry, and we'll use that when we return.
            -- We could also add a new type of stack frame for this.  Exactly what we do will
            -- depend on the final interface to builtins.
            Failure -> Failure
            Success (Closure arg' env') heap' ->
                let term = Apply () fun arg'
                in case termAsPrimIterApp term of
                     Nothing ->
                         throw $ LMachineException "Trying to apply invalid term" term
                         -- Was "Cannot reduce a not immediately reducible application."  This message isn't very helpful.
                     Just (IterApp (StaticStagedBuiltinName name) spine) ->
                         case applyEvaluateBuiltinName heap' env' name spine of
                           ConstAppSuccess term' -> returnL ctx heap' (Closure term' funEnv)
                           ConstAppStuck         -> returnL ctx heap' (Closure term  funEnv)
                           -- It's arguable what the env should be here. That depends on what the built-in can return.
                           -- Ideally it'd always return a closed term, so the environment should be irrelevant.
                           ConstAppFailure       -> Failure
                           ConstAppError _err    -> throw $ LMachineException "ConstAppError" term

                     Just (IterApp DynamicStagedBuiltinName{}     _    ) ->
                         throw $ LMachineException "Dynamic builtins not supported yet" term


-- | This is a workaround (thanks to Roman) to get things working while the dynamic builtins interface is under development.
applyEvaluateBuiltinName :: Heap -> Environment -> BuiltinName -> [Value TyName Name ()] -> ConstAppResult
applyEvaluateBuiltinName heap env name =
    runIdentity . runEvaluate (const $ Identity . evalL heap env) . runQuoteT . applyBuiltinName name

evalL :: Heap -> Environment -> Plain Term -> EvaluationResult
evalL heap env term = translateResult $ computeL [] heap (Closure term env)
-- I'm not sure if this is doing quite the right thing.  The current
-- strategy of the dynamic interface is that it when you're evaluating
-- a builtin, you also pass the current PLC evaluator along with its
-- state so that the builtin can evaluate terms properly (for example,
-- it may need to look up a variable in an environment).  It's
-- possible that this could update the heap, but in this case we're
-- not getting the new heap back.  I think this is harmless, but
-- perhaps inefficient (we may have to re-evaluate something that
-- we've already evaluated).  We could solve this by putting the heap
-- in a suitable monad, but let's wait until the interface has
-- stabilised first.  I think the version above is OK for simple
-- builtins for the time being.


-- | Instantiate a term with a type and proceed.
-- In case of 'TyAbs' just ignore the type. Otherwise check if the term is an
-- iterated application of a 'BuiltinName' to a list of 'Value's and, if succesful,
-- apply the term to the type via 'TyInst'.
instantiateEvaluate :: EvaluationContext -> Heap -> Type TyName () -> Closure -> LMachineResult
instantiateEvaluate ctx heap ty (Closure fun env) =
    case fun of
      TyAbs _ _ _ body ->
          computeL ctx heap (Closure body env)
      _ -> if isJust $ termAsPrimIterApp fun
           then returnL ctx heap $ Closure (TyInst () fun ty) env
           else throw $ LMachineException "Attempting to instantiate invalid term" fun

-- | Evaluate a term using the L machine. This internal version
-- returns a result containing the final heap and environment, which
-- it mightbe useful to know (for example, if we're testing we might
-- want to know how big the heap is.  Also, if we want to return a
-- value to whatever has invoked the machine we may want to fully
-- expand it, and you'd need the environment and heap to do that.
internalEvaluateL :: Term TyName Name () -> LMachineResult
internalEvaluateL t = computeL [] emptyHeap (Closure t emptyEnvironment)


-- | Convert an L machine result into the standard result type for communication with the outside world.
translateResult :: LMachineResult -> EvaluationResult
translateResult r = case r of
      Success (Closure t _) (Heap _ _) -> EvaluationSuccess t
      Failure                          -> EvaluationFailure

-- | Evaluate a term using the L machine. May throw an 'LMachineException'.
evaluateL :: Term TyName Name () -> EvaluationResult
evaluateL term = translateResult $  internalEvaluateL term

-- | Run a program using the L machine. May throw a 'MachineException'.
-- We're not using the dynamic names at the moment, but we'll require them eventually
-- I'm catching the errors here because the CI thing generates deliberately failing
-- programs and doesn't like exceptions.  I wasn't aware of this, so let's just
-- catch the exceptions and ignore them.
runL :: DynamicBuiltinNameMeanings -> Program TyName Name () -> EvaluationResult
runL _ (Program _ _ term) = evaluateL term
