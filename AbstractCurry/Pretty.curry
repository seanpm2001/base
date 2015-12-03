--- --------------------------------------------------------------------------
--- Pretty-printing of AbstractCurry.
---
--- This library provides a pretty-printer for AbstractCurry modules.
---
--- @author  Yannik Potdevin
--- @version October 2015
--- --------------------------------------------------------------------------
module AbstractCurry.Pretty
    ( Qualification(..), Options, LayoutChoice(..)

    , options, defaultOptions
    , setPageWith, setIndentWith, setQualification, setModName, setLayoutChoice

    , showCProg, prettyCurryProg, ppCurryProg

    , ppMName, ppExports, ppImports

    , ppCOpDecl, ppCTypeDecl, ppCFuncDecl, ppCFuncDeclWithoutSig
    , ppCFuncSignature, ppCTypeExpr, ppCPattern, ppCLiteral, ppCExpr
    , ppCStatement, ppQFunc, ppFunc, ppQType, ppType)
    where

import Pretty hiding        ( list, listSpaced, tupled, tupledSpaced, set
                            , setSpaced )
import AbstractCurry.Select hiding (varsOfLDecl, varsOfFDecl, varsOfStat)
import AbstractCurry.Types
import Function             (on)
import List                 (partition, union, scanl, last)
import Maybe                (isJust, fromJust)

type Collection a = [a]

data Qualification
    = Full      -- ^ Fully qualify every identifier, including those of the
                --   processed module and Prelude.
    | Imports   -- ^ Fully qualify external identifiers, do not qualify local
                --   identifiers and those of Prelude.
    | OnDemand  -- ^ Fully qualify only identifiers which need to be.
    | None      -- ^ Do not qualify any function.

data LayoutChoice = PreferNestedLayout  -- ^ Prefer
                                        -- a                      f a
                                        -- + b      respectively    b
                                        --   + ...                  c
                                        -- if an expression does not fit the page
                  | PreferFilledLayout  -- ^ Prefer
                                        -- a + b                  f a b
                                        -- + c + d  respectively  c d
                                        -- if an expression does not fit the page

data Options = Options
    { pageWidth         :: Int
    , indentationWidth  :: Int
    , qualification     :: Qualification
    , moduleName        :: String
    {- Debugging flag (show signature of local functions or not). -}
    , showLocalSigs     :: Bool
    , layoutChoice      :: LayoutChoice
    {- A collection of all to this module visible types (i.e. all imported
       [prelude too] and self defined types) -- used to determine how to qualify,
       if Qualification`OnDemand` was chosen. -}
    , visibleTypes      :: Collection QName
    {- A collection of all to this module visible functions and constructors
       (i.e. all imported [prelude too] and self defined ones) -- used to
       determine how to qualify, if Qualification `OnDemand` was chosen. -}
    , visibleFunctions  :: Collection QName
    {- A collection of currently visible (depending on context) variables.
       Used to determine how to qualify, if Qualification `OnDemand` was chosen.
    -}
    , visibleVariables  :: Collection CVarIName
    }

--- `defaultOptions = options 78 2 Imports "" []`.
--- Therefore use these options only with functions like
--- 'prettyCurryProg' or 'ppCurryProg', because they will overwrite the module
--- name anyway. Also avoid setting on demand qualification, because no
--- information about related modules is given.
defaultOptions :: Options
defaultOptions = options 78 2 Imports "" []

--- @param pw - the page width to use
--- @param iw - the indentation width to use
--- @param q - the qualification method to use
--- @param m - the name of the current module
--- @param rels - A list of all to the current module related modules, i.e. the
---               current module itself and all its imports (including prelude).
---               The current module must be the head of that list.
--- @return options with the desired behavior
options :: Int
        -> Int
        -> Qualification
        -> MName
        -> [CurryProg]
        -> Options
options pw iw q m rels =
    let o = Options { pageWidth        = pw
                    , indentationWidth = iw
                    , qualification    = q
                    , moduleName       = m
                    , showLocalSigs    = False
                    , layoutChoice     = PreferNestedLayout
                    , visibleTypes     = emptyCol
                    , visibleFunctions = emptyCol
                    , visibleVariables = emptyCol }
    in  setRelatedMods rels o

--- Sets the page width of the pretty printer options.
setPageWith :: Int -> Options -> Options
setPageWith pw o = o { pageWidth = pw }

--- Sets the indentation width of the pretty printer options.
setIndentWith :: Int -> Options -> Options
setIndentWith iw o = o { indentationWidth = iw }

--- Sets the qualification method to be used by the pretty printer.
setQualification :: Qualification -> Options -> Options
setQualification q o = o { qualification = q }

--- Sets the name of the current module in the pretty printer options.
setModName :: MName -> Options -> Options
setModName m o = o { moduleName = m }

--- Sets the preferred layout in the pretty printer options.
setLayoutChoice :: LayoutChoice -> Options -> Options
setLayoutChoice lc o = o { layoutChoice = lc }

--- Sets the related modules in the pretty printer options. See 'options' to
--- read a specification of "related modules".
setRelatedMods :: [CurryProg] -> Options -> Options
setRelatedMods [] o = o
setRelatedMods (currentMod:imports) o =
    o { visibleTypes = vts, visibleFunctions = vfs }
    where vts = fromList $ map typeName (types currentMod)
                        ++ collect publicTypeNames
          vfs = fromList $ concat [ map funcName $ functions currentMod
                                  , collect publicFuncNames
                                  , map consName $ constructors currentMod
                                  , collect publicConsNames ]
          collect proj = foldr union [] $ map proj imports

--- precedence of top level (pattern or application) context -- lowest
tlPrec      :: Int
tlPrec      = 0
--- precedence of infix (pattern or application) context
infAppPrec  :: Int
infAppPrec  = 1
--- precedence of standard prefix (pattern or application) context
prefAppPrec :: Int
prefAppPrec = 2
--- precedence of atoms (variables, literals, tuples, lists ...)
highestPrec :: Int
highestPrec = 3

--- Shows a pretty formatted version of an abstract Curry Program.
--- The options for pretty-printing are the 'defaultOptions'.
--- @param prog - a curry prog
--- @return a string, which represents the input program `prog`
showCProg :: CurryProg -> String
showCProg = prettyCurryProg defaultOptions

--- pretty-print the document generated by 'ppCurryProg', using the page width
--- specified by given options.
prettyCurryProg :: Options -> CurryProg -> String
prettyCurryProg opts cprog = pretty (pageWidth opts) $ ppCurryProg opts cprog

--- pretty-print a CurryProg (the representation of a program, written in curry,
--- using AbstractCurry) according to given options. This function will overwrite
--- the module name given by options with the name encapsulated in CurryProg.
ppCurryProg :: Options -> CurryProg -> Doc
ppCurryProg opts (CurryProg m ms ts fs os) = vsepBlank
    [ (nest' opts' $ sep [ text "module" <+> ppMName m, ppExports opts' ts fs])
       </> where_
    , ppImports opts' ms
    , vcatMap (ppCOpDecl opts') os
    , vsepBlankMap (ppCTypeDecl opts') ts
    , vsepBlankMap (ppCFuncDecl opts') fs ]
    where opts' = opts { moduleName = m }

--- pretty-print a module name (just a string).
ppMName :: MName -> Doc
ppMName = text

--- pretty-print exports, i.e. all type and function declarations which are
--- public.
--- extract the type and function declarations which are public and gather their
--- qualified names in a list.
ppExports :: Options -> [CTypeDecl] -> [CFuncDecl] -> Doc
ppExports opts ts fs
    | null pubTs  && null pubFs  = parens empty -- nothing is exported
    | null privTs && null privFs
                  && null privCs = empty        -- everything is exported
    | otherwise                  = filledTupledSpaced $ map tDeclToDoc pubTs
                                                     ++ map fDeclToDoc pubFs
    where (pubTs, privTs)  = partition isPublicTypeDecl ts
          (pubFs, privFs)  = partition isPublicFuncDecl fs
          privCs           = filter ((== Private) . consVis)
                           . concatMap typeCons $ ts
          isPublicTypeDecl = (== Public) . typeVis
          isPublicFuncDecl = (== Public) . funcVis
          tDeclToDoc       = on' (<>)
                                 (ppQTypeParsIfInfix opts . typeName)
                                 (ppConsExports opts . typeCons)
          fDeclToDoc = ppQFuncParsIfInfix opts . funcName

-- internal use only
ppConsExports :: Options -> [CConsDecl] -> Doc
ppConsExports opts cDecls
    | null pubCs  = empty
    | null privCs = parens $ dot <> dot
    | otherwise   = filledTupled $ map cDeclToDoc pubCs
    where (pubCs, privCs)  = partition isPublicConsDecl cDecls
          isPublicConsDecl = (== Public) . consVis
          cDeclToDoc       = ppQFuncParsIfInfix opts . consName


--- pretty-print imports (list of module names) by prepending the word "import"
--- to the module name.
ppImports :: Options -> [MName] -> Doc
ppImports _ imps = vcatMap (\m -> text "import" <+> ppMName m)
                           (filter (/= "Prelude") imps)

--- pretty-print operator precedence declarations.
ppCOpDecl :: Options -> COpDecl -> Doc
ppCOpDecl _ (COp qn fix p) =
    hsep [ppCFixity fix, int p, genericPPName (bquotesIf . not . isInfixId) qn]

--- pretty-print the fixity of a function.
ppCFixity :: CFixity -> Doc
ppCFixity CInfixOp  = text "infix"
ppCFixity CInfixlOp = text "infixl"
ppCFixity CInfixrOp = text "infixr"

--- pretty-print type declarations, like `data ... = ...`, `type ... = ...` or
--- `newtype ... = ...`.
ppCTypeDecl :: Options -> CTypeDecl -> Doc
ppCTypeDecl opts (CType qn _ tVars cDecls)
    = hsep [ text "data", ppType qn, ppCTVarINames opts tVars
           , if null cDecls then empty else ppCConsDecls opts cDecls]
ppCTypeDecl opts (CTypeSyn qn _ tVars tExp)
    = hsep [ text "type", ppType qn, ppCTVarINames opts tVars
           , align $ equals <+> ppCTypeExpr opts tExp]
ppCTypeDecl opts (CNewType qn _ tVars cDecl)
    = hsep [ text "newtype", ppType qn, ppCTVarINames opts tVars, equals
           , ppCConsDecl opts cDecl]

--- pretty-print a list of constructor declarations, including the `=` sign.
ppCConsDecls :: Options -> [CConsDecl] -> Doc
ppCConsDecls opts cDecls =
    align . sep $ [equals <+> ppCConsDecl opts (head cDecls)]
               ++ map ((bar <+>) . (ppCConsDecl opts)) (tail cDecls)

--- pretty-print a constructor declaration.
ppCConsDecl :: Options -> CConsDecl -> Doc
ppCConsDecl opts (CCons   qn _ tExps ) = ppFunc qn
                                     <+> hsepMap (ppCTypeExpr' 2 opts) tExps
ppCConsDecl opts (CRecord qn _ fDecls) =
    ppFunc qn <+> alignedSetSpaced (map (ppCFieldDecl opts) fDecls)

--- pretty-print a record field declaration (`field :: type`).
ppCFieldDecl :: Options -> CFieldDecl -> Doc
ppCFieldDecl opts (CField qn _ tExp) = hsep [ ppFunc qn
                                            , doubleColon
                                            , ppCTypeExpr opts tExp ]

--- pretty-print a function declaration.
ppCFuncDecl :: Options -> CFuncDecl -> Doc
ppCFuncDecl opts fDecl@(CFunc qn _ _ tExp _) =
    ppCFuncSignature opts qn tExp <$!$> ppCFuncDeclWithoutSig opts fDecl
ppCFuncDecl opts (CmtFunc cmt qn a v tExp rs) =
    vsepMap (text . ("--- " ++)) (lines cmt)
    <$!$> ppCFuncDecl opts (CFunc qn a v tExp rs)

--- pretty-print a function declaration without signature.
ppCFuncDeclWithoutSig :: Options -> CFuncDecl -> Doc
ppCFuncDeclWithoutSig opts fDecl@(CFunc qn _ _ _ rs) =
    ppCRules funcDeclOpts qn rs
    where funcDeclOpts = addFuncNamesToOpts (funcNamesOfFDecl fDecl) opts
ppCFuncDeclWithoutSig opts (CmtFunc cmt qn a v tExp rs) =
    vsepMap (text . ("--- " ++)) (lines cmt)
    <$!$> ppCFuncDeclWithoutSig opts (CFunc qn a v tExp rs)

--- pretty-print a function signature according to given options.
ppCFuncSignature :: Options -> QName -> CTypeExpr -> Doc
ppCFuncSignature opts qn tExp
    | isUntyped tExp = empty
    | otherwise = nest' opts
                $ sep [ genericPPName parsIfInfix qn
                      , align $ doubleColon <+> ppCTypeExpr opts tExp ]
    where isUntyped te = te == CTCons (pre "untyped") []

--- pretty-print a type expression.
ppCTypeExpr :: Options -> CTypeExpr -> Doc
ppCTypeExpr = ppCTypeExpr' tlPrec

-- Internal use only: Pretty-print a type expression and make use of supplied
-- precedence context. The supplied number represents the precedence of the
-- enclosing expression. Higher values mean more precedence, so if the nested
-- expression has lower precedence than the enclosing expression, the nested one
-- has to be enclosed in parentheses.
ppCTypeExpr' :: Int -> Options -> CTypeExpr -> Doc
ppCTypeExpr' _ opts (CTVar     tvar) = ppCTVarIName opts tvar
ppCTypeExpr' p opts (CFuncType tExp1 tExp2) =
    parensIf (p > tlPrec)
  $ sep [ ppCTypeExpr' 1 opts tExp1, rarrow <+> ppCTypeExpr opts tExp2]
ppCTypeExpr' p opts (CTCons qn tExps)
    | null tExps     = ppQType opts qn
    | isListCons qn  = brackets . (ppCTypeExpr opts) . head $ tExps -- assume singleton
    | isTupleCons qn = alignedTupled $ map (ppCTypeExpr opts) tExps
    | otherwise      = parensIf (p >= 2)
                     $ ppQType opts qn
                   <+> hsepMap (ppCTypeExpr' 2 opts) tExps

--- pretty-print a list of type variables horizontally separating them by `space`.
ppCTVarINames :: Options -> [CTVarIName] -> Doc
ppCTVarINames opts = hsepMap (ppCTVarIName opts)

--- pretty-print a type variable (currently the Int is ignored).
ppCTVarIName :: Options -> CTVarIName -> Doc
ppCTVarIName _ (_, tvar) = text tvar

--- pretty-print a list of function rules, concatenated vertically.
ppCRules :: Options -> QName -> [CRule] -> Doc
ppCRules opts qn rs
    | null rs   = genericPPName parsIfInfix qn <+> text "external"
    | otherwise = vcatMap (ppCRule opts qn) rs

--- pretty-print a rule of a function. Given a function
--- `f x y = x * y`, then `x y = x * y` is a rule consisting of `x y` as list of
--- patterns and `x * y` as right hand side.
ppCRule :: Options -> QName -> CRule -> Doc
ppCRule opts qn rule@(CRule ps rhs) =
    (nest' opts $ sep [ ppCPattern opts (CPComb qn ps) {- exploit similarity
                                                          between left hand side
                                                          of rule and constructor
                                                          pattern -}
                        <+> (case rhs of
                                  CSimpleRhs  _ _ -> equals
                                  CGuardedRhs _ _ -> empty )
                      , ppFuncRhs rhsOpts rhs ] )
 $$ if null lDecls
       then empty
       else indent' opts $ ppWhereDecl whereOpts lDecls
    where lDecls    = ldeclsOfRule rule
          whereOpts = addVarsToOpts (concatMap varsOfPat ps) opts
          rhsOpts   = last $ optsWithIncreasingNamespaces
                                varsOfLDecl
                                funcNamesOfLDecl
                                lDecls
                                whereOpts

--- pretty-print a pattern expression.
ppCPattern :: Options -> CPattern -> Doc
ppCPattern = ppCPattern' tlPrec

-- Internal use only: Pretty-print a pattern expression and make use of supplied
-- precedence context. The supplied number represents the precedence of the
-- enclosing pattern. Higher values mean more precedence, so if the nested
-- pattern has lower precedence than the enclosing pattern, the nested one has
-- to be enclosed in parentheses.
ppCPattern' :: Int -> Options -> CPattern -> Doc
ppCPattern' _ opts (CPVar  pvar) = ppCVarIName opts pvar
ppCPattern' _ opts (CPLit  lit ) = ppCLiteral opts lit
ppCPattern' p opts pat@(CPComb qn ps)
    | null ps        = parsIfInfix qn qnDoc
    | isApp qn       = parensIf (p >= prefAppPrec)
                     $ ppCPattern' infAppPrec opts (ps !! 0)
                   <+> ppCPattern' prefAppPrec opts (ps !! 1)
    | isTupleCons qn = filledTupled . map (ppCPattern opts) $ ps
    | isFinLis pat   = let ps' = fromJust $ extractFiniteListPattern pat
                       in  alignedList . map (ppCPattern opts) $ ps'
    | isInfixId qn   =
        case ps of [l, r] -> parensIf (p >= infAppPrec)
                           $ hsep [ ppCPattern' p' opts l, qnDoc
                                  , ppCPattern' p' opts r ]
                   _      -> prefixApp
    | otherwise      = prefixApp
    where qnDoc     = ppQFunc opts qn
          isApp     = (== ("Prelude", "apply"))
          p'        = if isInfixId qn then infAppPrec else prefAppPrec
          prefixApp = parensIf (p >= prefAppPrec) . nest' opts
                    $ sep [ parsIfInfix qn qnDoc
                          , align . (case layoutChoice opts of
                                          PreferFilledLayout -> fillSep
                                          PreferNestedLayout -> sep)
                                  . map (ppCPattern' p' opts) $ ps ]
          isFinLis  = isJust . extractFiniteListPattern
ppCPattern' _ opts (CPAs pvar p)
    = hcat [ppCVarIName opts pvar, at, ppCPattern' highestPrec opts p]
ppCPattern' p opts (CPFuncComb qn ps) = ppCPattern' p opts (CPComb qn ps)
ppCPattern' _ opts (CPLazy     p     ) = tilde <> ppCPattern' highestPrec opts p
ppCPattern' _ opts (CPRecord   qn rps) =
    ppQFunc opts qn <+> alignedSetSpaced (map (ppCFieldPattern opts) rps)

--- pretty-print a pattern variable (currently the Int is ignored).
ppCVarIName :: Options -> CVarIName -> Doc
ppCVarIName _ (_, pvar) = text pvar

--- pretty-print given literal (Int, Float, ...).
ppCLiteral :: Options -> CLiteral -> Doc
ppCLiteral _ (CIntc i)    = int i
ppCLiteral _ (CFloatc f)  = float f
ppCLiteral _ (CCharc c)   = text $ show c
ppCLiteral _ (CStringc s)
    | null s    = text "\"\"" -- necessary for pakcs
    | otherwise = text $ show s

--- pretty-print a record pattern
ppCFieldPattern :: Options -> CField CPattern -> Doc
ppCFieldPattern opts (qn, p) = ppQFunc opts qn <+> equals <+> ppCPattern opts p

--- pretty-print the right hand side of a rule (or case expression), including
--- the d sign, where `d` is the relation (as doc) between the left hand side
--- and the right hand side -- usually this is one of `=`, `->`.
--- If the right hand side contains local declarations, they will be pretty
--- printed too, further indented.
ppCRhs :: Doc -> Options -> CRhs -> Doc
ppCRhs d opts rhs = case rhs of
        CSimpleRhs  exp   lDecls ->
            (nest' opts $ sep [d, ppCExpr (expAndGuardOpts lDecls) exp])
         $$ maybePPlDecls lDecls
        CGuardedRhs conds lDecls ->
            ppCGuardedRhs (expAndGuardOpts lDecls) d conds
         $$ maybePPlDecls lDecls
    where expAndGuardOpts ls = last $ optsWithIncreasingNamespaces
                                        varsOfLDecl
                                        funcNamesOfLDecl
                                        ls
                                        opts
          maybePPlDecls ls   = if null ls
                                  then empty
                                  else indent' opts (ppWhereDecl opts ls)

--- Like 'ppCRhs', but do not pretty-print local declarations.
--- Instead give caller the choice how to handle the declarations. For example
--- the function 'ppCRule' uses this to prevent local declarationsfrom being
--- further indented.
ppFuncRhs :: Options -> CRhs -> Doc
{- No further enrichment of options necessary -- it was done in 'ppCRule' -}
ppFuncRhs opts (CSimpleRhs  exp _)   = ppCExpr opts exp
ppFuncRhs opts (CGuardedRhs conds _) = ppCGuardedRhs opts equals conds

ppCaseRhs :: Options -> CRhs -> Doc
ppCaseRhs = ppCRhs rarrow

--- pretty-print guard, i.e. the `| cond d exp` part of a right hand side, where
--- `d` is the relation (as doc) between `cond` and `exp` -- usually this is
--- one of `=`, `->`.
ppCGuardedRhs :: Options -> Doc -> [(CExpr, CExpr)] -> Doc
ppCGuardedRhs opts d = align . vvsepMap ppCGuard
    where ppCGuard (e1, e2) = sep [ bar <+> ppCExpr opts e1
                                  , d   <+> ppCExpr opts e2 ]

--- pretty-print local declarations . If the second argument is `text "where"`,
--- pretty-print a `where` block. If the second argument is `text "let"`,
--- pretty-print a `let` block without `in`.
ppCLocalDecls :: Options -> Doc -> [CLocalDecl] -> Doc
ppCLocalDecls opts d lDecls =
    (d <+>) . align . vvsepMap (ppCLocalDecl lDeclOpts) $ lDecls
    where lDeclOpts = last $ optsWithIncreasingNamespaces
                                varsOfLDecl
                                funcNamesOfLDecl
                                lDecls
                                opts

--- pretty-print local declarations (the part that follows the `where` keyword).
ppCLocalDecl :: Options -> CLocalDecl -> Doc
ppCLocalDecl opts (CLocalFunc fDecl) =
    if showLocalSigs opts
       then ppCFuncDecl opts fDecl
       else ppCFuncDeclWithoutSig opts fDecl
ppCLocalDecl opts (CLocalPat  p rhs) =
    hsep [ ppCPattern opts p, ppCRhs equals rhsOpts rhs ]
    where rhsOpts = addVarsToOpts (varsOfPat p) opts
ppCLocalDecl opts (CLocalVars pvars) =
    (<+> text "free") $ hsep $ punctuate comma $ map (ppCVarIName opts) pvars

--- pretty-print a `where` block, in which the word `where` stands alone in a
--- single line, above the following declarations.
ppWhereDecl :: Options -> [CLocalDecl] -> Doc
ppWhereDecl opts lDecls = (where_ $$)
                        . indent' opts
                        . vvsepMap (ppCLocalDecl lDeclOpts) $ lDecls
    where lDeclOpts = last $ optsWithIncreasingNamespaces
                                varsOfLDecl
                                funcNamesOfLDecl
                                lDecls
                                opts

--- pretty-print a `let` block without `in`. In contrast to 'ppWhereDecl', the
--- word `let` is in the same line as the first local declaration.
ppLetDecl :: Options -> [CLocalDecl] -> Doc
ppLetDecl opts = ppCLocalDecls opts (text "let")

--- pretty-print an expression.
ppCExpr :: Options -> CExpr -> Doc
ppCExpr = ppCExpr' tlPrec

-- Internal use only: Pretty-print an expression and make use of supplied
-- precedence context. The supplied number represents the precedence of the
-- enclosing expression. Higher values mean more precedence, so if the nested
-- expression has lower precedence than the enclosing expression, the nested one
-- has to be enclosed in parentheses.
ppCExpr' :: Int -> Options -> CExpr -> Doc
ppCExpr' _ opts (CVar     pvar) = ppCVarIName opts pvar
ppCExpr' _ opts (CLit     lit ) = ppCLiteral opts lit
ppCExpr' _ opts (CSymbol  qn  ) = ppQFuncParsIfInfix opts qn
ppCExpr' p opts app@(CApply f exp)
    | isITE app
        = parensIf (p > tlPrec)
        $ let (c, t, e) = fromJust $ extractITE app
          in  text "if" <+> (align $ sep [ ppCExpr opts c
                                         , text "then" <+> ppCExpr opts t
                                         , text "else" <+> ppCExpr opts e])
    | isTup app = let args = fromJust $ extractTuple app
                  in  alignedTupled (map (ppCExpr opts) args)
    | isFinLis app =
      let elems = fromJust $ extractFiniteListExp app
      in  (case layoutChoice opts of
             PreferNestedLayout -> alignedList
             PreferFilledLayout -> filledList )
            (map (ppCExpr opts) elems)
    | isInf app
        = parensIf (p >= infAppPrec)
        $ let (op, l, r) = fromJust $ extractInfix app
          in  (case layoutChoice opts of
                    PreferNestedLayout -> ppNestedWay
                    PreferFilledLayout -> ppFilledWay)
                        (ppCExpr' infAppPrec opts l)
                        (ppQFunc opts op)
                        (ppCExpr' infAppPrec opts r)
    | otherwise = parensIf (p >= prefAppPrec)
                $ (case layoutChoice opts of
                        PreferNestedLayout -> ppNestedWay
                        PreferFilledLayout -> ppFilledWay)
                            (ppCExpr' infAppPrec opts f)
                            empty
                            (ppCExpr' prefAppPrec opts exp)
    where isITE    = isJust . extractITE
          isInf    = isJust . extractInfix
          isTup    = isJust . extractTuple
          isFinLis = isJust . extractFiniteListExp
          ppNestedWay l sepa r = align . nest 1 $ sep [l, sepa <+> r]
          ppFilledWay l sepa r = nest 1 $ fillSep [l, sepa, r]
ppCExpr' p opts (CLambda ps exp) =
    parensIf (p > tlPrec) . nest' opts
  $ sep [ backslash <> hsepMap (ppCPattern' prefAppPrec opts) ps
                   <+> rarrow
        , ppCExpr expOpts exp]
    where expOpts = addVarsToOpts (concatMap varsOfPat ps) opts
ppCExpr' p opts (CLetDecl lDecls exp) =
    parensIf (p > tlPrec) . align
    {- 'ppLetDecl' itself ensures the correct handling of opts -}
  $ sep [ ppLetDecl opts lDecls, text "in" <+> ppCExpr expOpts exp]
    where expOpts = last $ optsWithIncreasingNamespaces
                            varsOfLDecl
                            funcNamesOfLDecl
                            lDecls
                            opts
ppCExpr' p opts (CDoExpr stms) =
    parensIf (p > tlPrec)
  $ text "do" <+> align (vvsep $ zipWith ppCStatement statOptsList stms)
    where statOptsList = optsWithIncreasingNamespaces
                            varsOfStat
                            funcNamesOfStat
                            stms
                            opts
ppCExpr' _ opts (CListComp exp stms) =
    brackets $ hsep [ ppCExpr expOpts exp, bar
                    , hsep $ punctuate (comma <> space)
                                       (zipWith ppCStatement statOptsList stms)]
    where expOpts      = last statOptsList
          statOptsList = optsWithIncreasingNamespaces
                            varsOfStat
                            funcNamesOfStat
                            stms
                            opts

ppCExpr' p opts (CCase cType exp cases) =
    parensIf (p > tlPrec) . align . nest' opts
  $ sep [ ppCCaseType cType <+> ppCExpr opts exp <+> text "of"
        , ppCases opts cases]
ppCExpr' p opts (CTyped exp tExp) =
    parensIf (p > tlPrec)
  $ hsep [ppCExpr opts exp, doubleColon, ppCTypeExpr opts tExp]
ppCExpr' _ opts (CRecConstr qn rFields) =
    ppQFunc opts qn <+> ppRecordFields opts rFields
ppCExpr' p opts (CRecUpdate exp rFields) = ppCExpr' p opts exp
                                       <+> ppRecordFields opts rFields

ppCStatement :: Options -> CStatement -> Doc
ppCStatement opts (CSExpr exp       ) = ppCExpr opts exp
ppCStatement opts (CSPat  pat    exp) = ppCPattern opts pat
                                    <+> larrow
                                    <+> ppCExpr opts exp
ppCStatement opts (CSLet  lDecls    ) = ppLetDecl opts lDecls

--- pretty-print `case`, `fcase` keywords.
ppCCaseType :: CCaseType -> Doc
ppCCaseType CRigid = text "case"
ppCCaseType CFlex  = text "fcase"

--- pretty-print a list of case expressions, i.e. the `p1 -> e1`,...,`pn -> en`,
--- transitions, vertically aligned.
ppCases :: Options -> [(CPattern, CRhs)] -> Doc
ppCases opts = align . vvsepMap (ppCase opts)

--- pretty-print a case expression.
ppCase :: Options -> (CPattern, CRhs) -> Doc
ppCase opts (p, rhs) = ppCPattern opts p <+> ppCaseRhs rhsOpts rhs
    where rhsOpts = addVarsToOpts (varsOfPat p) opts

--- pretty-print record field assignments like this:
---     { lab1 = exp1, ..., labn expn }
--- if it fits the page, or
---     { lab1 = exp1
---     , ...
---     , labn = expn }
--- otherwise.
ppRecordFields :: Options -> [CField CExpr] -> Doc
ppRecordFields opts = alignedSetSpaced . map (ppRecordField opts)

--- pretty-print a record field assignment (`fieldLabel = exp`).
ppRecordField :: Options -> CField CExpr -> Doc
ppRecordField opts (qn, exp) = ppQFunc opts qn <+> equals <+> ppCExpr opts exp

--- pretty-print a QName qualified according to given options.
--- @param visNames - Depending on call, this is the namespace of visible types
---                   or of visible functions. Used to determine if `qn` is
---                   ambiguous, in case the qualification method 'OnDemand' was
---                   chosen
--- @param visVars - The in current context visible variables.
--- @param g - A doc tranformer used to manipulate (f.e. surround with
---            parentheses) the QName, after it was (maybe) qualified.
--- @param opts - The options to use.
--- @param qn - The `QName` to pretty-print.
--- @return A pretty-printed `QName`, maybe qualified (depending on settings).
genericPPQName :: Collection QName
               -> Collection CVarIName
               -> (QName -> Doc -> Doc)
               -> Options
               -> QName
               -> Doc
genericPPQName visNames visVars g opts qn@(m, f)
    | qnIsBuiltIn = name
    | null m      = name -- assume local declaration
    | otherwise   =
        case qualification opts of
             Full     -> qName
             Imports  -> if m == moduleName opts || m == "Prelude"
                            then name
                            else qName
             OnDemand -> if m == moduleName opts
                            then name
                            else odName -- at this point we know qn is imported
             None     -> name
    where qnIsBuiltIn = or (map ($ qn) [ isUnitCons , isListCons
                                       , isTupleCons, isConsCons ])
          name        = g qn (text f)
          qName       = g qn $ ppMName m <> dot <> text f
          odName      = if isShadowed qn || isAmbiguous qn
                           then qName
                           else name
          isAmbiguous n = anyCol (on' (&&) (sameName n) (diffMod n)) visNames
          isShadowed n  = anyCol (sameName n) visVars
          sameName      :: (a, c) -> (b, c) -> Bool
          sameName      = \(_,x) (_,y) -> x == y
          diffMod       = (/=) `on` fst

genericPPName :: (QName -> Doc -> Doc) -> QName -> Doc
genericPPName f qn = f qn $ text . snd $ qn

--- pretty-print a function name or constructor name qualified according to
--- given options. Use 'ppQType' or 'ppType' for pretty-printing type names.
ppQFunc :: Options -> QName -> Doc
ppQFunc opts = genericPPQName (visibleFunctions opts)
                              (visibleVariables opts)
                              (flip const)
                              opts

--- Like 'ppQFunc', but surround name with parentheses if it is an infix
--- identifier.
ppQFuncParsIfInfix :: Options -> QName -> Doc
ppQFuncParsIfInfix opts = genericPPQName (visibleFunctions opts)
                                         (visibleVariables opts)
                                         parsIfInfix
                                         opts

--- pretty-print a function name or constructor name non-qualified.
--- Use 'ppQType' or 'ppType' for pretty-printing type names.
ppFunc :: QName -> Doc
ppFunc = genericPPName (flip const)

--- pretty-print a type (`QName`) qualified according to given options.
ppQType :: Options -> QName -> Doc
ppQType opts = genericPPQName (visibleTypes opts) emptyCol (flip const) opts

--- Like 'ppQType', but surround name with parentheses if it is an infix
--- identifier.
ppQTypeParsIfInfix :: Options -> QName -> Doc
ppQTypeParsIfInfix opts =
    genericPPQName (visibleTypes opts) emptyCol parsIfInfix opts

--- pretty-print a type (`QName`) non-qualified.
ppType :: QName -> Doc
ppType = genericPPName (flip const)

-- Helping function (diagnosis)
--- Check whether an operator is an infix identifier.
isInfixId :: QName -> Bool
isInfixId = all (`elem` "~!@#$%^&*+-=<>:?./|\\") . snd

--- Check whether an identifier represents the unit constructor
isUnitCons :: QName -> Bool
isUnitCons (_, i) = i == "()"

--- Check whether an identifier represents the empty list constructor
isListCons :: QName -> Bool
isListCons (_, i) = i == "[]"

--- Check whether an identifier represents the list constructor `:`
isConsCons :: QName -> Bool
isConsCons (_, i) = i == ":"

--- Check whether an identifier represents a tuple constructor
isTupleCons :: QName -> Bool
isTupleCons (_, i) = i == mkTuple (length i)
  where mkTuple n = '(' : replicate (n - 2) ',' ++ ")"

--- Check if given application tree represents an if then else construct.
--- If so, return the condition, the "then expression" and the "else expression".
--- Otherwise, return `Nothing`.
extractITE :: CExpr -> Maybe (CExpr, CExpr, CExpr)
extractITE e = case e of
                    CApply (CApply (CApply (CSymbol ("Prelude","if_then_else"))
                                            cond)
                                    tExp)
                            fExp -> Just (cond, tExp, fExp)
                    _            -> Nothing

--- Check if given application tree represents an infix operator application.
--- If so, return the operator, its left and its right argument. Otherwise,
--- return `Nothing`.
extractInfix :: CExpr -> Maybe (QName, CExpr, CExpr)
extractInfix e
    = case e of CApply (CApply (CSymbol s)
                                 e1)
                        e2
                    | isInfixId s -> Just (s, e1, e2)
                _                 -> Nothing

--- Check if given application tree represents a tuple contructor application.
--- If so, return the constructor and its arguments in a list. Otherwise, return
--- `Nothing`.
extractTuple :: CExpr -> Maybe [CExpr]
extractTuple = extractTuple' []
    where extractTuple' es exp
            = case exp of
                   CApply  f e                 -> extractTuple' (e:es) f
                   CSymbol s   | isTupleCons s -> Just es
                   _                           -> Nothing

--- Check if given application tree represents a finite list `[x1, ..., xn]`.
--- If so, return the list elements in a list. Otherwise, return `Nothing`.
extractFiniteListExp :: CExpr -> Maybe [CExpr]
extractFiniteListExp = extractFiniteListExp' []
    where extractFiniteListExp' es exp =
            case exp of
                 CApply (CApply (CSymbol f)
                                 e)
                         arg | isConsCons f -> extractFiniteListExp' (e:es) arg
                 CSymbol s   | isListCons s -> Just $ reverse es
                 _                          -> Nothing

--- Check if given construct pattern represents a finite list `[x1, ..., xn]`.
--- If so, return the list elements in a list. Otherwise, return `Nothing`.
extractFiniteListPattern :: CPattern -> Maybe [CPattern]
extractFiniteListPattern = extractFiniteListPattern' []
    where extractFiniteListPattern' es pat =
            case pat of
                 CPComb qn [e, t] | isConsCons qn
                                  -> extractFiniteListPattern' (e:es) t
                 CPComb qn []     | isListCons qn
                                  -> Just $ reverse es
                 _                -> Nothing

-- Helping functions (pretty-printing)
hsepMap :: (a -> Doc) -> [a] -> Doc
hsepMap f = hsep . map f

vcatMap :: (a -> Doc) -> [a] -> Doc
vcatMap f = vcat . map f

vsepMap :: (a -> Doc) -> [a] -> Doc
vsepMap f = vsep . map f

vsepBlankMap :: (a -> Doc) -> [a] -> Doc
vsepBlankMap f = vsepBlank . map f

vvsep :: [Doc] -> Doc
vvsep = compose (<$!$>)

vvsepMap :: (a -> Doc) -> [a] -> Doc
vvsepMap f = vvsep . map f

fillSepMap :: (a -> Doc) -> [a] -> Doc
fillSepMap f = fillSep . map f

encloseSepSpaced :: Doc -> Doc -> Doc -> [Doc] -> Doc
encloseSepSpaced l r s = encloseSep (l <> space) (space <> r) (s <> space)

alignedList :: [Doc] -> Doc
alignedList = encloseSep lbracket rbracket comma

filledList :: [Doc] -> Doc
filledList = fillEncloseSep lbracket rbracket comma

alignedSetSpaced :: [Doc] -> Doc
alignedSetSpaced = encloseSepSpaced lbrace rbrace comma

alignedTupled :: [Doc] -> Doc
alignedTupled = encloseSep lparen rparen comma

filledTupled :: [Doc] -> Doc
filledTupled = fillEncloseSep lparen rparen comma

filledTupledSpaced :: [Doc] -> Doc
filledTupledSpaced = fillEncloseSepSpaced lparen rparen comma

nest' :: Options -> Doc -> Doc
nest' opts = nest (indentationWidth opts)

indent' :: Options -> Doc -> Doc
indent' opts = indent (indentationWidth opts)

bquotesIf :: Bool -> Doc -> Doc
bquotesIf b d = if b then bquotes d else d

parsIfInfix :: QName -> Doc -> Doc
parsIfInfix = parensIf . isInfixId

larrow :: Doc
larrow = text "<-"

where_ :: Doc
where_ = text "where"

nil :: Doc
nil = text "[]"

-- Helping functions (various)
on' :: (b -> b -> c) -> (a -> b) -> (a -> b) -> a -> c
on' comb f g x = f x `comb` g x

-- Helping functions (CRUD functions for Collection)
emptyCol :: Collection a
emptyCol = []

appendCol :: Collection a -> Collection a -> Collection a
appendCol = (++)

anyCol :: (a -> Bool) -> Collection a -> Bool
anyCol = any

fromList :: [a] -> Collection a
fromList = id

-- Helping functions (management of visible names)
addVarsToOpts :: [CVarIName] -> Options -> Options
addVarsToOpts vs o =
    o { visibleVariables = fromList vs `appendCol` visibleVariables o }

addFuncNamesToOpts :: [QName] -> Options -> Options
addFuncNamesToOpts ns o =
    o { visibleFunctions = fromList ns `appendCol` visibleFunctions o }

addVarsAndFuncNamesToOpts :: [CVarIName] -> [QName] -> Options -> Options
addVarsAndFuncNamesToOpts vs ns = addVarsToOpts vs . addFuncNamesToOpts ns

--- Generates a list of options with increasing numbers of visible variables
--- and function names. Resulting lists are useful to match the scopes of
--- do expressions and list comprehensions, where latter statements see previous
--- variables and functions names, but prior elements do not see subsequent
--- variables and function names.
--- Note that `last $ optsWithIncreasingNamespaces varsOf funcNamesOf xs opts`
--- are options which contain all variables and function names of xs.
--- @param varsOf - a projection function
--- @param funcNamesOf - a projection function
--- @xs - a list [x1, x2, ...] of elements to which the projection functions
---       will be applied
--- @param opts - root options
--- @return a list `[opts0, opts1, opts2, ...]`, where
---         `opts == opts0`,
---         `opts1 == opts0` plus vars and funcNames of `x1`,
---         `opts2 == opts1` plus vars and funcNames of `x2`,
---         ...
optsWithIncreasingNamespaces :: (a -> [CVarIName])
                             -> (a -> [QName])
                             -> [a]
                             -> Options
                             -> [Options]
optsWithIncreasingNamespaces varsOf funcNamesOf xs opts =
    scanl (flip . uncurry $ addVarsAndFuncNamesToOpts) opts varsAndFuncNamesOfXs
    where varsAndFuncNamesOfXs = map varsOf xs `zip` map funcNamesOf xs

-- Helping function (gather variables occurring in argument)
--- In contrast to `AbstractCurry.Select.varsOfLDecl`, this function does not
--- include variables of right hand sides.
varsOfLDecl :: CLocalDecl -> [CVarIName]
varsOfLDecl (CLocalFunc f      ) = varsOfFDecl f
varsOfLDecl (CLocalPat  p     _) = varsOfPat p
varsOfLDecl (CLocalVars lvars  ) = lvars

--- In contrast to `AbstractCurry.Select.varsOfFDecl`, this function does not
--- include variables of right hand sides.
varsOfFDecl :: CFuncDecl -> [CVarIName]
varsOfFDecl (CFunc     _ _ _ _ r) = concatMap varsOfRule r
varsOfFDecl (CmtFunc _ _ _ _ _ r) = concatMap varsOfRule r
    where varsOfRule (CRule pats _) = concatMap varsOfPat pats

--- In contrast to `AbstractCurry.Select.varsOfStat`, this function does not
--- include variables of right hand sides.
varsOfStat :: CStatement -> [CVarIName]
varsOfStat (CSExpr _   ) = []
varsOfStat (CSPat  p  _) = varsOfPat p
varsOfStat (CSLet  ld  ) = concatMap varsOfLDecl ld
