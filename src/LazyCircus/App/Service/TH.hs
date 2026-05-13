{-# LANGUAGE TemplateHaskell #-}

{- | Template Haskell macros for generating service library boilerplate.

PURPOSE: Generate a complete service library from a list of
  @(RequestType, ResponseType, ToolSpecs)@ triples, including the service
  data type, config type, 'IsInServiceLib' instances, builder function, and
  tool enumeration/dispatch/JSON types when tool specs are provided.
SCOPE: Service lib data type generation, config type generation,
  'IsInServiceLib' instance generation, builder function generation,
  tool enum type generation, tool info/description generation,
  'ToolCall'\/'ToolResponse' sum type generation, 'FromJSON' dispatch,
  'executeToolCall'\/'toolCallName'\/'encodeToolResponse' generation,
  and smart constructor generation for AI script integration.
-}
module LazyCircus.App.Service.TH (
    makeServiceLib,
) where

import Data.OpenApi.Schema (ToSchema, toInlinedSchema)
import Data.Text qualified as Text (unpack)
import RIO

import Data.Aeson (FromJSON, Result (..), ToJSON, Value, fromJSON, object, toJSON, withObject, (.:), (.=))
import Data.Char (toLower)
import Data.List (nub, (\\))

import Language.Haskell.TH

import LazyCircus.App.Service (
    HasFailbackValue (..),
    IsInServiceLib (..),
    ServiceHandler (..),
    ToolCallExec (..),
    ToolDescription (..),
    callService,
    createService,
 )
import LazyCircus.Scene.AI.Lang (AIScript)
import LazyCircus.Script (Script (..))

{- | Converts a type name to a camelCase field name by lowercasing the first character.
PRE-CONTRACT: The Name must represent a type constructor whose base name starts with an uppercase letter.
POST-CONTRACT: Result starts with a lowercase letter; the rest of the characters are unchanged.
-}
typeToFieldName :: Name -> String
typeToFieldName name =
    case nameBase name of
        [] -> []
        (c : cs) -> toLower c : cs

-- | Shared no-unpacking, no-strictness record field annotation.
recordBang :: Bang
recordBang = Bang NoSourceUnpackedness NoSourceStrictness

{- | Internal representation of a service pair with optional tool specifications.
  (fieldName, requestType, responseType, toolSpecs).
-}
type FieldPair = (String, Name, Name, [(Name, String, String)])

{- | Checks that request type names in the list are unique.
PRE-CONTRACT: None.
POST-CONTRACT: Returns () when all request names are unique; calls 'fail' otherwise.
-}
detectDuplicates :: [(Name, Name)] -> Q ()
detectDuplicates pairs = do
    let reqNames = map fst pairs
        dups = reqNames \\ nub reqNames
    unless (null dups) $
        fail $
            "makeServiceLib: duplicate request types: " <> show dups

{- | Validates that each constructor name appears in the given type's constructors.
PRE-CONTRACT: reqName must resolve to a 'DataD' or 'NewtypeD' via 'reify'.
POST-CONTRACT: Calls 'fail' if any constructor is not found; returns () otherwise.
-}
validateConstructors :: Name -> [Name] -> Q ()
validateConstructors reqName conNames = do
    info <- reify reqName
    actualCons <- case info of
        TyConI (DataD _ _ _ _ cons _) -> pure $ map conNameOf cons
        TyConI (NewtypeD _ _ _ _ con _) -> pure [conNameOf con]
        _ ->
            fail $
                "makeServiceLib: " <> nameBase reqName <> " is not a data or newtype"
    let actualConBases = map nameBase actualCons
    forM_ conNames $ \cn ->
        unless (nameBase cn `elem` actualConBases) $
            fail $
                "Constructor '"
                    <> nameBase cn
                    <> "' is not a constructor of type "
                    <> nameBase reqName
  where
    -- \| Extracts the constructor name from various Con declarations.
    conNameOf :: Con -> Name
    conNameOf (NormalC name _) = name
    conNameOf (RecC name _) = name
    conNameOf (InfixC _ name _) = name
    conNameOf (GadtC (n : _) _ _) = n
    conNameOf (RecGadtC (n : _) _ _) = n
    conNameOf (GadtC [] _ _) = error "conNameOf: GadtC with no names"
    conNameOf (RecGadtC [] _ _) = error "conNameOf: RecGadtC with no names"
    conNameOf (ForallC _ _ c) = conNameOf c

{- | Checks that enum constructor base names are unique across all tool specs.
PRE-CONTRACT: None.
POST-CONTRACT: Calls 'fail' if any constructor base name appears more than once.
-}
detectDuplicateEnumConstructors :: [(Name, String, String)] -> Q ()
detectDuplicateEnumConstructors allSpecs = do
    let conBaseNames = map (\(cn, _, _) -> nameBase cn) allSpecs
        dups = conBaseNames \\ nub conBaseNames
    unless (null dups) $
        fail $
            "makeServiceLib: duplicate enum constructor names across request types: "
                <> show dups

{- | Checks that tool-name strings are unique across all tool specs.
PRE-CONTRACT: None.
POST-CONTRACT: Calls 'fail' if any tool-name string appears more than once.
-}
detectDuplicateToolNameStrings :: [(Name, String, String)] -> Q ()
detectDuplicateToolNameStrings allSpecs = do
    let toolNames = map (\(_, toolName, _) -> toolName) allSpecs
        dups = toolNames \\ nub toolNames
    unless (null dups) $
        fail $
            "makeServiceLib: duplicate tool name strings: " <> show dups

{- | Checks that type base names (used as field name prefixes) are unique.
PRE-CONTRACT: None.
POST-CONTRACT: Calls 'fail' if any two request types have the same base name.
-}
detectDuplicateFieldNames :: [(Name, Name, [(Name, String, String)])] -> Q ()
detectDuplicateFieldNames rawPairs = do
    let baseNames = map (nameBase . (\(r, _, _) -> r)) rawPairs
        dups = baseNames \\ nub baseNames
    unless (null dups) $
        fail $
            "makeServiceLib: request types with duplicate base names produce "
                <> "conflicting field names: "
                <> show dups

-- ── Existing generators (adapted for FieldPair) ──────────────────────────

{- | Generates the service library data type declaration.
PRE-CONTRACT: libName is a valid Haskell constructor name; pairs is non-empty.
POST-CONTRACT: Returns a 'DataD' with one record constructor whose fields are
  named @{fieldName}Service@ with type @ServiceHandler ReqTy ResTy@.
-}
genServiceLibType :: String -> [FieldPair] -> Q Dec
genServiceLibType libName pairs = do
    let conName = mkName libName
    fields <- mapM mkField pairs
    pure $ DataD [] conName [] Nothing [RecC conName fields] []
  where
    mkField (fieldName, reqName, resName, _) = do
        let selName = mkName $ fieldName <> "Service"
            fieldType =
                ConT ''ServiceHandler
                    `AppT` ConT reqName
                    `AppT` ConT resName
        pure (selName, recordBang, fieldType)

{- | Generates the config data type declaration with an @m@ type parameter.
PRE-CONTRACT: libName is a valid Haskell constructor name; pairs is non-empty.
POST-CONTRACT: Returns a 'DataD' with @m@ as a type parameter and fields typed
  @ReqTy -> m ResTy@.
-}
genConfigType :: String -> [FieldPair] -> Q Dec
genConfigType libName pairs = do
    let conName = mkName $ libName <> "Config"
        mVar = PlainTV (mkName "m") BndrReq
    fields <- mapM mkField pairs
    pure $ DataD [] conName [mVar] Nothing [RecC conName fields] []
  where
    mkField (fieldName, reqName, resName, _) = do
        let selName = mkName fieldName
            m = VarT $ mkName "m"
            fieldType = ArrowT `AppT` ConT reqName `AppT` (m `AppT` ConT resName)
        pure (selName, recordBang, fieldType)

{- | Generates 'IsInServiceLib' instances for each request/response pair.
PRE-CONTRACT: libName is the 'Name' of the service lib type; pairs are non-empty.
POST-CONTRACT: Returns one 'InstanceD' per pair, each implementing 'callFromServiceLib'.
-}
genIsInServiceLibInstances :: Name -> [FieldPair] -> [Q Dec]
genIsInServiceLibInstances libName pairs =
    map mkInstance pairs
  where
    mkInstance (fieldName, reqName, resName, _) = do
        let selName = mkName $ fieldName <> "Service"
            argName = mkName "x"
            body =
                NormalB $
                    LamE
                        [VarP argName]
                        ( AppE
                            (VarE 'callService)
                            (AppE (VarE selName) (VarE argName))
                        )
        pure $
            InstanceD
                Nothing
                []
                ( ConT ''IsInServiceLib
                    `AppT` ConT libName
                    `AppT` ConT reqName
                    `AppT` ConT resName
                )
                [FunD 'callFromServiceLib [Clause [] body []]]

{- | Generates the @mk@ builder function for the service library.
PRE-CONTRACT: libName is a valid Haskell constructor name; configConName is the
  'Name' of the config constructor; pairs are non-empty.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'.
-}
genMkFunction :: String -> Name -> [FieldPair] -> Q [Dec]
genMkFunction libName configConName pairs = do
    m <- newName "m"
    let funName = mkName $ "mk" <> libName
        configType = ConT configConName `AppT` VarT m
        libConName = mkName libName
    sig <- genMkSig funName m configType libConName pairs
    body <- genMkBody funName configConName libConName pairs
    pure [sig, body]

{- | Generates the type signature for the @mk@ function.
PRE-CONTRACT: All parameters are well-formed TH names/types.
POST-CONTRACT: Returns a 'SigD' with the correct forall, constraints, and return type.
-}
genMkSig :: Name -> Name -> Type -> Name -> [FieldPair] -> Q Dec
genMkSig funName m configType libConName pairs = do
    let constraints =
            AppT (ConT ''MonadUnliftIO) (VarT m)
                : concatMap mkConstraint pairs
        returnType =
            AppT (VarT m) $
                AppT (AppT (TupleT 2) (ConT libConName)) $
                    AppT ListT (AppT (VarT m) (TupleT 0))
    pure $
        SigD funName $
            ForallT [PlainTV m SpecifiedSpec] constraints $
                AppT (AppT ArrowT configType) returnType
  where
    -- \| Builds constraints for a single pair. Always adds 'HasFailbackValue';
    --   adds 'FromJSON'\/'ToJSON' when tool specs are present.
    mkConstraint :: FieldPair -> [Type]
    mkConstraint (_, reqName, resName, specs) =
        AppT (ConT ''HasFailbackValue) (ConT resName)
            : if null specs
                then []
                else
                    [ AppT (ConT ''FromJSON) (ConT reqName)
                    , AppT (ConT ''ToJSON) (ConT resName)
                    , AppT (ConT ''ToSchema) (ConT reqName)
                    ]

{- | Generates the function body for the @mk@ function.
PRE-CONTRACT: All parameters are well-formed TH names.
POST-CONTRACT: Returns a 'FunD' whose body creates each service and assembles the results.
-}
genMkBody :: Name -> Name -> Name -> [FieldPair] -> Q Dec
genMkBody funName _configConName libConName pairs = do
    let configName = mkName "config"
    stmts <- genStatements configName pairs
    let finalStmt = genFinalStmt libConName pairs
    pure $
        FunD
            funName
            [ Clause
                [VarP configName]
                (NormalB (DoE Nothing (stmts <> [finalStmt])))
                []
            ]

{- | Generates the bind statements for each service creation.
PRE-CONTRACT: configName and pairs are well-formed.
POST-CONTRACT: Returns a list of 'BindS' statements, one per pair.
-}
genStatements :: Name -> [FieldPair] -> Q [Stmt]
genStatements configName pairs =
    mapM mkBind (zip [0 ..] pairs)
  where
    mkBind (i :: Int, (fieldName, _, _, _)) = do
        hName <- newName $ "h" <> show i
        wName <- newName $ "w" <> show i
        let selName = mkName fieldName
            -- createService (fieldName config)
            rhs =
                AppE
                    (VarE 'createService)
                    (AppE (VarE selName) (VarE configName))
        pure $ BindS (TupP [VarP hName, VarP wName]) rhs

{- | Generates the final pure statement that constructs the service lib and worker list.
PRE-CONTRACT: libConName and pairs are well-formed.
POST-CONTRACT: Returns a 'NoBindS' that assembles the handler and workers.
-}
genFinalStmt :: Name -> [FieldPair] -> Stmt
genFinalStmt libConName pairs =
    NoBindS $
        AppE (VarE 'pure) (TupE [Just handlersExpr, Just workersExpr])
  where
    handlersExpr = foldl' app (ConE libConName) handlerVars
      where
        handlerVars = map (\i -> VarE $ mkName $ "h" <> show i) [0 .. length pairs - 1]
        app f v = AppE f v
    workersExpr = ListE $ map (\i -> VarE $ mkName $ "w" <> show i) [0 .. length pairs - 1]

-- ── New generators: tool enum, toolInfo, allToolDescriptions ─────────────

{- | Generates the tool enumeration data type.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'DataD' with nullary constructors for each tool spec.
  For empty specs, returns an empty data type without derivations.
-}
genToolEnumType :: String -> [(Name, String, String)] -> Q Dec
genToolEnumType libName [] = do
    let typeName = mkName $ libName <> "Tool"
    pure $ DataD [] typeName [] Nothing [] []
genToolEnumType libName toolSpecs = do
    let typeName = mkName $ libName <> "Tool"
        constructors = map mkCon toolSpecs
        derivClauses =
            [ DerivClause
                Nothing
                (map (ConT . mkName) ["Show", "Read", "Eq", "Ord", "Enum", "Bounded"])
            ]
    pure $ DataD [] typeName [] Nothing constructors derivClauses
  where
    mkCon (conName, _, _) = NormalC (mkName $ nameBase conName <> "Tool") []

{- | Generates the @toolInfo@ function that maps each enum constructor to a 'ToolDescription'.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'. For empty specs, returns a
  wildcard clause that calls 'error'.
-}
genToolInfo :: String -> [(Name, String, String)] -> Q [Dec]
genToolInfo libName toolSpecs = do
    let funName = mkName "toolInfo"
        typeName = mkName $ libName <> "Tool"
        sigType =
            AppT (AppT ArrowT (ConT typeName)) (ConT ''ToolDescription)
    clauses <- case toolSpecs of
        [] ->
            pure
                [ Clause
                    [WildP]
                    ( NormalB
                        ( AppE
                            (VarE (mkName "error"))
                            (LitE (StringL "toolInfo: no tools defined"))
                        )
                    )
                    []
                ]
        _ -> mapM mkClause toolSpecs
    pure [SigD funName sigType, FunD funName clauses]
  where
    mkClause (conName, toolName, desc) =
        let enumCon = mkName $ nameBase conName <> "Tool"
        in pure $
            Clause
                [ConP enumCon [] []]
                ( NormalB $
                    ConE 'ToolDescription
                        `AppE` LitE (StringL toolName)
                        `AppE` LitE (StringL desc)
                        `AppE` AppE (VarE (mkName "toolSchema")) (ConE enumCon)
                )
                []

{- | Generates the @allToolDescriptions@ value.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'. For empty specs, returns an
  empty list literal to avoid calling 'minBound'/'maxBound' on an empty type.
-}
genAllToolDescriptions :: String -> [(Name, String, String)] -> Q [Dec]
genAllToolDescriptions _libName [] = do
    let funName = mkName "allToolDescriptions"
        sigType = AppT ListT (ConT ''ToolDescription)
        body = NormalB $ ListE []
    pure [SigD funName sigType, FunD funName [Clause [] body []]]
genAllToolDescriptions _libName _toolSpecs = do
    let funName = mkName "allToolDescriptions"
        sigType = AppT ListT (ConT ''ToolDescription)
        enumRange =
            ArithSeqE
                ( FromToR
                    (VarE (mkName "minBound"))
                    (VarE (mkName "maxBound"))
                )
        body =
            NormalB $
                AppE (AppE (VarE (mkName "map")) (VarE (mkName "toolInfo"))) enumRange
    pure [SigD funName sigType, FunD funName [Clause [] body []]]

-- ── JSON Schema generation ───────────────────────────────────────────────

{- | Generates the @toolSchema@ function that maps each tool enum constructor to a
'Just' JSON Schema for record constructors or 'Nothing' for non-record constructors.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'. For empty specs, returns [].
-}
genToolSchema :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
genToolSchema _libName [] = pure []
genToolSchema libName rawPairs = do
    let funName = mkName "toolSchema"
        typeName = mkName $ libName <> "Tool"
        sigType = AppT (AppT ArrowT (ConT typeName)) (AppT (ConT ''Maybe) (ConT ''Value))
        allToolSpecs = concatMap (\(_, _, specs) -> specs) rawPairs
    clauses <- mapM (mkSchemaClause rawPairs) allToolSpecs
    pure [SigD funName sigType, FunD funName clauses]

{- | Generate one clause of the @toolSchema@ function for a single tool spec.
PRE-CONTRACT: rawPairs contains exactly one parent request type for the given constructor.
POST-CONTRACT: Returns a Clause that matches the tool enum constructor and produces
  @'Just' ('toJSON' ('toInlinedSchema' ('Proxy' :: 'Proxy' parentReq)))@.
-}
mkSchemaClause :: [(Name, Name, [(Name, String, String)])] -> (Name, String, String) -> Q Clause
mkSchemaClause rawPairs (conName, _, _) = do
    let enumCon = mkName $ nameBase conName <> "Tool"
        parentReqs = [reqName | (reqName, _, specs) <- rawPairs, (cn, _, _) <- specs, cn == conName]
    parentReq <- case parentReqs of
        [req] -> pure req
        []    -> fail $ "mkSchemaClause: no parent request type for constructor " <> nameBase conName
        _     -> fail $ "mkSchemaClause: ambiguous parent for constructor " <> nameBase conName
    -- Generate: Just (toJSON (toInlinedSchema (Proxy :: Proxy parentReq)))
    let proxyExpr = SigE (ConE 'Proxy) (AppT (ConT ''Proxy) (ConT parentReq))
        schemaExpr = AppE (VarE 'toInlinedSchema) proxyExpr
        valueExpr  = AppE (VarE 'toJSON) schemaExpr
        body       = AppE (ConE 'Just) valueExpr
    pure $ Clause [ConP enumCon [] []] (NormalB body) []

-- ── New generators: ToolCall, ToolResponse, FromJSON, execute, etc. ──────

{- | Generates the @ToolCall@ sum type, one constructor per request type with tool specs.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'DataD' with constructors @{ReqType}ToolCall Text {ReqType}@.
-}
genToolCallType :: String -> [(Name, Name, [(Name, String, String)])] -> Q Dec
genToolCallType libName rawPairs = do
    let typeName = mkName $ libName <> "ToolCall"
        constructors = map mkCon (filter hasSpecs rawPairs)
    if null constructors
        then pure $ DataD [] typeName [] Nothing [] []
        else
            pure $
                DataD
                    []
                    typeName
                    []
                    Nothing
                    constructors
                    [ DerivClause Nothing (map (ConT . mkName) ["Show", "Eq"])
                    ]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkCon (reqName, _, _) =
        let conName = mkName $ nameBase reqName <> "ToolCall"
         in NormalC
                conName
                [ (recordBang, ConT ''Text)
                , (recordBang, ConT reqName)
                ]

{- | Generates the @ToolResponse@ sum type, one constructor per response type with tool specs.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: Returns a 'DataD' with constructors @{ResType}ToolResponse {ResType}@.
-}
genToolResponseType :: String -> [(Name, Name, [(Name, String, String)])] -> Q Dec
genToolResponseType libName rawPairs = do
    let typeName = mkName $ libName <> "ToolResponse"
        constructors = map mkCon (filter hasSpecs rawPairs)
    if null constructors
        then pure $ DataD [] typeName [] Nothing [] []
        else
            pure $
                DataD
                    []
                    typeName
                    []
                    Nothing
                    constructors
                    [ DerivClause Nothing (map (ConT . mkName) ["Show", "Eq"])
                    ]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkCon (_, resName, _) =
        let conName = mkName $ nameBase resName <> "ToolResponse"
         in NormalC
                conName
                [ (recordBang, ConT resName)
                ]

{- | Generates a 'FromJSON' instance for the @ToolCall@ type that dispatches on @tool_name@.

Uses @o .: \"arguments\"@ inside each case branch so that Aeson's 'parseJSON'
dispatches to the correct @'FromJSON' req@ instance without shadowing the
instance's own 'parseJSON' method.

PRE-CONTRACT: libName is a valid Haskell identifier; at least one pair has tool specs.
POST-CONTRACT: Returns an 'InstanceD' with a 'parseJSON' method.
-}
genFromJSONToolCall :: String -> [(Name, Name, [(Name, String, String)])] -> Q Dec
genFromJSONToolCall libName rawPairs = do
    let typeName = mkName $ libName <> "ToolCall"
        objName = mkName "o"
        nameVar = mkName "name"
        alts = concatMap mkAlts (filter hasSpecs rawPairs)
        defaultAlt =
            Match
                WildP
                ( NormalB
                    ( AppE
                        (VarE 'fail)
                        ( AppE
                            (VarE 'Text.unpack)
                            ( AppE
                                ( AppE
                                    (VarE '(<>))
                                    (LitE (StringL "Unknown tool: "))
                                )
                                (VarE nameVar)
                            )
                        )
                    )
                )
                []
        caseExpr = CaseE (VarE nameVar) (alts <> [defaultAlt])
        lambdaBody =
            DoE
                Nothing
                [ BindS
                    (VarP nameVar)
                    ( AppE
                        (AppE (VarE '(.:)) (VarE objName))
                        (LitE (StringL "tool_name"))
                    )
                , NoBindS caseExpr
                ]
        lambda = LamE [VarP objName] lambdaBody
        rhs =
            AppE
                ( AppE
                    (VarE 'withObject)
                    (LitE (StringL (libName <> "ToolCall")))
                )
                lambda
    pure $
        InstanceD
            Nothing
            []
            (AppT (ConT ''FromJSON) (ConT typeName))
            [FunD (mkName "parseJSON") [Clause [] (NormalB rhs) []]]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkAlts (reqName, _, specs) =
        map mkAlt specs
      where
        conName = mkName $ nameBase reqName <> "ToolCall"
        mkAlt (_, toolName, _) =
            Match
                (LitP (StringL toolName))
                ( NormalB
                    ( AppE
                        ( AppE
                            (VarE '(<$>))
                            (AppE (ConE conName) (VarE (mkName "name")))
                        )
                        ( AppE
                            (AppE (VarE '(.:)) (VarE (mkName "o")))
                            (LitE (StringL "arguments"))
                        )
                    )
                )
                []

{- | Generates the @executeToolCall@ function that dispatches a tool call to the correct service.
PRE-CONTRACT: libName is a valid Haskell identifier; at least one pair has tool specs.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'.
-}
genExecuteToolCall :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
genExecuteToolCall libName rawPairs = do
    let funName = mkName "executeToolCall"
        libType = mkName libName
        toolCallType = mkName $ libName <> "ToolCall"
        toolRespType = mkName $ libName <> "ToolResponse"
        mVar = mkName "m"
        constraints = [AppT (ConT ''MonadUnliftIO) (VarT mVar)]
        sigType =
            ForallT
                [PlainTV mVar SpecifiedSpec]
                constraints
                ( AppT
                    (AppT ArrowT (ConT libType))
                    ( AppT
                        (AppT ArrowT (ConT toolCallType))
                        (AppT (VarT mVar) (ConT toolRespType))
                    )
                )
    clauses <- mapM mkClause (filter hasSpecs rawPairs)
    pure [SigD funName sigType, FunD funName clauses]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkClause (reqName, resName, _) = do
        reqVar <- newName "req"
        let callConName = mkName $ nameBase reqName <> "ToolCall"
            respConName = mkName $ nameBase resName <> "ToolResponse"
            fieldName = typeToFieldName reqName
            selName = mkName $ fieldName <> "Service"
            slVar = mkName "sl"
            -- callService (fieldNameService sl) req
            callServiceApp =
                AppE
                    ( AppE
                        (VarE 'callService)
                        (AppE (VarE selName) (VarE slVar))
                    )
                    (VarE reqVar)
            -- RespCon <$> callService ...
            body =
                NormalB $
                    AppE
                        (AppE (VarE '(<$>)) (ConE respConName))
                        callServiceApp
            pat = ConP callConName [] [WildP, VarP reqVar]
        pure $ Clause [VarP slVar, pat] body []

{- | Generates the @toolCallName@ function that extracts the tool name from a 'ToolCall'.
PRE-CONTRACT: libName is a valid Haskell identifier; at least one pair has tool specs.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'.
-}
genToolCallName :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
genToolCallName libName rawPairs = do
    let funName = mkName "toolCallName"
        toolCallType = mkName $ libName <> "ToolCall"
        sigType =
            AppT (AppT ArrowT (ConT toolCallType)) (ConT ''Text)
    clauses <- mapM mkClause (filter hasSpecs rawPairs)
    pure [SigD funName sigType, FunD funName clauses]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkClause (reqName, _, _) = do
        nameVar <- newName "name"
        let conName = mkName $ nameBase reqName <> "ToolCall"
            pat = ConP conName [] [VarP nameVar, WildP]
            body = NormalB (VarE nameVar)
        pure $ Clause [pat] body []

{- | Generates the @encodeToolResponse@ function that encodes a 'ToolResponse' as a JSON 'Value'.
PRE-CONTRACT: libName is a valid Haskell identifier; at least one pair has tool specs.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'.
-}
genEncodeToolResponse :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
genEncodeToolResponse libName rawPairs = do
    let funName = mkName "encodeToolResponse"
        toolRespType = mkName $ libName <> "ToolResponse"
        sigType =
            AppT
                (AppT ArrowT (ConT ''Text))
                ( AppT
                    (AppT ArrowT (ConT toolRespType))
                    (ConT ''Value)
                )
    nameArg <- newName "name"
    clauses <- mapM (mkClause nameArg) (filter hasSpecs rawPairs)
    pure [SigD funName sigType, FunD funName clauses]
  where
    hasSpecs (_, _, specs) = not (null specs)
    mkClause nameArg (_, resName, _) = do
        respVar <- newName "resp"
        let conName = mkName $ nameBase resName <> "ToolResponse"
            pat = ConP conName [] [VarP respVar]
            -- object ["tool_name" .= name, "result" .= toJSON resp]
            pairs =
                ListE
                    [ AppE
                        ( AppE
                            (VarE '(.=))
                            (LitE (StringL "tool_name"))
                        )
                        (VarE nameArg)
                    , AppE
                        ( AppE
                            (VarE '(.=))
                            (LitE (StringL "result"))
                        )
                        (AppE (VarE 'toJSON) (VarE respVar))
                    ]
            body = NormalB $ AppE (VarE 'object) pairs
        pure $ Clause [VarP nameArg, pat] body []

{- | Generates smart constructors for wrapping AI scripts with tool descriptions.
PRE-CONTRACT: libName is a valid Haskell identifier.
POST-CONTRACT: When toolSpecs is non-empty, returns declarations for
  'aiScriptWithAll' and 'aiScriptWith'. When empty, returns [].
-}
genSmartConstructors :: String -> [(Name, String, String)] -> Q [Dec]
genSmartConstructors _libName [] = pure []
genSmartConstructors libName _toolSpecs = do
    let enumType = mkName $ libName <> "Tool"
    pure $ genAiScriptWithAll <> genAiScriptWith enumType
  where
    -- aiScriptWithAll :: AIScript b -> Script b
    -- aiScriptWithAll = AIScriptDef allToolDescriptions
    genAiScriptWithAll =
        [ SigD
            (mkName "aiScriptWithAll")
            ( AppT
                ( AppT
                    ArrowT
                    (AppT (ConT ''AIScript) (VarT (mkName "b")))
                )
                (AppT (ConT ''Script) (VarT (mkName "b")))
            )
        , FunD
            (mkName "aiScriptWithAll")
            [ Clause
                []
                ( NormalB
                    ( AppE
                        (ConE 'AIScriptDef)
                        (VarE (mkName "allToolDescriptions"))
                    )
                )
                []
            ]
        ]
    -- aiScriptWith :: [{Lib}Tool] -> AIScript b -> Script b
    -- aiScriptWith tools = AIScriptDef (map toolInfo tools)
    genAiScriptWith enumType =
        let toolsVar = mkName "tools"
         in [ SigD
                (mkName "aiScriptWith")
                ( AppT
                    (AppT ArrowT (AppT ListT (ConT enumType)))
                    ( AppT
                        ( AppT
                            ArrowT
                            (AppT (ConT ''AIScript) (VarT (mkName "b")))
                        )
                        (AppT (ConT ''Script) (VarT (mkName "b")))
                    )
                )
            , FunD
                (mkName "aiScriptWith")
                [ Clause
                    [VarP toolsVar]
                    ( NormalB
                        ( AppE
                            (ConE 'AIScriptDef)
                            ( AppE
                                ( AppE
                                    (VarE (mkName "map"))
                                    (VarE (mkName "toolInfo"))
                                )
                                (VarE toolsVar)
                            )
                        )
                    )
                    []
                ]
            ]

-- ── mkToolCallExec generator ─────────────────────────────────────────────

{- | Generates the @mkToolCallExec@ function that creates a 'ToolCallExec' closure
from a service library. The closure dispatches tool calls by parsing JSON, executing
the tool, and encoding the response.
PRE-CONTRACT: libName is a valid Haskell identifier; tool specs are non-empty.
POST-CONTRACT: Returns a 'SigD' and a 'FunD'. For empty specs, returns [].
-}
genMkToolCallExec :: String -> [(Name, String, String)] -> Q [Dec]
genMkToolCallExec _libName [] = pure []
genMkToolCallExec libName _toolSpecs = do
    let funName = mkName "mkToolCallExec"
        libType = mkName libName
        slVar      = mkName "sl"
        toolNameV  = mkName "toolName"
        argsValV   = mkName "argsValue"
        djVar      = mkName "dispatchJson"
        tcVar      = mkName "tc"
        respVar    = mkName "resp"
        errVar     = mkName "err"
        sigType = AppT (AppT ArrowT (ConT libType)) (ConT ''ToolCallExec)
        -- inner lambda: \toolName argsValue -> do { ... }
        innerBody = DoE Nothing
            [ LetS [ValD (VarP djVar)
                (NormalB $ AppE (VarE 'object) $ ListE
                    [ AppE (AppE (VarE '(.=)) (LitE (StringL "tool_name"))) (VarE toolNameV)
                    , AppE (AppE (VarE '(.=)) (LitE (StringL "arguments"))) (VarE argsValV)
                    ])
                []]
            , NoBindS $ CaseE (AppE (VarE 'fromJSON) (VarE djVar))
                [ Match (ConP 'Success [] [VarP tcVar])
                    (NormalB $ DoE Nothing
                        [ BindS (VarP respVar)
                            (AppE (AppE (VarE (mkName "executeToolCall")) (VarE slVar)) (VarE tcVar))
                        , NoBindS $ AppE (VarE 'pure)
                            (AppE (AppE (VarE (mkName "encodeToolResponse"))
                                (AppE (VarE (mkName "toolCallName")) (VarE tcVar)))
                                (VarE respVar))
                        ])
                    []
                , Match (ConP 'Error [] [VarP errVar])
                    (NormalB $ AppE (VarE (mkName "fail")) (VarE errVar))
                    []
                ]
            ]
        innerLambda = LamE [VarP toolNameV, VarP argsValV] innerBody
        -- outer: mkToolCallExec sl = ToolCallExec $ \toolName argsValue -> ...
        body = NormalB $ AppE (ConE 'ToolCallExec) innerLambda
    pure [SigD funName sigType, FunD funName [Clause [VarP slVar] body []]]

-- ── Main entry point ─────────────────────────────────────────────────────

{- | Template Haskell macro that generates a complete service library.

Given a service library name and a list of @(RequestType, ResponseType, ToolSpecs)@
triples, generates:

1. A service library data type with 'ServiceHandler' fields.
2. A config data type with function fields and an @m@ type parameter.
3. 'IsInServiceLib' instances for each request\/response pair.
4. An @mk@ builder function that constructs the service library from config.
5. A tool enumeration type (@{LibName}Tool@) with 'Enum'\/'Bounded'.
6. A @toolInfo@ function mapping enum values to 'ToolDescription'.
7. An @allToolDescriptions@ value collecting all tool descriptions.
8. A @ToolCall@ sum type for JSON dispatch (when tool specs are present).
9. A @ToolResponse@ sum type for wrapping responses (when tool specs are present).
10. A 'FromJSON' instance for @ToolCall@ (when tool specs are present).
11. An @executeToolCall@ function (when tool specs are present).
12. A @toolCallName@ function (when tool specs are present).
13. An @encodeToolResponse@ function (when tool specs are present).
14. Smart constructors @aiScriptWithAll@ and @aiScriptWith@ (when tool specs are present).
15. A @toolSchema@ function (when tool specs are present).
16. A @mkToolCallExec@ function that creates a 'ToolCallExec' closure (when tool specs are present).

=== Example

> makeServiceLib "AllServices"
>     [ (''SimpleRequest, ''SimpleResponse,
>         [('Add, "add", "Adds two numbers"), ('Subtract, "subtract", "Subtracts two numbers")])
>     ]

PRE-CONTRACT: The list of pairs is non-empty; all request type names are unique;
  all names refer to in-scope type constructors; constructor names in tool specs
  are unique across all request types and exist in their respective request types.
  Request types with tool specs must be record types with derived 'Generic' and
  'ToSchema' instances.
POST-CONTRACT: Returns a list of declarations that define the service library,
  its config, instances, builder function, and tool-related types and functions.
-}
makeServiceLib :: String -> [(Name, Name, [(Name, String, String)])] -> Q [Dec]
makeServiceLib libName rawPairs = do
    when (null rawPairs) $
        fail "makeServiceLib: at least one (RequestType, ResponseType) pair is required"
    let fieldPairs = map mkFieldPair rawPairs
    detectDuplicates (map (\(r, rs, _) -> (r, rs)) rawPairs)
    -- Collect all tool specs flattened across request types
    let allToolSpecs = concatMap (\(_, _, specs) -> specs) rawPairs
    -- Validate constructors exist in their respective request types
    forM_ rawPairs $ \(reqName, _, specs) ->
        unless (null specs) $
            validateConstructors reqName (map (\(cn, _, _) -> cn) specs)
    -- Check for duplicate enum constructor base names across all request types
    unless (null allToolSpecs) $ do
        detectDuplicateEnumConstructors allToolSpecs
        detectDuplicateToolNameStrings allToolSpecs
    -- Check for duplicate field names from request type base names
    detectDuplicateFieldNames rawPairs
    let libConName = mkName libName
        configConName = mkName $ libName <> "Config"
    -- Existing generators
    serviceLibType <- genServiceLibType libName fieldPairs
    configType <- genConfigType libName fieldPairs
    instances <- sequence $ genIsInServiceLibInstances libConName fieldPairs
    mkDecls <- genMkFunction libName configConName fieldPairs
    -- Tool enum / info / descriptions (always generated)
    toolEnumDec <- genToolEnumType libName allToolSpecs
    -- JSON Schema must come before toolInfo since toolInfo references toolSchema
    toolSchemaDecs <- genToolSchema libName rawPairs
    toolInfoDecs <- genToolInfo libName allToolSpecs
    allToolDescsDecs <- genAllToolDescriptions libName allToolSpecs
    -- T2b generators (only when at least one spec exists)
    let hasAnySpecs = not (null allToolSpecs)
    t2bDecs <-
        if hasAnySpecs
            then do
                tc <- genToolCallType libName rawPairs
                tr <- genToolResponseType libName rawPairs
                fj <- genFromJSONToolCall libName rawPairs
                et <- genExecuteToolCall libName rawPairs
                tn <- genToolCallName libName rawPairs
                er <- genEncodeToolResponse libName rawPairs
                mkTCE <- genMkToolCallExec libName allToolSpecs
                pure $ [tc, tr, fj] <> et <> tn <> er <> mkTCE
            else pure []
    smartCtorDecs <- genSmartConstructors libName allToolSpecs
    pure $
        [serviceLibType, configType, toolEnumDec]
            <> toolSchemaDecs
            <> toolInfoDecs
            <> allToolDescsDecs
            <> instances
            <> mkDecls
            <> t2bDecs
            <> smartCtorDecs
  where
    mkFieldPair (reqName, resName, specs) =
        (typeToFieldName reqName, reqName, resName, specs)
