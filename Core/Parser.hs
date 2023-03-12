{-# LANGUAGE PatternGuards, TupleSections, ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
module Core.Parser (parse) where

import Core.Data
import Core.Syntax
import Core.Prelude

import Name hiding (freshName)
import qualified Name
import StaticFlags
import Utilities

import qualified Data.Map as M

import qualified Language.Haskell.Exts as LHE
import Language.Preprocessor.Cpphs

import System.Directory
import System.FilePath (replaceExtension)


parse :: FilePath -> IO (String, [(Var, Term)])
parse path = do
    -- Read and pre-process .core file
    contents <- readFile path >>= cpp
    unless qUIET $ putStrLn contents
    
    -- Read and pre-process corresponding .hs file (if any)
    let wrapper_path = replaceExtension path ".hs"
    has_wrapper <- doesFileExist wrapper_path
    wrapper <- if has_wrapper then readFile wrapper_path >>= cpp else return ""
    
    -- Return parsed .core file
    return (wrapper, moduleCore . LHE.fromParseResult . LHE.parseFileContentsWithMode (LHE.defaultParseMode { LHE.parseFilename = path, LHE.extensions =
      [LHE.EnableExtension LHE.CPP, LHE.EnableExtension LHE.MagicHash] }) $ contents)
  where cpp = runCpphs (defaultCpphsOptions { boolopts = (boolopts defaultCpphsOptions) { locations = False }, defines = ("SUPERCOMPILE", "1") : defines defaultCpphsOptions }) path


-- | Descriptions of terms: used for building readable names for ANF-introduced variables
data Description = Opaque String | ArgumentOf Description

descriptionString :: Description -> String
descriptionString = go (0 :: Int)
  where
    go n (Opaque s)     = s ++ (if n > 0 then show n else "")
    go n (ArgumentOf d) = go (n + 1) d

desc :: Term -> Description
desc = desc' . unI

desc' :: TermF Identity -> Description
desc' (Var x)         = Opaque (name_string x)
desc' (Value _)       = Opaque "value"
desc' (App e1 _)      = argOf (desc e1)
desc' (PrimOp pop es) = foldr (\_ d -> argOf d) (Opaque (show pop)) es
desc' (Case _ _)      = Opaque "case"
desc' (LetRec _ e)    = desc e

argOf :: Description -> Description
argOf = ArgumentOf


data ParseState = ParseState {
    ids :: IdSupply,
    dcWrappers :: M.Map DataCon Var,
    intWrappers :: M.Map Integer Var,
    charWrappers :: M.Map Char Var,
    primWrappers :: M.Map PrimOp Var
  }

initParseState :: ParseState
initParseState = ParseState {
    ids = parseIdSupply,
    dcWrappers = M.empty,
    intWrappers = M.empty,
    charWrappers = M.empty,
    primWrappers = M.empty
  }

buildWrappers :: ParseState -> [(Var, Term)]
buildWrappers ps
  = [ (f, lambdas xs $ data_ dc xs)
    | (dc, f) <- M.toList (dcWrappers ps)
    , let arity = dataConArity dc; xs = map (\i -> name $ 'x' : show i) [1..arity] ] ++
    [ (f, int i)
    | (i, f) <- M.toList (intWrappers ps) ] ++
    [ (f, char c)
    | (c, f) <- M.toList (charWrappers ps) ] ++
    [ (f, lam (name "x1") $ lam (name "x2") $ primOp pop [var (name "x1"), var (name "x2")])
    | (pop, f) <- M.toList (primWrappers ps) ] ++
    [ (name "error", lam (name "msg") $ scrutinise (var (name "prelude_error") `app` name "msg") []) ] ++
    [ (name "uncoveredBranch", scrutinise (var (name "bAD")) []) ]

newtype ParseM a = ParseM { unParseM :: ParseState -> (ParseState, [(Var, Term)], a) }

instance Functor ParseM where
    fmap = liftM

instance Applicative ParseM where
  pure = return
  (<*>) = ap

instance Monad ParseM where
    return x = ParseM $ \s -> (s, [], x)
    mx >>= fxmy = ParseM $ \s -> case unParseM mx s of (s, floats1, x) -> case unParseM (fxmy x) s of (s, floats2, y) -> (s, floats1 ++ floats2, y)

freshName :: String -> ParseM Name
freshName n = ParseM $ \s -> let (ids', x) = Name.freshName (ids s) n in (s { ids = ids' }, [], x)

freshFloatName :: String -> Term -> ParseM (Maybe (Var, Term), Name)
freshFloatName _ (I (Var x)) = return (Nothing, x)
freshFloatName n e           = freshName n >>= \x -> return (Just (x, e), x)

float :: [(Var, Term)] -> ParseM ()
float floats = ParseM $ \s -> (s, floats, ())

nameIt :: Description -> Term -> ParseM Var
nameIt d e = freshFloatName ("a" ++ descriptionString d) e >>= \(mb_float, x) -> float (maybeToList mb_float) >> return x

bindFloats :: ParseM Term -> ParseM Term
bindFloats = bindFloatsWith . fmap ([],)

bindFloatsWith :: ParseM ([(Var, Term)], Term) -> ParseM Term
bindFloatsWith act = ParseM $ \s -> case unParseM act s of (s, floats, (xes, e)) -> (s, [], bind (xes ++ floats) e)

tupleCore :: [Term] -> ParseM Term
tupleCore es = case tupleDataCon (length es) of Nothing -> return (expectHead "tupleCore" es); Just dc -> dataConCore dc es

listCore :: [Term] -> ParseM Term
listCore es = nilCore >>= \e_nil -> foldrM consCore e_nil es
  where
    foldrM :: Monad m => (a -> b -> m b) -> b -> [a] -> m b
    foldrM c n xs = foldM (flip c) n (reverse xs)

nilCore :: ParseM Term
nilCore = dataConCore nilDataCon []

consCore :: Term -> Term -> ParseM Term
consCore e1 e2 = dataConCore consDataCon [e1, e2]

dataConCore :: DataCon -> [Term] -> ParseM Term
dataConCore dc es = dataConWrapper dc >>= \wrap -> foldM appE (var wrap) es

charCore :: Char -> ParseM Term
charCore c = fmap var $ charWrapper c

stringCore :: String -> ParseM Term
stringCore s = mapM charCore s >>= listCore

appE :: Term -> Term -> ParseM Term
appE e1 e2 = nameIt (argOf (desc e1)) e2 >>= \x2 -> return (e1 `app` x2)

dataConWrapper :: DataCon -> ParseM Var
dataConWrapper = grabWrapper dcWrappers (\s x -> s { dcWrappers = x }) (\dc -> dataConFriendlyName dc `orElse` dc)

intWrapper :: Integer -> ParseM Var
intWrapper = grabWrapper intWrappers (\s x -> s { intWrappers = x }) show

charWrapper :: Char -> ParseM Var
charWrapper = grabWrapper charWrappers (\s x -> s { charWrappers = x }) return

primWrapper :: PrimOp -> ParseM Var
primWrapper = grabWrapper primWrappers (\s x -> s { primWrappers = x }) show

grabWrapper :: Ord a
            => (ParseState -> M.Map a Var) -> (ParseState -> M.Map a Var -> ParseState)
            -> (a -> String) -- For building human readable names for the wrapper invocations only
            -> a -> ParseM Var
grabWrapper get set describe what = do
    mb_x <- ParseM $ \s -> (s, [], M.lookup what (get s))
    case mb_x of Just x -> return x
                 Nothing -> freshName ("w" ++ describe what) >>= \x -> ParseM $ \s -> (set s (M.insert what x (get s)), [], x)

runParseM :: ParseM a -> ([(Var, Term)], a)
runParseM act = (buildWrappers s ++ floats, x)
  where
    (s, floats, x) = unParseM act initParseState


moduleCore :: LHE.Module LHE.SrcSpanInfo -> [(Var, Term)]
moduleCore (LHE.Module _loc _name _ops _imports decls) = wrap_xes ++ xes
  where (wrap_xes, xes) = runParseM $ declsCore decls


declsCore :: [LHE.Decl LHE.SrcSpanInfo] -> ParseM [(Name, Term)]
declsCore = fmap concat . mapM declCore

declCore :: LHE.Decl LHE.SrcSpanInfo -> ParseM [(Name, Term)]
declCore (LHE.FunBind _l [LHE.Match _loc n pats (LHE.UnGuardedRhs _l' e) _binds@(Just ( LHE.BDecls _l'' where_decls) )]) = do
    let x = name (nameString n)
    (ys, _bound_ns, build) <- patCores pats
    e <- bindFloatsWith $ liftM2 (,) (declsCore where_decls) (expCore e)
    return [(x, lambdas ys $ build e)]
declCore (LHE.PatBind _loc pat (LHE.UnGuardedRhs _l e) _binds@(Just (LHE.BDecls _l'' where_decls))) = do
    (x, bound_ns, build) <- patCore pat
    e <- bindFloatsWith $ liftM2 (,) (declsCore where_decls) (expCore e)
    return $ (x, e) : [(n, build (var n)) | n <- bound_ns, n /= x]
declCore d@(LHE.FunBind _l [LHE.Match _loc n pats (LHE.UnGuardedRhs _l' e) Nothing]) =
  declCore (LHE.FunBind _l [LHE.Match _loc n pats (LHE.UnGuardedRhs _l' e)
    (Just (LHE.BDecls _l [])) ])
declCore (LHE.PatBind _loc pat (LHE.UnGuardedRhs _l e) Nothing) =
  declCore (LHE.PatBind _loc pat (LHE.UnGuardedRhs _l e) (Just (LHE.BDecls _l [])))
declCore td@(LHE.TypeDecl _l _declhead _type) =
      (return [])
declCore dd@(LHE.DataDecl _l _dn _c _dh _ls _der) =
      (return [])
declCore id@(LHE.InstDecl _l _overlap _rule _ids) =
      (return [])
declCore ts@(LHE.TypeSig _l _names _t) =
      (return [])
declCore d = panic "declCore" (text $ LHE.prettyPrint d ++ show d)


expCore :: LHE.Exp LHE.SrcSpanInfo -> ParseM Term
expCore (LHE.Var _l qname) = qNameCore qname
expCore (LHE.Con _l qname) = fmap var $ dataConWrapper $ qNameDataCon qname
expCore (LHE.Lit _l lit) = literalCore lit
expCore (LHE.NegApp _l e) = expCore $ LHE.App _l (LHE.Var _l (LHE.UnQual _l (LHE.Ident _l "negate"))) e
expCore (LHE.App _l e1 e2) = expCore e1 >>= \e1 -> expCore e2 >>= appE e1
expCore (LHE.InfixApp _l e1 eop e2) = qopCore eop >>= \eop -> expCore e1 >>= \e1 -> nameIt (argOf (desc eop)) e1 >>= \x1 -> expCore e2 >>= \e2 -> nameIt (argOf (argOf (desc eop))) e2 >>= \x2 -> return $ apps eop [x1, x2]
expCore (LHE.Let _l (LHE.BDecls _l' binds) e) = bindFloatsWith $ liftM2 (,) (declsCore binds) (expCore e)
expCore (LHE.If _l e1 e2 e3) = expCore e1 >>= \e1 -> liftM2 (if_ e1) (expCore e2) (expCore e3)
expCore (LHE.Case _l e alts) = expCore e >>= \e -> fmap (scrutinise e) (mapM altCore alts)
expCore (LHE.Tuple _l _boxed es) = mapM expCore es >>= tupleCore
expCore (LHE.Paren _l e) = expCore e
expCore (LHE.List _l es) = mapM expCore es >>= listCore
expCore (LHE.Lambda _ ps e) = patCores ps >>= \(xs, _bound_xs, build) -> fmap (lambdas xs) $ bindFloats $ fmap build (expCore e)
expCore (LHE.LeftSection _l e1 eop) = qopCore eop >>= \eop -> expCore e1 >>= \e1 -> nameIt (argOf (desc eop)) e1 >>= \x1 -> return (eop `app` x1)
expCore (LHE.RightSection _l eop e2) = qopCore eop >>= \eop -> nameIt (desc eop) eop >>= \xop -> expCore e2 >>= \e2 -> nameIt (argOf (argOf (desc eop))) e2 >>= \x2 -> freshName "rsect" >>= \x1 -> return $ lambda x1 $ (var xop `app` x1) `app` x2  -- NB: careful about sharing!
expCore (LHE.EnumFromTo _l e1 e2) = expCore $ LHE.App _l (LHE.App _l (LHE.Var _l (LHE.UnQual _l (LHE.Ident _l "enumFromTo"))) e1) e2
expCore (LHE.EnumFromThen _l e1 e2) = expCore $ LHE.App _l (LHE.App _l (LHE.Var _l (LHE.UnQual _l (LHE.Ident _l "enumFromThen"))) e1) e2
expCore (LHE.EnumFromThenTo _l e1 e2 e3) = expCore $ LHE.App _l (LHE.App _l (LHE.App _l (LHE.Var _l (LHE.UnQual _l (LHE.Ident _l "enumFromThenTo"))) e1) e2) e3
expCore (LHE.ListComp _l e quals) = listCompCore e [case qual of LHE.QualStmt _l' stmt -> stmt | qual <- quals]
expCore e = panic "expCore" (text $ show e)

qopCore :: LHE.QOp LHE.SrcSpanInfo -> ParseM Term
qopCore (LHE.QVarOp _l qn) = qNameCore qn
qopCore (LHE.QConOp _l qn) = qNameCore qn

literalCore :: LHE.Literal LHE.SrcSpanInfo -> ParseM Term
literalCore (LHE.Int _l i _s) = fmap var $ intWrapper i
literalCore (LHE.Char _l c _s) = charCore c
literalCore (LHE.String _l s _s) = stringCore s

altCore :: LHE.Alt LHE.SrcSpanInfo -> ParseM Alt
altCore (LHE.Alt _loc pat (LHE.UnGuardedRhs _l e) (Just (LHE.BDecls _l' binds))) = do
    (altcon, build) <- altPatCore pat
    e <- bindFloatsWith $ liftM2 (,) (declsCore binds) (expCore e)
    return (altcon, build e)
altCore (LHE.Alt _loc pat (LHE.UnGuardedRhs _l e) Nothing) =
  altCore (LHE.Alt _loc pat (LHE.UnGuardedRhs _l e) (Just (LHE.BDecls _l [])))
altCore p = panic "altCore" (text $ show p)

-- | For irrefutible pattern matches a single level deep, where we need to make a choice based on the outer constructor *only*:
altPatCore :: LHE.Pat LHE.SrcSpanInfo -> ParseM (AltCon, Term -> Term)
altPatCore (LHE.PApp _l qname pats)           = liftM (dataAlt (qNameDataCon qname)) (patCores pats)
altPatCore (LHE.PInfixApp _l pat1 qname pat2) = liftM (dataAlt (qNameDataCon qname)) (patCores [pat1, pat2])
altPatCore (LHE.PTuple _l _boxed [pat1, pat2])       = liftM (dataAlt pairDataCon) (patCores [pat1, pat2])
altPatCore (LHE.PParen _l pat)                = altPatCore pat
altPatCore (LHE.PList _l [])                  = return $ dataAlt nilDataCon ([], [], id)
altPatCore (LHE.PLit _l _sign (LHE.Int _l' i _s))          = return (LiteralAlt (Int i), id)
altPatCore (LHE.PLit _l _sign (LHE.Char _l' c _s))         = return (LiteralAlt (Char c), id)
altPatCore (LHE.PVar _l x)                    = return (DefaultAlt (Just (name (nameString x))), id) -- TODO: this is not quite right, because case on variable is not
altPatCore (LHE.PWildCard _l)                   = return (DefaultAlt Nothing, id)                      -- strict in Haskell. But the standard library depends on it being so...
altPatCore p = panic "altPatCore" (text $ show p)

dataAlt :: DataCon -> ([Var], [Var], Term -> Term) -> (AltCon, Term -> Term)
dataAlt dcon (names, _bound_ns, build) = (DataAlt dcon names, build)

listCompCore :: LHE.Exp LHE.SrcSpanInfo -> [LHE.Stmt LHE.SrcSpanInfo] -> ParseM Term
listCompCore e_inner stmts = go stmts
  where
    go [] = expCore e_inner >>= \e_inner -> listCore [e_inner]
    go (stmt:stmts) = case stmt of
        -- concatMap (\pat -> [[go stmts]]) e
        LHE.Generator _loc pat e -> do
            (x, _bound_xs, build) <- patCore pat
            arg1 <- liftM (lambda x . build) $ bindFloats $ go stmts
            arg2 <- expCore e
            var (name "concatMap") `appE` arg1 >>= (`appE` arg2)
        -- if e then [[go stmts]] else []
        LHE.Qualifier _l e -> liftM3 if_ (expCore e) (go stmts) (listCore [])
        -- let [[binds]] in [[go stmts]]
        LHE.LetStmt _l (LHE.BDecls _l' binds) -> bindFloatsWith $ liftM2 (,) (declsCore binds) (go stmts)


specialConDataCon :: LHE.SpecialCon LHE.SrcSpanInfo -> DataCon
specialConDataCon (LHE.UnitCon _l) = unitDataCon
specialConDataCon (LHE.ListCon _l) = nilDataCon
specialConDataCon (LHE.TupleCon _l LHE.Boxed 2) = pairDataCon
specialConDataCon (LHE.Cons _l) = consDataCon

nameString :: LHE.Name LHE.SrcSpanInfo -> String
nameString (LHE.Ident _l s)  = s
nameString (LHE.Symbol _l s) = s

qNameCore :: LHE.QName LHE.SrcSpanInfo -> ParseM Term
qNameCore (LHE.UnQual _l n) = fmap var $ case nameString n of -- TODO: this is a hack. What if I locally rebind one of these names?
    "+"   -> primWrapper Add
    "-"   -> primWrapper Subtract
    "*"   -> primWrapper Multiply
    "div" -> primWrapper Divide
    "mod" -> primWrapper Modulo
    "=="  -> primWrapper Equal
    "<"   -> primWrapper LessThan
    "<="  -> primWrapper LessThanEqual
    s -> return (name s)
qNameCore (LHE.Special _l sc) = fmap var $ dataConWrapper $ specialConDataCon sc
qNameCore qn = panic "qNameCore" (text $ show qn)

qNameDataCon :: LHE.QName LHE.SrcSpanInfo -> DataCon
qNameDataCon (LHE.UnQual _l n)   = nameString n
qNameDataCon (LHE.Special _l sc) = specialConDataCon sc

patCores :: [LHE.Pat LHE.SrcSpanInfo] -> ParseM ([Var], [Var], Term -> Term)
patCores []     = return ([], [], id)
patCores (p:ps) = do
    (n', bound_ns', build) <- patCore p
    (ns', bound_nss', build') <- patCores ps
    return (n':ns', bound_ns' ++ bound_nss', build . build')

-- | For refutable and irrefutable pattern matches where there is only a single alternative so constructors can be nested
patCore :: LHE.Pat LHE.SrcSpanInfo             -- Pattern
        -> ParseM (Var,          -- Name consumed by the pattern
                   [Var],        -- Names bound by the pattern
                   Term -> Term) -- How to build the (strict) consuming context around the thing inside the pattern
patCore (LHE.PVar _l n)    = return (x, [x], id)
  where x = name (nameString n)
patCore (LHE.PWildCard _l)   = fmap (\x -> (x, [x], id)) $ freshName "_"
patCore (LHE.PParen _l p)  = patCore p
patCore (LHE.PTuple _l _boxed ps) = case tupleDataCon (length ps) of
    Nothing | [p] <- ps -> patCore p
    Just dc -> tuplePatCore dc ps
patCore (LHE.PApp _l (LHE.Special _l' (LHE.UnitCon _l'')) []) = tuplePatCore unitDataCon []
patCore (LHE.PInfixApp _l p1 qinfix p2) = do
    n' <- freshName "infx"
    (n1', bound_ns1, build1) <- patCore p1
    (n2', bound_ns2, build2) <- patCore p2
    return (n', bound_ns1 ++ bound_ns2, \e -> scrutinise (var n') [(DataAlt (qNameDataCon qinfix) [n1', n2'], build1 (build2 e))])
patCore p = panic "patCore" (text $ show p)

tuplePatCore :: DataCon -> [LHE.Pat LHE.SrcSpanInfo] -> ParseM (Var, [Var], Term -> Term)
tuplePatCore dc ps = do
    (ns', bound_ns', build) <- patCores ps
    freshName "tup" >>= \n' -> return (n', bound_ns', \e -> scrutinise (var n') [(DataAlt dc ns', build e)])

bind :: [(Var, Term)] -> Term -> Term
bind = letRecSmart

scrutinise :: Term -> [(AltCon, Term)] -> Term
scrutinise e alts = case_ e expanded_alts
  where
    expanded_alts :: [(AltCon, Term)]
    expanded_alts = fromMaybe alts $ do
        -- We can only expand cases if we can guess the other members of the family (we have no type information)
        let covered_dcs = [dc | (DataAlt dc _xs, _e) <- alts]
        siblings <- listToMaybe $ map dataConSiblings covered_dcs
        let uncovered_siblings = [ (dc, xs)
                                 | (dc, arity) <- siblings
                                 , dc `notElem` covered_dcs
                                   -- We replace the arity with a list of names to which to bind the sibling.
                                   -- NB: use supply of totally fresh names to avoid introducing shadowing
                                 , let xs = snd $ freshNames expandIdSupply (replicate arity "xpand")
                                 ]
        
        let (def_alts, other_alts) = extractJusts (\alt -> do { (DefaultAlt mb_x, e) <- Just alt; return (mb_x, e) }) alts
        fmap (other_alts ++) $ case def_alts of
            -- We only need to expand defaults if we have a default (which also means that everything is covered)
            [(def_mb_x, def_e)] | eXPAND_CASE_DEFAULTS
              -> return [ (DataAlt uncovered_dc uncovered_xs,
                           bind [ (x, data_ uncovered_dc uncovered_xs)
                                | Just x <- [def_mb_x]
                                ] def_e)
                        | (uncovered_dc, uncovered_xs) <- uncovered_siblings
                        ]
            -- We only need to expand uncovereds if we don't have a default (and even then we might find that the case is exhaustive)
            [] | eXPAND_CASE_UNCOVEREDS
              -> return [ (DataAlt uncovered_dc uncovered_xs, var (name "uncoveredBranch"))
                        | (uncovered_dc, uncovered_xs) <- uncovered_siblings
                        ]
            -- Nothing needs to be expanded in any other case
            _ -> Nothing
