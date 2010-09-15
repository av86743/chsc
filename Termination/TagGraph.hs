module Termination.TagGraph (
        -- * The TagGraph type
        TagGraph
        
        -- FIXME: the splitter will be broken with this type :(. Probably.
    ) where

import Termination.TagBag
import Termination.Terminate

import Evaluator.FreeVars
import Evaluator.Syntax

import Utilities

import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import qualified Data.Map as M
import qualified Data.Set as S


data TagGraph = TagGraph { vertices :: IM.IntMap Int, edges :: IM.IntMap IS.IntSet }
               deriving (Eq)

instance Pretty TagGraph where
    pPrint _tr = text "TagGraph (FIXME: pretty printer)" -- FIXME

instance TagCollection TagGraph where
    tr1 <| tr2 = tr1 `setEqual` tr2 && cardinality tr1 <= cardinality tr2
    
    growingTags tr1 tr2 = IM.keysSet (IM.filter (/= 0) (IM.mapMaybe id (combineIntMaps (const Nothing) Just (\i1 i2 -> Just (i2 - i1)) (vertices tr1) (vertices tr2))))
    
    stateTags (Heap h _, k, in_e@(_, e)) = pureHeapTagGraph h
                                             `plusTagGraph` stackTagGraph [focusedTermTag' e] k
                                             `plusTagGraph` mkTermTagGraph (focusedTermTag' e) in_e
      where
        pureHeapTagGraph :: PureHeap -> TagGraph
        pureHeapTagGraph h = plusTagGraphs [mkTagGraph [pureHeapBindingTag' e] (inFreeVars annedTermFreeVars in_e) | in_e@(_, e) <- M.elems h]
        
        stackTagGraph :: [Tag] -> Stack -> TagGraph
        stackTagGraph _         []     = emptyTagGraph
        stackTagGraph focus_tgs (kf:k) = emptyTagGraph { edges = IM.fromList [(kf_tg, IS.singleton focus_tg) | kf_tg <- kf_tgs, focus_tg <- focus_tgs] } -- Binding structure of the stack itself
                                            `plusTagGraph` mkTagGraph kf_tgs (snd (stackFrameFreeVars kf))                                               -- Binding structure of the stack referring to the heap. TODO: update frames?
                                            `plusTagGraph` stackTagGraph kf_tgs k                                                                        -- Recurse to deal with rest of the stack
          where kf_tgs = stackFrameTags' kf
        
        mkTermTagGraph e_tg in_e = mkTagGraph [e_tg] (inFreeVars annedTermFreeVars in_e)
        mkTagGraph e_tgs fvs = TagGraph { vertices = IM.unionsWith (+) [IM.singleton e_tg 1 | e_tg <- e_tgs], edges = M.foldWithKey go IM.empty h }
          where go x (_, e_heap) edges | x `S.notMember` fvs = edges
                                       | otherwise           = foldr (\e_tg edges -> IM.insertWith IS.union e_tg (IS.singleton (pureHeapBindingTag' e_heap)) edges) edges e_tgs


emptyTagGraph :: TagGraph
emptyTagGraph = TagGraph { vertices = IM.empty, edges = IM.empty }

plusTagGraph :: TagGraph -> TagGraph -> TagGraph
plusTagGraph tr1 tr2 = TagGraph { vertices = IM.unionWith (+) (vertices tr1) (vertices tr2), edges = IM.unionWith IS.union (edges tr1) (edges tr2) }

plusTagGraphs :: [TagGraph] -> TagGraph
plusTagGraphs trs = TagGraph { vertices = IM.unionsWith (+) (map vertices trs), edges = IM.unionsWith IS.union (map edges trs) }

cardinality :: TagGraph -> Int
cardinality = IM.fold (+) 0 . vertices

setEqual :: TagGraph -> TagGraph -> Bool
setEqual tr1 tr2 = IM.keysSet (vertices tr1) == IM.keysSet (vertices tr2) && edges tr1 == edges tr2
