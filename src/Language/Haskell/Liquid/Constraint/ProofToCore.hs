{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE FlexibleContexts     #-}

module Language.Haskell.Liquid.Constraint.ProofToCore where

import Prelude hiding (error)
import CoreSyn hiding (Expr, Var)
import qualified CoreSyn as H
import Language.Haskell.Liquid.Types.Errors

import Var hiding (Var)
import qualified Var as V
import CoreUtils

import Type hiding (Var)
import TypeRep

import Language.Haskell.Liquid.GHC.Misc
import Language.Haskell.Liquid.WiredIn

import Language.Fixpoint.Misc

import Prover.Types
import Language.Haskell.Liquid.Transforms.CoreToLogic ()
import qualified Data.List as L
import Data.Maybe (fromMaybe)

type HId       = Id
type HVar      = Var      HId
type HAxiom    = Axiom    HId
type HCtor     = Ctor     HId
type HVarCtor  = VarCtor     HId
type HQuery    = Query    HId
type HInstance = Instance HId
type HProof    = Proof    HId
type HExpr     = Expr     HId

type CmbExpr = CoreExpr -> CoreExpr -> CoreExpr

class ToCore a where
  toCore :: CmbExpr -> CoreExpr -> a -> CoreExpr

instance ToCore HInstance where
  toCore c e i = makeApp (toCore c e $ inst_axiom i) (toCore c e <$> inst_args i)

instance ToCore HProof where
  toCore _ e Invalid = e
  toCore c e p       = combineProofs c e $ (toCore c e <$> p_evidence p)

instance ToCore HAxiom where
  toCore c e a = toCore c e $ axiom_name a

instance ToCore HExpr  where
  toCore c e (EVar v)    = toCore c e v
  toCore c' e (EApp c es) = makeApp (toCore c' e c) (toCore c' e <$> es)

instance ToCore HCtor where
  toCore c' e c =  toCore c' e $ ctor_expr c

instance ToCore HVar where
  toCore _ _ v = H.Var $ var_info v


-------------------------------------------------------------------------------
----------------  Combining Proofs --------------------------------------------
-------------------------------------------------------------------------------

-- | combineProofs :: combinator -> default expressions -> list of proofs
-- |               -> combined result

combineProofs :: CmbExpr -> CoreExpr -> [CoreExpr] -> CoreExpr
combineProofs _ e []  =  e
combineProofs c _ es = foldl (flip Let) (combine [1..] c (H.Var v) (H.Var <$> vs)) (bs ++ [dictionaryBind])
    where
      (v:vs, bs) = unzip [let v = (varANF i (exprType e)) in (v, NonRec v e)
                              | (e, i) <- zip es [1..] ]

combine _ _ e []             = e
combine _ c e' [e]           = c e' e
combine (i:uniq) c e' (e:es) = Let (NonRec v (c e' e)) (combine uniq c (H.Var v) es)
  where
     v = varCombine i (exprType $ c e' e)
combine _ _ _ _              = impossible Nothing err -- TODO: Does this case have a
   where                                              -- sane implementation?
     err = "Language.Haskell.Liquid.Constraint.ProofToCore.combine called with"
           ++ " empty first argument and non-empty fourth argument. This should"
           ++ " never happen!"


-------------------------------------------------------------------------------
----------------  make Application --------------------------------------------
-------------------------------------------------------------------------------



-- | To make application we need to instantiate expressions irrelevant to logic
-- | type application and dictionaries.
-- | Then, ANF the final expression

makeApp :: CoreExpr -> [CoreExpr] -> CoreExpr
makeApp f es = foldl (flip Let) (foldl App f' (reverse es')) (reverse  bs)
  where
   vts      = resolveVs as $ zip (dropWhile isClassPred ts) (exprType <$> es)
   (as, ts) = bkArrow (exprType f)
   f'       = instantiateVars vts f
   ds       = makeDictionaries dictionaryVar f'
   (bs, es', _) = foldl anf ([], [], [1..]) (ds ++ (instantiateVars vts <$> es))


instance Show Type where
  show (TyVarTy v) = show $ tvId v
  show t           = showPpr t

-- | ANF
anf :: ([CoreBind], [CoreExpr], [Int]) -> CoreExpr -> ([CoreBind], [CoreExpr], [Int])
anf (bs, es, i:uniq) (App f e) = ((NonRec v (App f e')):(bs++bs'), H.Var v:es, uniq')
  where v = varANF i (exprType $ App f e)
        (bs', [e'], uniq') = anf ([], [], uniq) e

anf (bs, es, uniq) e = (bs, e:es, uniq)

-- | Filling up dictionaries
makeDictionaries dname e = go (exprType e)
  where
    go (ForAllTy _ t) = go t
    go (FunTy tx t  ) | isClassPred tx = (makeDictionary dname tx):go t
    go _              = []

makeDictionary dname t = App (H.Var dname) (Type t)

-- | Filling up types
instantiateVars vts e = go e (exprType e)
  where
    go e (ForAllTy a t) = go (App e (Type $ fromMaybe (TyVarTy a) $ L.lookup a vts)) t
    go e _              = e

resolveVs :: [Id] -> [(Type, Type)] -> [(Id, Type)]
resolveVs as  ts = go as ts
  where
    go _   []                                     = []
    go fvs ((ForAllTy v t1, t2):ts)               = go (v:fvs) ((t1, t2):ts)
    go fvs ((t1, ForAllTy v t2):ts)               = go (v:fvs) ((t1, t2):ts)
    go fvs ((FunTy t1 t2, FunTy t1' t2'):ts)      = go fvs ((t1, t1'):(t2, t2'):ts)
    go fvs ((AppTy t1 t2, AppTy t1' t2'):ts)      = go fvs ((t1, t1'):(t2, t2'):ts)
    go fvs ((TyVarTy a, TyVarTy a'):ts) | a == a' = go fvs ts
    go fvs ((TyVarTy a, t):ts) | a `elem` fvs     = let vts = (go fvs (substTyV (a, t) <$> ts)) in (a, resolveVar a t vts) : vts
    go fvs ((t, TyVarTy a):ts) | a `elem` fvs     = let vts = (go fvs (substTyV (a, t) <$> ts)) in (a, resolveVar a t vts) : vts
    go fvs ((TyConApp _ cts,TyConApp _ cts'):ts)  = go fvs (zip cts cts' ++ ts)
    go fvs ((LitTy _, LitTy _):ts)                = go fvs ts
    go _   (tt:_)                                 = panic Nothing $ ("cannot resolve " ++ show tt ++ (" for ") ++ show ts)

resolveVar _ t [] = t
resolveVar a t ((a', t'):ats)
  | a == a'           = resolveVar a' t' ats
  | TyVarTy a'' <- t' = resolveVar a'' t' ats
  | otherwise         = resolveVar a t ats


substTyV :: (Id, Type) -> (Type, Type) -> (Type, Type)
substTyV (a, at) (t1, t2) = (go t1, go t2)
  where
    go (ForAllTy a' t) | a == a'   = ForAllTy a' t
                       | otherwise = ForAllTy a' (go t)
    go (FunTy t1 t2)   = FunTy (go t1) (go t2)
    go (AppTy t1 t2)   = AppTy (go t1) (go t2)
    go (TyConApp c ts) = TyConApp c (go <$> ts)
    go (LitTy l)       = LitTy l
    go (TyVarTy v)     | v == a    = at
                       | otherwise = TyVarTy v


-------------------------------------------------------------------------------
-------------------------  HELPERS --------------------------------------------
-------------------------------------------------------------------------------

varCombine i = stringVar ("proof_anf_cmb"  ++ show i)
varANF     i = stringVar ("proof_anf_bind" ++ show i)

bkArrow = go [] []
  where
    go vs ts (ForAllTy v t) = go (v:vs) ts t
    go vs ts (FunTy tx t)   = go vs (tx:ts) t
    go vs ts _              = (reverse vs, reverse ts)
