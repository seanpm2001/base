------------------------------------------------------------------------------
--- This module contains functions to reduce the size of FlatCurry programs
--- by combining the main module and all imports into a single program
--- that contains only the functions directly or indirectly called from
--- a set of main functions.
---
--- @author Michael Hanus, Carsten Heine
--- @version August 2016
--- @category meta
------------------------------------------------------------------------------

{-# OPTIONS_CYMAKE -Wno-incomplete-patterns #-}

module FlatCurry.Compact(generateCompactFlatCurryFile,computeCompactFlatCurry,
                         Option(..),RequiredSpec,requires,alwaysRequired,
                         defaultRequired) where

import FlatCurry.Types
import FlatCurry.Files
import SetRBT
import TableRBT
import Maybe
import List             (nub, union)
import FileGoodies
import FilePath         (takeFileName, (</>))
import Directory
import Sort             (cmpString, leqString)
import XML
import Distribution     (lookupModuleSourceInLoadPath, stripCurrySuffix)

infix 0 `requires`

------------------------------------------------------------------------------
--- Options to guide the compactification process.
--- @cons Verbose  - for more output
--- @cons Main     - optimize for one main (unqualified!) function supplied here
--- @cons Exports  - optimize w.r.t. the exported functions of the module only
--- @cons InitFuncs - optimize w.r.t. given list of initially required functions
--- @cons Required - list of functions that are implicitly required and, thus,
---                  should not be deleted if the corresponding module
---                  is imported
--- @cons Import   - module that should always be imported
---                  (useful in combination with option InitFuncs)
data Option =
    Verbose
  | Main String
  | Exports
  | InitFuncs [QName]
  | Required [RequiredSpec]
  | Import String
-- deriving Eq

instance Eq Option where
  _ == _ = error "TODO: Eq FlatCurry.Compact.Option"


isMainOption :: Option -> Bool
isMainOption o = case o of
                   Main _ -> True
                   _      -> False

getMainFuncFromOptions :: [Option] -> String
getMainFuncFromOptions (o:os) =
   case o of
     Main f -> f
     _      -> getMainFuncFromOptions os

getRequiredFromOptions :: [Option] -> [RequiredSpec]
getRequiredFromOptions options = concat [ fs | Required fs <- options ]

-- add Import for modules containing always required functions:
addImport2Options :: [Option] -> [Option]
addImport2Options options =
  options ++
  map Import (nub (concatMap alwaysReqMod (getRequiredFromOptions options)))
 where
  alwaysReqMod (AlwaysReq (m,_))  = [m]
  alwaysReqMod (Requires _ _) = []

------------------------------------------------------------------------------
--- Data type to specify requirements of functions.
data RequiredSpec = AlwaysReq QName | Requires QName QName

--- (fun `requires` reqfun) specifies that the use of the function "fun"
--- implies the application of function "reqfun".
requires :: QName -> QName -> RequiredSpec
requires fun reqfun = Requires fun reqfun

--- (alwaysRequired fun) specifies that the function "fun" should be
--- always present if the corresponding module is loaded.
alwaysRequired :: QName -> RequiredSpec
alwaysRequired fun = AlwaysReq fun

--- Functions that are implicitly required in a FlatCurry program
--- (since they might be generated by external functions like
--- "==" or "=:=" on the fly).
defaultRequired :: [RequiredSpec]
defaultRequired =
  [alwaysRequired (prelude,"apply"),
   alwaysRequired (prelude,"letrec"),
   alwaysRequired (prelude,"cond"),
   alwaysRequired (prelude,"failure"),
   (prelude,"==")    `requires` (prelude,"&&"),
   (prelude,"=:=")   `requires` (prelude,"&"),
   (prelude,"=:<=")  `requires` (prelude,"ifVar"),
   (prelude,"=:<=")  `requires` (prelude,"=:="),
   (prelude,"=:<=")  `requires` (prelude,"&>"),
   (prelude,"=:<<=") `requires` (prelude,"&"),
   (prelude,"$#")    `requires` (prelude,"ensureNotFree"),
   (prelude,"readFile") `requires` (prelude,"prim_readFileContents"),
   ("Ports","prim_openPortOnSocket") `requires` ("Ports","basicServerLoop"),
   ("Ports","prim_timeoutOnStream")  `requires` ("Ports","basicServerLoop"),
   ("Ports","prim_choiceSPEP")       `requires` ("Ports","basicServerLoop"),
   ("Dynamic","getDynamicKnowledge") `requires` ("Dynamic","isKnownAtTime") ]

prelude :: String
prelude = "Prelude"

--- Get functions that are required in a module w.r.t.
--- a requirement specification.
getRequiredInModule :: [RequiredSpec] -> String -> [QName]
getRequiredInModule reqspecs mod = concatMap getImpReq reqspecs
 where
  getImpReq (AlwaysReq (mf,f)) = if mf==mod then [(mf,f)] else []
  getImpReq (Requires _ _) = []

--- Get functions that are implicitly required by a function w.r.t.
--- a requirement specification.
getImplicitlyRequired :: [RequiredSpec] -> QName -> [QName]
getImplicitlyRequired reqspecs fun = concatMap getImpReq reqspecs
 where
  getImpReq (AlwaysReq _) = []
  getImpReq (Requires f reqf) = if f==fun then [reqf] else []

--- The basic types that are always required in a FlatCurry program.
defaultRequiredTypes :: [QName]
defaultRequiredTypes =
  [(prelude,"()"),(prelude,"Int"),(prelude,"Float"),(prelude,"Char"),
   (prelude,"Success"),(prelude,"IO")]


-------------------------------------------------------------------------------
-- Main functions:
-------------------------------------------------------------------------------

--- Computes a single FlatCurry program containing all functions potentially
--- called from a set of main functions and writes it into a FlatCurry file.
--- This is done by merging all imported FlatCurry modules and removing
--- the imported functions that are definitely not used.
--- @param options  - list of options
--- @param progname - name of the Curry program that should be compacted
--- @param target   - name of the target file where the compact program is saved
generateCompactFlatCurryFile :: [Option] -> String -> String -> IO ()
generateCompactFlatCurryFile options progname target = do
  optprog <- computeCompactFlatCurry options progname
  writeFCY target optprog
  done

--- Computes a single FlatCurry program containing all functions potentially
--- called from a set of main functions.
--- This is done by merging all imported FlatCurry modules (these are loaded
--- demand-driven so that modules that contains no potentially called functions
--- are not loaded) and removing the imported functions that are definitely
--- not used.
--- @param options  - list of options
--- @param progname - name of the Curry program that should be compacted
--- @return the compact FlatCurry program
computeCompactFlatCurry :: [Option] -> String -> IO Prog
computeCompactFlatCurry orgoptions progname =
  let options = addImport2Options orgoptions in
  if (elem Exports options) && (any isMainOption options)
  then error
        "CompactFlat: Options 'Main' and 'Exports' can't be be used together!"
  else do
    putStr "CompactFlat: Searching relevant functions in module "
    prog <- readCurrentFlatCurry progname
    resultprog <- makeCompactFlatCurry prog options
    putStrLn ("CompactFlat: Number of functions after optimization: " ++
              show (length (moduleFuns resultprog)))
    return resultprog

--- Create the optimized program.
makeCompactFlatCurry :: Prog -> [Option] -> IO Prog
makeCompactFlatCurry mainmod options = do
  (initfuncs,loadedmnames,loadedmods) <- requiredInCompactProg mainmod options
  let initFuncTable = extendFuncTable (emptyTableRBT leqQName)
                                      (concatMap moduleFuns loadedmods)
      required = getRequiredFromOptions options
      loadedreqfuns = concatMap (getRequiredInModule required)
                                (map moduleName loadedmods)
      initreqfuncs = initfuncs ++ loadedreqfuns
  (finalmods,finalfuncs,finalcons,finaltcons) <-
     getCalledFuncs required
                    loadedmnames loadedmods initFuncTable
                    (foldr insertRBT (emptySetRBT leqQName) initreqfuncs)
                    (emptySetRBT leqQName) (emptySetRBT leqQName)
                    initreqfuncs
  putStrLn ("\nCompactFlat: Total number of functions (without unused imports): "
            ++ show (foldr (+) 0 (map (length . moduleFuns) finalmods)))
  let finalfnames  = map functionName finalfuncs
  return (Prog (moduleName mainmod)
               []
               (let allTDecls = concatMap moduleTypes finalmods
                    reqTCons  = extendTConsWithConsType finalcons finaltcons
                                                        allTDecls
                    allReqTCons = requiredDatatypes reqTCons allTDecls
                 in filter (\tdecl->tconsName tdecl `elemRBT` allReqTCons)
                           allTDecls)
               finalfuncs
               (filter (\ (Op oname _ _) -> oname `elem` finalfnames)
                       (concatMap moduleOps finalmods)))

-- compute the transitive closure of a set of type constructors w.r.t.
-- to a given list of type declaration so that the set contains
-- all type constructor names occurring in the type declarations:
requiredDatatypes :: SetRBT QName -> [TypeDecl] -> SetRBT QName
requiredDatatypes tcnames tdecls =
  let newtcons = concatMap (newTypeConsOfTDecl tcnames) tdecls
   in if null newtcons
      then tcnames
      else requiredDatatypes (foldr insertRBT tcnames newtcons) tdecls

-- Extract the new type constructors (w.r.t. a given set) contained in a
-- type declaration:
newTypeConsOfTDecl :: SetRBT QName -> TypeDecl -> [QName]
newTypeConsOfTDecl tcnames (TypeSyn tcons _ _ texp) =
  if tcons `elemRBT` tcnames
  then filter (\tc -> not (tc `elemRBT` tcnames)) (allTypesOfTExpr texp)
  else []
newTypeConsOfTDecl tcnames (Type tcons _ _ cdecls) =
  if tcons `elemRBT` tcnames
  then filter (\tc -> not (tc `elemRBT` tcnames))
          (concatMap (\ (Cons _ _ _ texps) -> concatMap allTypesOfTExpr texps)
                    cdecls)
  else []

-- Extend set of type constructor with type constructors of data declarations
-- contain some constructor.
extendTConsWithConsType :: SetRBT QName -> SetRBT QName -> [TypeDecl]
                        -> SetRBT QName
extendTConsWithConsType _ tcons [] = tcons
extendTConsWithConsType cnames tcons (TypeSyn tname _ _ _ : tds) =
  extendTConsWithConsType cnames (insertRBT tname tcons) tds
extendTConsWithConsType cnames tcons (Type tname _ _ cdecls : tds) =
  if tname `elem` defaultRequiredTypes ||
     any (\cdecl->consName cdecl `elemRBT` cnames) cdecls
  then extendTConsWithConsType cnames (insertRBT tname tcons) tds
  else extendTConsWithConsType cnames tcons tds

-- Extend function table (mapping from qualified names to function declarations)
-- by some new function declarations:
extendFuncTable :: TableRBT QName FuncDecl -> [FuncDecl]
                -> TableRBT QName FuncDecl
extendFuncTable ftable fdecls =
  foldr (\f t -> updateRBT (functionName f) f t) ftable fdecls


-------------------------------------------------------------------------------
-- Generate the Prog to start with:
-------------------------------------------------------------------------------

-- Compute the initially required functions in the compact program
-- together with the set of module names and contents that are initially loaded:
requiredInCompactProg :: Prog -> [Option] -> IO ([QName],SetRBT String,[Prog])
requiredInCompactProg mainmod options
 | not (null initfuncs)
  = do impprogs <- mapIO readCurrentFlatCurry imports
       return (concat initfuncs, add2mainmodset imports, mainmod:impprogs)
 | Exports `elem` options
  = do impprogs <- mapIO readCurrentFlatCurry imports
       return (nub mainexports, add2mainmodset imports, mainmod:impprogs)
 | any isMainOption options
  = let func = getMainFuncFromOptions options in
     if (mainmodname,func) `elem` (map functionName (moduleFuns mainmod))
     then do
       impprogs <- mapIO readCurrentFlatCurry imports
       return ([(mainmodname,func)], add2mainmodset imports, mainmod:impprogs)
     else error $ "CompactFlat: Cannot find main function \""++func++"\"!"
 | otherwise
  = do impprogs <- mapIO readCurrentFlatCurry
                         (nub (imports ++ moduleImports mainmod))
       return (nub (mainexports ++
                    concatMap (exportedFuncNames . moduleFuns) impprogs),
               add2mainmodset (map moduleName impprogs),
               mainmod:impprogs)
 where
   imports = nub [ mname | Import mname <- options ]

   mainmodname = moduleName mainmod

   initfuncs = [ fs | InitFuncs fs <- options ]

   mainexports = exportedFuncNames (moduleFuns mainmod)

   mainmodset = insertRBT mainmodname (emptySetRBT leqString)

   add2mainmodset mnames = foldr insertRBT mainmodset mnames


-- extract the names of all exported functions:
exportedFuncNames :: [FuncDecl] -> [QName]
exportedFuncNames funs =
   map (\(Func name _ _ _ _)->name)
       (filter (\(Func _ _ vis _ _)->vis==Public) funs)


-------------------------------------------------------------------------------
--- Adds all required functions to the program and load modules, if necessary.
--- @param required - list of potentially required functions
--- @param loadedmnames - set of already considered module names
--- @param progs - list of already loaded modules
--- @param functable - mapping from (loaded) function names to their definitions
--- @param loadedfnames - set of already loaded function names
--- @param loadedcnames - set of already required data constructors
--- @param loadedtnames - set of already required data constructors
--- @param fnames - list of function names to be analyzed for dependencies
--- @return (list of loaded modules, list of required function declarations,
---          set of required data constructors, set of required type names)
getCalledFuncs :: [RequiredSpec] -> SetRBT String -> [Prog]
               -> TableRBT QName FuncDecl
               -> SetRBT QName -> SetRBT QName -> SetRBT QName
               -> [QName]
               -> IO ([Prog],[FuncDecl],SetRBT QName,SetRBT QName)
getCalledFuncs _ _ progs _ _ dcs ts [] = return (progs,[],dcs,ts)
getCalledFuncs required loadedmnames progs functable loadedfnames loadedcnames
               loadedtnames ((m,f):fs)
  | not (elemRBT m loadedmnames)
   = do newmod <- readCurrentFlatCurry m
        let reqnewfun = getRequiredInModule required m
        getCalledFuncs required (insertRBT m loadedmnames) (newmod:progs)
                       (extendFuncTable functable (moduleFuns newmod))
                       (foldr insertRBT loadedfnames reqnewfun) loadedcnames
                       loadedtnames ((m,f):fs ++ reqnewfun)
  | isNothing (lookupRBT (m,f) functable)
   = -- this must be a data constructor: ingore it since already considered
     getCalledFuncs required loadedmnames progs
                    functable loadedfnames loadedcnames loadedtnames fs
  | otherwise = do
   let fdecl = fromJust (lookupRBT (m,f) functable)
       funcCalls = allFuncCalls fdecl
       newFuncCalls = filter (\qn->not (elemRBT qn loadedfnames)) funcCalls
       newReqs = concatMap (getImplicitlyRequired required) newFuncCalls
       consCalls = allConstructorsOfFunc fdecl
       newConsCalls = filter (\qn->not (elemRBT qn loadedcnames)) consCalls
       newtcons = allTypesOfFunc fdecl
   (newprogs,newfuns,newcons, newtypes) <-
       getCalledFuncs required loadedmnames progs functable
                      (foldr insertRBT loadedfnames (newFuncCalls++newReqs))
                      (foldr insertRBT loadedcnames consCalls)
                      (foldr insertRBT loadedtnames newtcons)
                      (fs ++ newFuncCalls ++ newReqs ++ newConsCalls)
   return (newprogs, fdecl:newfuns, newcons, newtypes)


-------------------------------------------------------------------------------
-- Operations to get all function calls, types,... in a function declaration:
-------------------------------------------------------------------------------

--- Get all function calls in a function declaration and remove duplicates.
--- @param funcDecl - a function declaration in FlatCurry
--- @return a list of all function calls
allFuncCalls :: FuncDecl -> [QName]
allFuncCalls (Func _ _ _ _ (External _)) = []
allFuncCalls (Func _ _ _ _ (Rule _ expr)) = nub (allFuncCallsOfExpr expr)


--- Get all function calls in an expression.
--- @param expr - an expression
--- @return a list of all function calls
allFuncCallsOfExpr :: Expr -> [QName]
allFuncCallsOfExpr (Var _) = []
allFuncCallsOfExpr (Lit _) = []
allFuncCallsOfExpr (Comb ctype fname exprs) = case ctype of
  FuncCall       -> fname:fnames
  FuncPartCall _ -> fname:fnames
  _ -> fnames
 where
  fnames = concatMap allFuncCallsOfExpr exprs
allFuncCallsOfExpr (Free _ expr) = 
    allFuncCallsOfExpr expr
allFuncCallsOfExpr (Let bs expr) =
    concatMap (allFuncCallsOfExpr . snd) bs ++ allFuncCallsOfExpr expr
allFuncCallsOfExpr (Or expr1 expr2) = 
    allFuncCallsOfExpr expr1 ++ allFuncCallsOfExpr expr2
allFuncCallsOfExpr (Case _ expr branchExprs) =
    allFuncCallsOfExpr expr ++
    concatMap allFuncCallsOfBranchExpr branchExprs
allFuncCallsOfExpr (Typed expr _) = allFuncCallsOfExpr expr


--- Get all function calls in a branch expression in case expressions.
--- @param branchExpr - a branch expression
--- @return a list of all function calls
allFuncCallsOfBranchExpr :: BranchExpr -> [QName]
allFuncCallsOfBranchExpr (Branch _ expr) = allFuncCallsOfExpr expr



--- Get all data constructors in a function declaration.
allConstructorsOfFunc :: FuncDecl -> [QName]
allConstructorsOfFunc (Func _ _ _ _ (External _)) = []
allConstructorsOfFunc (Func _ _ _ _ (Rule _ expr)) = allConsOfExpr expr

--- Get all data constructors in an expression.
allConsOfExpr :: Expr -> [QName]
allConsOfExpr (Var _) = []
allConsOfExpr (Lit _) = []
allConsOfExpr (Comb ctype cname exprs) = case ctype of
  ConsCall       -> cname:cnames
  ConsPartCall _ -> cname:cnames
  _ -> cnames
 where
  cnames = unionMap allConsOfExpr exprs
allConsOfExpr (Free _ expr) = 
   allConsOfExpr expr
allConsOfExpr (Let bs expr) =
   union (unionMap (allConsOfExpr . snd) bs) (allConsOfExpr expr)
allConsOfExpr (Or expr1 expr2) = 
   union (allConsOfExpr expr1) (allConsOfExpr expr2)
allConsOfExpr (Case _ expr branchExprs) =
   union (allConsOfExpr expr) (unionMap consOfBranch branchExprs)
 where
  consOfBranch (Branch (LPattern _) e) = allConsOfExpr e
  consOfBranch (Branch (Pattern c _) e) = union [c] (allConsOfExpr e)
allConsOfExpr (Typed expr _) = allConsOfExpr expr


--- Get all type constructors in a function declaration.
allTypesOfFunc :: FuncDecl -> [QName]
allTypesOfFunc (Func _ _ _ texp _) = allTypesOfTExpr texp

--- Get all data constructors in an expression.
allTypesOfTExpr :: TypeExpr -> [QName]
allTypesOfTExpr (TVar _) = []
allTypesOfTExpr (FuncType texp1 texp2) = 
   union (allTypesOfTExpr texp1) (allTypesOfTExpr texp2)
allTypesOfTExpr (TCons tcons args) =
  union [tcons] (unionMap allTypesOfTExpr args)

unionMap :: (a -> [b]) -> [a] -> [b]
unionMap f = foldr union [] . map f


-------------------------------------------------------------------------------
-- Functions to get direct access to some data inside a datatype:
-------------------------------------------------------------------------------

--- Extracts the function name of a function declaration.
functionName :: FuncDecl -> QName
functionName (Func name _ _ _ _) = name

--- Extracts the constructor name of a constructor declaration.
consName :: ConsDecl -> QName
consName (Cons name _ _ _) = name

--- Extracts the type name of a type declaration.
tconsName :: TypeDecl -> QName
tconsName (Type name _ _ _) = name
tconsName (TypeSyn name _ _ _) = name

--- Extracts the names of imported modules of a FlatCurry program.
moduleImports :: Prog -> [String]
moduleImports (Prog _ imports _ _ _) = imports


--- Extracts the types of a FlatCurry program.
moduleTypes :: Prog -> [TypeDecl]
moduleTypes (Prog _ _ types _ _) = types

--- Extracts the operators of a FlatCurry program.
moduleOps :: Prog -> [OpDecl]
moduleOps (Prog _ _ _ _ ops) = ops

--- Extracts the name of the Prog.
moduleName :: Prog -> String
moduleName (Prog name _ _ _ _) = name

--- Extracts the functions of the program.
moduleFuns :: Prog -> [FuncDecl]
moduleFuns (Prog _ _ _ funs _) = funs


-------------------------------------------------------------------------------
-- Functions for comparison:
-------------------------------------------------------------------------------

--- Compares two qualified names.
--- Returns True, if the first name is lexicographically smaller than
--- the second name using the leString function to compare String.
leqQName :: QName -> QName -> Bool
leqQName (m1,n1) (m2,n2) = let cm = cmpString m1 m2
                            in cm==LT || (cm==EQ && leqString n1 n2)


-------------------------------------------------------------------------------
-- I/O functions:
-------------------------------------------------------------------------------

-- Read a FlatCurry program (parse only if necessary):
readCurrentFlatCurry :: String -> IO Prog
readCurrentFlatCurry modname = do
  putStr (modname++"...")
  mbsrc <- lookupModuleSourceInLoadPath modname
  case mbsrc of
    Nothing -> error ("Curry file for module \""++modname++"\" not found!")
    Just (moddir,progname) -> do
      let fcyname = flatCurryFileName (moddir </> takeFileName modname)
      fcyexists <- doesFileExist fcyname
      if not fcyexists
       then readFlatCurry modname >>= processPrimitives progname
       else do
         ctime <- getModificationTime progname
         ftime <- getModificationTime fcyname
         if ctime>ftime
          then readFlatCurry progname >>= processPrimitives progname
          else readFlatCurryFile fcyname >>= processPrimitives progname

-- read primitive specification and transform FlatCurry program accordingly:
processPrimitives :: String -> Prog -> IO Prog
processPrimitives progname prog = do
  pspecs <- readPrimSpec (moduleName prog)
                         (stripCurrySuffix progname ++ ".prim_c2p")
  return (mergePrimSpecIntoModule pspecs prog)

mergePrimSpecIntoModule :: [(QName,QName)] -> Prog -> Prog
mergePrimSpecIntoModule trans (Prog name imps types funcs ops) =
  Prog name imps types (concatMap (mergePrimSpecIntoFunc trans) funcs) ops

mergePrimSpecIntoFunc :: [(QName,QName)] -> FuncDecl -> [FuncDecl]
mergePrimSpecIntoFunc trans (Func name ar vis tp rule) =
 let fname = lookup name trans in
 if fname==Nothing
 then [Func name ar vis tp rule]
 else let Just (lib,entry) = fname
       in if null entry
          then []
          else [Func name ar vis tp (External (lib++' ':entry))]


readPrimSpec :: String -> String -> IO [(QName,QName)]
readPrimSpec mod xmlfilename = do
  existsXml <- doesFileExist xmlfilename
  if existsXml
   then do --putStrLn $ "Reading specification '"++xmlfilename++"'..."
           xmldoc <- readXmlFile xmlfilename
           return (xml2primtrans mod xmldoc)
   else return []

xml2primtrans :: String -> XmlExp -> [(QName,QName)]
xml2primtrans mod (XElem "primitives" [] primitives) = map xml2prim primitives
 where
   xml2prim (XElem "primitive" (("name",fname):_)
                   [XElem "library" [] xlib, XElem "entry" [] xfun]) =
       ((mod,fname),(textOfXml xlib,textOfXml xfun))
   xml2prim (XElem "ignore" (("name",fname):_) []) = ((mod,fname),("",""))


-------------------------------------------------------------------------------
