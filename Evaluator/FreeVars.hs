{-# LANGUAGE GeneralizedNewtypeDeriving, PatternGuards, NoMonoLocalBinds #-}
module Evaluator.FreeVars (
    inFreeVars,
    heapBindingFreeVars,
    pureHeapBoundVars, stackBoundVars, stackFrameBoundVars, stackFrameFreeVars,
    pureHeapVars, stateFreeVars, stateAllFreeVars, stateLetBounders, stateLambdaBounders, stateInternalBounders, stateUncoveredVars
  ) where

import Evaluator.Deeds
import Evaluator.Syntax

import Core.FreeVars
import Core.Renaming

import Utilities

import qualified Data.Map as M
import qualified Data.Set as S


inFreeVars :: (a -> FreeVars) -> In a -> FreeVars
inFreeVars thing_fvs (rn, thing) = renameFreeVars rn (thing_fvs thing)

-- | Finds the set of things "referenced" by a 'HeapBinding': this is only used to construct tag-graphs
heapBindingFreeVars :: HeapBinding -> FreeVars
heapBindingFreeVars = maybe S.empty (inFreeVars annedTermFreeVars) . heapBindingTerm

-- | Returns all the variables bound by the heap that we might have to residualise in the splitter
pureHeapBoundVars :: PureHeap -> BoundVars
pureHeapBoundVars = M.keysSet -- I think its harmless to include variables bound by phantoms in this set

-- | Returns all the variables bound by the stack that we might have to residualise in the splitter
stackBoundVars :: Stack -> BoundVars
stackBoundVars = S.unions . map (stackFrameBoundVars . tagee)

stackFrameBoundVars :: StackFrame -> BoundVars
stackFrameBoundVars = fst . stackFrameOpenFreeVars

stackFrameFreeVars :: StackFrame -> FreeVars
stackFrameFreeVars = snd . stackFrameOpenFreeVars

stackFrameOpenFreeVars :: StackFrame -> (BoundVars, FreeVars)
stackFrameOpenFreeVars kf = case kf of
    Apply x'                -> (S.empty, S.singleton x')
    Scrutinise in_alts      -> (S.empty, inFreeVars annedAltsFreeVars in_alts)
    PrimApply _ in_vs in_es -> (S.empty, S.unions (map (inFreeVars annedValueFreeVars) in_vs) `S.union` S.unions (map (inFreeVars annedTermFreeVars) in_es))
    Update x'               -> (S.singleton x', S.empty)


-- | Computes the variables bound and free in a state
stateVars :: (Deeds, Heap, Stack, In (Anned a)) -> (HowBound -> BoundVars, FreeVars)
pureHeapVars :: PureHeap -> (HowBound -> BoundVars, FreeVars)
(stateVars, pureHeapVars) = (\(_, Heap h _, k, in_e) -> finish $ pureHeapOpenFreeVars h (stackOpenFreeVars k (inFreeVars annedFreeVars in_e)),
                             \h -> finish $ pureHeapOpenFreeVars h (S.empty, S.empty))
  where
    finish ((bvs_internal, bvs_lambda, bvs_let), fvs) = (\how -> case how of InternallyBound -> bvs_internal; LambdaBound -> bvs_lambda; LetBound -> bvs_let, fvs)
    
    pureHeapOpenFreeVars :: PureHeap -> (BoundVars, FreeVars) -> ((BoundVars, BoundVars, BoundVars), FreeVars)
    pureHeapOpenFreeVars h (bvs_internal, fvs) = (\f -> M.foldrWithKey f ((bvs_internal, S.empty, S.empty), fvs) h) $ \x' hb ((bvs_internal, bvs_lambda, bvs_let), fvs) -> (case howBound hb of
        InternallyBound -> (S.insert x' bvs_internal, bvs_lambda, bvs_let)
        LambdaBound     -> (bvs_internal, S.insert x' bvs_lambda, bvs_let)
        LetBound        -> (bvs_internal, bvs_lambda, S.insert x' bvs_let),
        fvs `S.union` heapBindingFreeVars hb)
    
    stackOpenFreeVars :: Stack -> FreeVars -> (BoundVars, FreeVars)
    stackOpenFreeVars k fvs = (S.unions *** (S.union fvs . S.unions)) . unzip . map (stackFrameOpenFreeVars . tagee) $ k


-- | Returns (an overapproximation of) the free variables that the state would have if it were residualised right now (i.e. variables bound by phantom bindings *are* in the free vars set)
stateFreeVars :: (Deeds, Heap, Stack, In (Anned a)) -> FreeVars
stateFreeVars s = fvs S.\\ bvs InternallyBound
  where (bvs, fvs) = stateVars s

stateAllFreeVars :: (Deeds, Heap, Stack, In (Anned a)) -> FreeVars
stateAllFreeVars = snd . stateVars

stateLetBounders :: (Deeds, Heap, Stack, In (Anned a)) -> BoundVars
stateLetBounders = ($ LetBound) . fst . stateVars

stateLambdaBounders :: (Deeds, Heap, Stack, In (Anned a)) -> BoundVars
stateLambdaBounders = ($ LambdaBound) . fst . stateVars

stateInternalBounders :: (Deeds, Heap, Stack, In (Anned a)) -> BoundVars
stateInternalBounders = ($ InternallyBound) . fst . stateVars

stateUncoveredVars :: (Deeds, Heap, Stack, In (Anned a)) -> FreeVars
stateUncoveredVars s = fvs S.\\ bvs InternallyBound S.\\ bvs LetBound S.\\ bvs LambdaBound
  where (bvs, fvs) = stateVars s
