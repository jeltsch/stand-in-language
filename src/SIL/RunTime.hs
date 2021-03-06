--{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
module SIL.RunTime where

import Data.Functor.Identity
import Debug.Trace
import Control.Monad.Except
import Control.Monad.Fix

import SIL
import SIL.Optimizer

-- runtime expression
data RExpr
  = RZero
  | RPair !RExpr !RExpr
  | RVar
  | RAbort !RExpr
  | RGate !RExpr
  | RLeft !RExpr
  | RRight !RExpr
  | RTrace !RExpr
  | RSetEnv !RExpr
  | RDefer !RExpr
  | RTwiddle !RExpr
  -- machine optimized instructions
  | RITE !RExpr !RExpr !RExpr
  | RChurch !Int !(Maybe RExpr)
  deriving (Eq, Show, Ord)

instance EndoMapper RExpr where
  endoMap f RZero = f RZero
  endoMap f (RPair a b) = f $ RPair (endoMap f a) (endoMap f b)
  endoMap f RVar = f RVar
  endoMap f (RAbort x) = f . RAbort $ endoMap f x
  endoMap f (RGate x) = f . RGate $ endoMap f x
  endoMap f (RLeft x) = f . RLeft $ endoMap f x
  endoMap f (RRight x) = f . RRight $ endoMap f x
  endoMap f (RTrace x) = f . RTrace $ endoMap f x
  endoMap f (RSetEnv x) = f . RSetEnv $ endoMap f x
  endoMap f (RDefer x) = f . RDefer $ endoMap f x
  endoMap f (RTwiddle x) = f . RTwiddle $ endoMap f x
  endoMap f (RITE i t e) = f $ RITE (endoMap f i) (endoMap f t) (endoMap f e)
  endoMap f r@(RChurch _ Nothing) = f r

toRExpr :: IExpr -> RExpr
toRExpr Zero = RZero
toRExpr (Pair a b) = RPair (toRExpr a) (toRExpr b)
toRExpr Var = RVar
toRExpr (Abort x) = RAbort $ toRExpr x
toRExpr (Gate x) = RGate $ toRExpr x
toRExpr (PLeft x) = RLeft $ toRExpr x
toRExpr (PRight x) = RRight $ toRExpr x
toRExpr (Trace x) = RTrace $ toRExpr x
toRExpr (SetEnv x) = RSetEnv $ toRExpr x
toRExpr (Defer x) = RDefer $ toRExpr x
toRExpr (Twiddle x) = RTwiddle $ toRExpr x

fromRExpr :: RExpr -> IExpr
fromRExpr RZero = Zero
fromRExpr (RPair a b) = Pair (fromRExpr a) (fromRExpr b)
fromRExpr RVar = Var
fromRExpr (RAbort x) = Abort $ fromRExpr x
fromRExpr (RGate x) = Gate $ fromRExpr x
fromRExpr (RLeft x) = PLeft $ fromRExpr x
fromRExpr (RRight x) = PRight $ fromRExpr x
fromRExpr (RTrace x) = Trace $ fromRExpr x
fromRExpr (RSetEnv x) = SetEnv $ fromRExpr x
fromRExpr (RDefer x) = Defer $ fromRExpr x
fromRExpr (RTwiddle x) = Twiddle $ fromRExpr x
fromRExpr (RITE i t e) = app (Gate $ fromRExpr i) (Pair (fromRExpr e) (fromRExpr t))
fromRExpr (RChurch i Nothing) = toChurch i

type RunTimeError = String

rEval :: MonadError RunTimeError m => (RExpr -> RExpr -> m RExpr) -> RExpr -> RExpr -> m RExpr
rEval f env g = let f' = f env
                    rApply (RPair ng eenv) v = f (RPair v eenv) ng
                    rApply (RChurch ci Nothing) v = pure $ RChurch ci (Just v)
                    rApply (RChurch ci (Just cf)) v =
                      let step 0 cv = pure cv
                          step x cv = rApply cf cv >>= step (x - 1)
                      in step ci v
                    rApply ng _ = throwError $ "not a closure " ++ show ng
                in case g of
  RZero -> pure RZero
  (RPair a b) -> RPair <$> f' a <*> f' b
  RVar -> pure env
  RAbort x -> f' x >>= \nx -> if nx == RZero then pure RZero
                              else throwError $ concat ["rabort: ", g2s $ fromRExpr nx]
  RDefer x -> pure x
  RTwiddle x -> f' x >>= \nx -> case nx of
    RPair i (RPair c cenv) -> pure $ RPair c (RPair i cenv)
    bx -> throwError $ concat ["rtwiddle: expecting pair pair, got ", show nx]
  -- this seems a bit hacky
  RSetEnv (RTwiddle (RPair i g)) -> do
    ng <- f' g
    ni <- f' i
    rApply ng ni
  RSetEnv x -> f' x >>= \g -> case g of
    RPair c i -> rApply c i
    bx -> throwError $ concat ["rsetenv basic - not a closure: ", show bx]
  RGate x -> f' x >>= \g -> case g of
    RZero -> pure $ RLeft RVar
    _ -> pure $ RRight RVar
  RLeft g -> f' g >>= \g -> case g of
    (RPair a _) -> pure a
    _ -> pure RZero
  RRight g -> f' g >>= \g -> case g of
    (RPair _ b) -> pure b
    _ -> pure RZero
  RTrace g -> f' g >>= \g -> pure $ trace (show g) g
  RITE i t e -> f' i >>= \ng -> case ng of
    RZero -> f' e
    _ -> f' t
  r@(RChurch _ _) -> pure r

iEval :: MonadError RunTimeError m => (IExpr -> IExpr -> m IExpr) -> IExpr -> IExpr -> m IExpr
iEval f env g = let f' = f env in case g of
  Zero -> pure Zero
  Pair a b -> do
    na <- f' a
    nb <- f' b
    pure $ Pair na nb
  Var -> pure env
  Abort x -> f' x >>= \nx -> if nx == Zero then pure Zero else throwError $ concat ["abort: ", g2s nx]
  SetEnv x -> (f' x >>=) $ \nx -> case nx of
    Pair c nenv -> f nenv c
    bx -> throwError $ concat ["setenv: expecting pair, got ", show bx]
  Defer x -> pure x
  Twiddle x -> (f' x >>=) $ \nx -> case nx of
    Pair i (Pair c cenv) -> pure $ Pair c (Pair i cenv)
    bx -> throwError $ concat ["twiddle: expecting pair pair, got ", show bx]
  Gate x -> f' x >>= \g -> case g of
    Zero -> pure $ PLeft Var
    _ -> pure $ PRight Var
  PLeft g -> f' g >>= \g -> case g of
    (Pair a _) -> pure a
    _ -> pure Zero
  PRight g -> f' g >>= \g -> case g of
    (Pair _ x) -> pure x
    _ -> pure Zero
  Trace g -> f' g >>= \g -> pure $ trace (show g) g

toChurch :: Int -> IExpr
toChurch x =
  let inner 0 = PLeft Var
      inner x = app (PLeft $ PRight Var) (inner (x - 1))
  in lam (lam (inner x))

rOptimize :: RExpr -> RExpr
rOptimize =
  let modR (RSetEnv (RPair (RGate i) (RPair e t))) = RITE i t e
      modR c@(RPair (RDefer (RPair (RDefer (apps)) RVar)) RVar) = let appCount = countApps 0 apps in
        if appCount > 0
        then RChurch appCount Nothing
        else c
      modR x = x
      countApps x (RLeft RVar) = x
      countApps x (RSetEnv (RTwiddle (RPair ia (RLeft (RRight RVar))))) = countApps (x + 1) ia
      countApps _ _ = 0
  in endoMap modR

simpleEval :: IExpr -> IO IExpr
simpleEval x = runExceptT (fix iEval Zero x) >>= \r -> case r of
  Left e -> fail e
  Right i -> pure i

fasterEval :: IExpr -> IO IExpr
fasterEval =
  let frEval x = runExceptT (fix rEval RZero x) >>= \r -> case r of
        Left e -> fail e
        Right i -> pure i
  in fmap fromRExpr . frEval . rOptimize . toRExpr

optimizedEval :: IExpr -> IO IExpr
optimizedEval = fasterEval --simpleEval . optimize

pureEval :: IExpr -> Either RunTimeError IExpr
pureEval g = runIdentity . runExceptT $ fix iEval Zero g

pureREval :: IExpr -> Either RunTimeError IExpr
pureREval = fmap fromRExpr . runIdentity . runExceptT . fix rEval RZero . rOptimize . toRExpr

pureEvalWithError :: IExpr -> Either String IExpr
pureEvalWithError = fix iEval Zero

showPass :: (Show a, MonadIO m) => m a -> m a
showPass a = a >>= (liftIO . print) >> a

tEval :: IExpr -> IO IExpr
tEval x = runExceptT (fix (\f e g -> showPass $ iEval f e g) Zero x) >>= \r -> case r of
  Left e -> fail e
  Right i -> pure i

typedEval :: (IExpr -> DataType -> Bool) -> IExpr -> (IExpr -> IO ()) -> IO ()
typedEval typeCheck iexpr prettyPrint = if typeCheck iexpr ZeroType
  then simpleEval iexpr >>= prettyPrint
  else putStrLn "failed typecheck"

debugEval :: (IExpr -> DataType -> Bool) -> IExpr -> IO ()
debugEval typeCheck iexpr = if typeCheck iexpr ZeroType
  then tEval iexpr >>= (print . PrettyIExpr)
  else putStrLn "failed typecheck"

fullEval typeCheck i = typedEval typeCheck i print

prettyEval typeCheck i = typedEval typeCheck i (print . PrettyIExpr)

evalLoop :: (Show a, Eq a) => (DataType -> IExpr -> Maybe a) -> IExpr -> IO ()
evalLoop typeCheck iexpr = if typeCheck ZeroType (app iexpr Zero) == Nothing
  then let mainLoop s = do
             result <- runExceptT . fix rEval RZero $ RSetEnv (RTwiddle (RPair s optIExpr))
             case result of
               Right RZero -> putStrLn "aborted"
               Right (RPair disp newState) -> do
                 putStrLn . g2s . fromRExpr $ disp
                 case newState of
                   RZero -> putStrLn "done"
                   _ -> do
                     inp <- (toRExpr . s2g) <$> getLine
                     mainLoop $ RPair inp newState
               r -> putStrLn $ concat ["runtime error, dumped ", show r]
           optIExpr = rOptimize $ toRExpr iexpr
       in mainLoop RZero
  else putStrLn $ concat ["main's checked type: "
                         , show $ typeCheck ZeroType (app iexpr Zero)
                         ]
