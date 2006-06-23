> {-# OPTIONS_GHC -fglasgow-exts #-}

> module Ivor.State where

> import Ivor.TTCore
> import Ivor.Nobby
> import Ivor.Gadgets
> import Ivor.Typecheck
> import Ivor.Datatype
> import Ivor.MakeData
> import Ivor.ICompile
> import Ivor.Grouper
> import Ivor.SC
> import Ivor.Bytecode
> import Ivor.CodegenC
> import Ivor.Tactics as Tactics
> import Ivor.Display
> import Ivor.Unify

> import IO
> import System
> import List
> import Debug.Trace

State of the system, include all definitions, pattern matching rules,
compiled terms, etc.

> data IState = ISt {
>            -- All definitions        
>	     defs :: !(Gamma Name),
>            -- All datatype definitions
>            datadefs :: [(Name,Datatype Name)],
>            -- All elimination rules in their pattern matching form
>            -- (with type)
>            eliminators :: [(Name, (Indexed Name, [Scheme Name]))],
>            -- Supercombinators for each definition
>            runtt :: SCs,
>            -- Bytecode for each definitions
>            bcdefs :: ByteDef,
>            -- List of holes to be solved in proof state
>            holequeue :: ![Name],
>            -- Premises we're not interested in, so don't show
>            hidden :: [Name],
>            -- Current proof term (FIXME: Combine with holequeue, and make it efficient)
>            proofstate :: !(Maybe (Indexed Name)),
>            -- Actions required of last tactic
>            actions :: ![TacticAction],
>            -- List of fresh names for tactics to use
>            namesupply :: [Name],
>            -- Output from last operation
>            response :: String,
>            -- Previous state
>            undoState :: !(Maybe IState)
>        }

> initstate = ISt (Gam []) [] [] [] [] [] [] Nothing [] mknames "" Nothing
>   where mknames = [MN ("myName",x) | x <- [1..]]

> respond :: IState -> String -> IState
> respond st str = st { response = (response st) ++ str }

> gensym :: IState -> (Name, IState)
> gensym st = (head (namesupply st),
>              st { namesupply = tail (namesupply st) })

> jumpqueue hole q = nub (hole: (q \\ [hole]))
> stail (x:xs) = xs
> stail [] = []

> prf st = case (proofstate st) of
>           Nothing -> error "Can't happen"
>           (Just x) -> x

> saveState st = let st' = st in
>                    st { undoState = Just st' }

Take a data type definition and add constructors and elim rule to the context.

> doData :: Monad m => IState -> Name -> RawDatatype -> m IState
> doData st n r = do
>            let ctxt = defs st
>            let runtts = runtt st 
>            let bcs = bcdefs st
>            dt <- checkType (defs st) r -- Make iota schemes
>            ctxt <- gInsert (fst (tycon dt)) (snd (tycon dt)) ctxt
>                        -- let ctxt' = (tycon dt):ctxt
>            ctxt <- addCons (datacons dt) ctxt
>            (ctxt, newruntts, newbc) <- 
>                addElim ctxt runtts bcs (erule dt) (e_ischemes dt)
>            (newdefs, newruntts, newbc) <-
>                addElim ctxt newruntts newbc (crule dt) (c_ischemes dt)
>            let newelims = (fst (erule dt), (snd (erule dt), e_ischemes dt)):
>                           (fst (crule dt), (snd (crule dt), c_ischemes dt)):
>                           eliminators st
>            let newdatadefs = (n,dt):(datadefs st)
>            return $ st { defs = newdefs, datadefs = newdatadefs,
>                          eliminators = newelims,
>                          bcdefs = newbc, runtt = newruntts }
>    where addCons [] ctxt = return ctxt
>          addCons ((n,gl):xs) ctxt = do
>              ctxt <- addCons xs ctxt
>              gInsert n gl ctxt
>          addElim ctxt runtts bcdefs erule schemes = do
>            let cases = compileSchemes schemes
>            let arity = getArity schemes
>            let rule = mkElim (fst erule) (snd erule) arity cases
>            newdefs <- gInsert (fst erule) (G (ElimRule rule) (snd erule))
>                                   ctxt
>	--     putStrLn $ show cases
>            let sc = elimSC (fst erule) (levelise (snd erule)) cases
>	--     putStrLn $ showSC sc
>            let newsc = (N (fst erule),(arity,sc))
>            let newruntts = (newsc:runtts)
>            let bc = compileAll newruntts [newsc]
>	--     putStrLn $ show bc
>            let newbc = bc++bcdefs
>            return (newdefs, newruntts, newbc)

> doMkData :: Monad m => IState -> Datadecl -> m IState
> doMkData st (Datadecl n ps rawty cs) 
>     = do (gty,_) <- checkIndices (defs st) ps [] rawty
>          let ty = forget (normalise (defs st) gty)
>          -- TMP HACK: Do it twice, to fill in _ placeholders.
>          rd1 <- mkRawData n ps ty cs
>          dt1 <- checkType (defs st) rd1
>          let csfilled = map (forgetcon (length ps)) (datacons dt1)
>          rd <- mkRawData n ps ty csfilled
>          doData st n rd
>  where checkIndices gam [] env rawty = check gam env rawty Nothing
>        checkIndices gam ((n,nrawty):xs) env rawty = do
>            (Ind nty,_) <- check gam env nrawty Nothing
>            checkIndices gam xs (env++[(n,B Pi nty)]) rawty
>        -- also need to strip parameters
>        forgetcon numps (n, (G _ (Ind t))) = (n, (stripps numps (forget t)))
>        stripps 0 t = t
>        stripps n (RBind _ _ sc) = stripps (n-1) sc

> suspendProof :: Monad m => IState -> m IState
> suspendProof st = do case proofstate st of
>                        (Just prf) -> do
>                          let (Gam olddefs) = defs st
>                          newdef <- suspendFrom (defs st) prf (holequeue st)
>                          return $ st { proofstate = Nothing,
>                                        defs = Gam (newdef:olddefs),
>                                        holequeue = []
>                                      }
>                        _ -> fail "No proof in progress"

> suspendFrom gam (Ind (Bind x (B (Guess v) ty) (Sc (P n)))) q | n == x =
>               return $ (x, G (Partial (Ind v) q) (finalise (Ind ty)))
> suspendFrom _ _ _ = fail "Not a suspendable proof"

> resumeProof :: Monad m => IState -> Name -> m IState
> resumeProof st n = case (proofstate st) of
>      Nothing ->
>          case glookup n (defs st) of
>             Just ((Partial (Ind v) q),(Ind ty)) -> do
>                 -- recheck in case any of the names have changed 'status'
>                 -- (e.g., from undefined to defined type constructors)
>                 let vraw = forget v
>                 let traw = forget ty
>                 (Ind vrecheck, _) <- typecheck (defs st) vraw
>                 (Ind trecheck, _) <- typecheck (defs st) traw
>                 return $ st 
>                    { proofstate = Just
>                        (Ind (Bind n (B (Guess (makePs vrecheck))
>                                               (makePs trecheck)) 
>                               (Sc (P n)))),
>                      defs = remove n (defs st),
>                      holequeue = q
>                    }
>             _ -> fail "Not a suspended proof"
>      (Just _) -> fail "Already a proof in progress"

And an argument to the current proof (after any dependencies)
e.g. adding z:C x to foo : (x:A)(y:B)Z = [x:A][y:B]H
 becomes foo : (x:A)(z:C x)(y:B) = [x:A][z:C x][y:B]H.

> addArg :: Monad m => IState -> Name -> TT Name -> m IState
> addArg st n ty = 
>     case proofstate st of
>         Just (Ind (Bind n (B (Guess v) t) sc)) -> do 
>            (v',t') <- addArgTy v t (getDeps ty)
>            return $ st { proofstate = Just (Ind (Bind n (B (Guess v') t') sc)) }
>         _ -> fail "Can't add argument now"
>   where
>      getDeps ty = filter (nonfree (defs st)) (getNames (Sc ty))
>      nonfree gam n | Nothing <- lookupval n gam = True
>                    | otherwise = False
>      addArgTy v t [] = return (Bind n (B Lambda ty) (Sc v),
>                                Bind n (B Pi ty) (Sc t))
>      addArgTy (Bind n (B Lambda nty) (Sc v))
>               (Bind n' (B Pi nty') (Sc t)) ds 
>          | n == n' = do (v',t') <- addArgTy v t (ds \\ [n])
>                         return (Bind n (B Lambda nty) (Sc v'),
>                                 Bind n (B Pi nty) (Sc t'))
>      addArgTy _ _ _ = fail "Can't add argument here"



> dumpState :: IState -> String
> dumpState st = dumpProofstate (proofstate st)
>  where dumpProofstate Nothing = ""
>        dumpProofstate (Just p) = dhole p (holequeue st)
>                                  
>        dhole p [] = show p
>        dhole p (n:ns) = displayHoleContext (defs st) (hidden st) n p ++
>                           "Next holes: " ++ show ns++"\n"
