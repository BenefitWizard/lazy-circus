{-# LANGUAGE TemplateHaskell #-}

-- | Template Haskell macros for generating service library boilerplate.
--
-- Given a list of @(RequestType, ResponseType)@ pairs, 'makeServiceLib'
-- generates a service library data type, its config type, 'IsInServiceLib'
-- instances, and a builder function.
module LazyCircus.App.Service.TH (
    makeServiceLib,
) where

import RIO

import Data.Char (toLower)
import Data.List (nub, (\\))

import Language.Haskell.TH

import LazyCircus.App.Service (
    HasFailbackValue (..),
    IsInServiceLib (..),
    ServiceHandler (..),
    callService,
    createService,
 )

-- | Converts a type name to a camelCase field name by lowercasing the first character.
-- PRE-CONTRACT: The Name must represent a type constructor whose base name starts with an uppercase letter.
-- POST-CONTRACT: Result starts with a lowercase letter; the rest of the characters are unchanged.
typeToFieldName :: Name -> String
typeToFieldName name =
    case nameBase name of
        [] -> []
        (c : cs) -> toLower c : cs

-- | Checks that request type names in the list are unique.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns () when all request names are unique; calls 'fail' otherwise.
detectDuplicates :: [(Name, Name)] -> Q ()
detectDuplicates pairs = do
    let reqNames = map fst pairs
        dups = reqNames \\ nub reqNames
    unless (null dups) $
        fail $
            "makeServiceLib: duplicate request types: " <> show dups

-- | Generates the service library data type declaration.
-- PRE-CONTRACT: libName is a valid Haskell constructor name; pairs is non-empty.
-- POST-CONTRACT: Returns a 'DataD' with one record constructor whose fields are
--   named @{fieldName}Service@ with type @ServiceHandler ReqTy ResTy@.
genServiceLibType :: String -> [(String, Name, Name)] -> Q Dec
genServiceLibType libName pairs = do
    let conName = mkName libName
    fields <- mapM mkField pairs
    pure $ DataD [] conName [] Nothing [RecC conName fields] []
  where
    mkField (fieldName, reqName, resName) = do
        let selName = mkName $ fieldName <> "Service"
            fieldType =
                ConT ''ServiceHandler
                    `AppT` ConT reqName
                    `AppT` ConT resName
        pure (selName, recordBang, fieldType)

-- | Generates the config data type declaration with an @m@ type parameter.
-- PRE-CONTRACT: libName is a valid Haskell constructor name; pairs is non-empty.
-- POST-CONTRACT: Returns a 'DataD' with @m@ as a type parameter and fields typed
--   @ReqTy -> m ResTy@.
genConfigType :: String -> [(String, Name, Name)] -> Q Dec
genConfigType libName pairs = do
    let conName = mkName $ libName <> "Config"
        mVar = PlainTV (mkName "m") BndrReq
    fields <- mapM mkField pairs
    pure $ DataD [] conName [mVar] Nothing [RecC conName fields] []
  where
    mkField (fieldName, reqName, resName) = do
        let selName = mkName fieldName
            m = VarT $ mkName "m"
            fieldType = ArrowT `AppT` ConT reqName `AppT` (m `AppT` ConT resName)
        pure (selName, recordBang, fieldType)

-- | Generates 'IsInServiceLib' instances for each request/response pair.
-- PRE-CONTRACT: libName is the 'Name' of the service lib type; pairs are non-empty.
-- POST-CONTRACT: Returns one 'InstanceD' per pair, each implementing 'callFromServiceLib'.
genIsInServiceLibInstances :: Name -> [(String, Name, Name)] -> [Q Dec]
genIsInServiceLibInstances libName pairs =
    map mkInstance pairs
  where
    mkInstance (fieldName, reqName, resName) = do
        let selName = mkName $ fieldName <> "Service"
            -- \x -> callService (fieldNameService x)
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
                [ FunD 'callFromServiceLib [Clause [] body []] ]

-- | Generates the @mk@ builder function for the service library.
-- PRE-CONTRACT: libName is a valid Haskell constructor name; configConName is the
--   'Name' of the config constructor; pairs are non-empty.
-- POST-CONTRACT: Returns a 'SigD' and a 'FunD'.
genMkFunction :: String -> Name -> [(String, Name, Name)] -> Q [Dec]
genMkFunction libName configConName pairs = do
    m <- newName "m"
    let funName = mkName $ "mk" <> libName
        configType = ConT configConName `AppT` VarT m
        libConName = mkName libName
    sig <- genMkSig funName m configType libConName pairs
    body <- genMkBody funName configConName libConName pairs
    pure [sig, body]

-- | Generates the type signature for the @mk@ function.
-- PRE-CONTRACT: All parameters are well-formed TH names/types.
-- POST-CONTRACT: Returns a 'SigD' with the correct forall, constraints, and return type.
genMkSig :: Name -> Name -> Type -> Name -> [(String, Name, Name)] -> Q Dec
genMkSig funName m configType libConName pairs = do
    let constraints =
            AppT (ConT ''MonadUnliftIO) (VarT m)
                : map (\(_, _, resName) -> AppT (ConT ''HasFailbackValue) (ConT resName)) pairs
        returnType =
            AppT (VarT m) $
                AppT (AppT (TupleT 2) (ConT libConName)) $
                    AppT ListT (AppT (VarT m) (TupleT 0))
    pure $
        SigD funName $
            ForallT [PlainTV m SpecifiedSpec] constraints $
                AppT (AppT ArrowT configType) returnType

-- | Generates the function body for the @mk@ function.
-- PRE-CONTRACT: All parameters are well-formed TH names.
-- POST-CONTRACT: Returns a 'FunD' whose body creates each service and assembles the results.
genMkBody :: Name -> Name -> Name -> [(String, Name, Name)] -> Q Dec
genMkBody funName _configConName libConName pairs = do
    let configName = mkName "config"
    stmts <- genStatements configName pairs
    let finalStmt = genFinalStmt libConName pairs
    pure $
        FunD funName
            [ Clause
                [VarP configName]
                (NormalB (DoE Nothing (stmts <> [finalStmt])))
                []
            ]

-- | Generates the bind statements for each service creation.
-- PRE-CONTRACT: configName and pairs are well-formed.
-- POST-CONTRACT: Returns a list of 'BindS' statements, one per pair.
genStatements :: Name -> [(String, Name, Name)] -> Q [Stmt]
genStatements configName pairs =
    mapM mkBind (zip [0 ..] pairs)
  where
    mkBind (i :: Int, (fieldName, _, _)) = do
        hName <- newName $ "h" <> show i
        wName <- newName $ "w" <> show i
        let selName = mkName fieldName
            -- createService (fieldName config)
            rhs =
                AppE
                    (VarE 'createService)
                    (AppE (VarE selName) (VarE configName))
        pure $ BindS (TupP [VarP hName, VarP wName]) rhs

-- | Generates the final pure statement that constructs the service lib and worker list.
-- PRE-CONTRACT: libConName and pairs are well-formed.
-- POST-CONTRACT: Returns a 'NoBindS' that assembles the handler and workers.
genFinalStmt :: Name -> [(String, Name, Name)] -> Stmt
genFinalStmt libConName pairs =
    NoBindS $
        AppE (VarE 'pure) (TupE [Just handlersExpr, Just workersExpr])
  where
    handlersExpr = foldl' app (ConE libConName) handlerVars
      where
        handlerVars = map (\i -> VarE $ mkName $ "h" <> show i) [0 .. length pairs - 1]
        app f v = AppE f v
    workersExpr = ListE $ map (\i -> VarE $ mkName $ "w" <> show i) [0 .. length pairs - 1]

-- | Shared no-unpacking, no-strictness record field annotation.
recordBang :: Bang
recordBang = Bang NoSourceUnpackedness NoSourceStrictness

-- | Template Haskell macro that generates a complete service library.
--
-- Given a service library name and a list of @(RequestType, ResponseType)@ pairs,
-- generates:
--
-- 1. A service library data type with 'ServiceHandler' fields.
-- 2. A config data type with function fields and an @m@ type parameter.
-- 3. 'IsInServiceLib' instances for each request/response pair.
-- 4. An @mk@ builder function that constructs the service library from config.
--
-- === Example
--
-- > makeServiceLib "AllServices"
-- >     [ (''SimpleRequest, ''SimpleResponse)
-- >     , (''AddExpressionRequest, ''AddExpressionResponse)
-- >     ]
--
-- PRE-CONTRACT: The list of pairs is non-empty; all request type names are unique;
--   all names refer to in-scope type constructors.
-- POST-CONTRACT: Returns a list of declarations that define the service library,
--   its config, instances, and builder function.
makeServiceLib :: String -> [(Name, Name)] -> Q [Dec]
makeServiceLib libName rawPairs = do
    when (null rawPairs) $
        fail "makeServiceLib: at least one (RequestType, ResponseType) pair is required"
    let fieldPairs = map mkFieldPair rawPairs
    detectDuplicates rawPairs
    let libConName = mkName libName
        configConName = mkName $ libName <> "Config"
    serviceLibType <- genServiceLibType libName fieldPairs
    configType <- genConfigType libName fieldPairs
    instances <- sequence $ genIsInServiceLibInstances libConName fieldPairs
    mkDecls <- genMkFunction libName configConName fieldPairs
    pure $ [serviceLibType, configType] <> instances <> mkDecls
  where
    mkFieldPair (reqName, resName) =
        (typeToFieldName reqName, reqName, resName)
