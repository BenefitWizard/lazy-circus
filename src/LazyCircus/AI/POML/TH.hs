{-# LANGUAGE TemplateHaskell #-}

{- |
PURPOSE: Generate POML AST values (and optional input record types) from
  @.poml@ source files at compile time via a Template Haskell macro.
SCOPE: Reading and parsing @.poml@ files, building the variable type
  environment, validating the parsed document (single root, declared
  variables, valid element names, no @poml@-typed variables inside
  concatenations), and emitting a record type plus a function definition
  whose body constructs a single 'POML' AST node.
DEPENDS: "LazyCircus.AI.POML.Parser" for parsing, "LazyCircus.AI.POML.Types"
  for the 'POML' AST shape (used to drive code generation),
  @template-haskell@ for splice construction, and the RIO prelude for
  primitive helpers referenced by generated code.

== Consumer requirements

The generated splice references the following names directly, so a module
that calls 'makePoml' must keep them in scope:

  * 'POML' and all of its constructors from "LazyCircus.AI.POML.Types"
    (@Paragraph@, @Heading@, @Code@, @Strong@, @Italic@, @Underline@,
    @Strikethrough@, @Span@, @Br@, @Text@, @List@, @CP@, @Role@, @Task@,
    @ExampleSet@, @Example@, @ExampleInput@, @ExampleOutput@), plus the
    @default*Params@ values referenced by each semantic tag
    ('defaultListParams', 'defaultCPParams', 'defaultRoleParams',
    'defaultTaskParams', 'defaultExampleSetParams',
    'defaultExampleParams', 'defaultExampleInputParams',
    'defaultExampleOutputParams').
  * 'Text' (the type) and 'bool', 'tshow' from the RIO prelude.
  * @OverloadedStrings@ must be enabled (the library default already does
    this) so that string literals produced by the splice coerce to
    'Data.Text.Text' at use sites.

If two 'makePoml' calls in the same module produce record types that share a
field name, enable @DuplicateRecordFields@ in the consumer module.
-}
module LazyCircus.AI.POML.TH
    ( makePoml
    ) where

import Data.Char (toLower, toUpper)
import Data.Text qualified as T
import RIO.Map (Map)
import RIO.Map qualified as Map
import Language.Haskell.TH hiding (Code)
import Language.Haskell.TH.Syntax (addDependentFile)
import LazyCircus.AI.POML.Parser
    ( LetDecl (..)
    , PomlDoc (..)
    , PomlNode (..)
    , PomlType (..)
    , TemplateExpr (..)
    , parsePoml
    )
import LazyCircus.AI.POML.Types
    ( POML (..)
    , defaultCPParams
    , defaultExampleInputParams
    , defaultExampleOutputParams
    , defaultExampleParams
    , defaultExampleSetParams
    , defaultListParams
    , defaultRoleParams
    , defaultTaskParams
    )
import RIO

-- | Shared no-unpacking, no-strictness record field annotation; mirrors
-- 'LazyCircus.App.Service.TH.recordBang'.
recordBang :: Bang
recordBang = Bang NoSourceUnpackedness NoSourceStrictness

{- | Compile-time macro that reads, parses, and lowers a @.poml@ file into a
Haskell record type (when the document declares template variables) and a
function returning a 'POML' value.

The @base@ argument drives the generated names: a base of @"hello"@
produces a record type @HelloInput@ (when there are @<let>@ declarations)
and a function @hello@. The @filePath@ argument is interpreted relative to
the project root and is registered with 'addDependentFile' so edits to the
source @.poml@ trigger recompilation.

See the module header for the consumer-side import requirements.

PRE-CONTRACT: @base@ is a valid Haskell identifier prefix suitable for the
  derived type and function names (the type name capitalises its first
  character and appends @Input@; the function name lowercases the first
  character). @filePath@ points to a readable @.poml@ file whose root
  element is @<poml>@.
POST-CONTRACT: On success returns at most one record type declaration (when
  the document has @<let>@ declarations) and exactly one function
  declaration whose body is a single 'POML' value. Calls 'fail' on any
  parse error, undeclared variable reference, multi-rooted body, empty
  body, invalid element name, or @poml@-typed variable inside a
  concatenation.
-}
makePoml :: String -> FilePath -> Q [Dec]
makePoml base filePath = do
    content <- runIO (readFileUtf8 filePath)
    addDependentFile filePath
    case parsePoml content of
        Left err -> fail ("makePoml: failed to parse " <> filePath <> ": " <> err)
        Right doc -> generateDecls base doc

-- | Drive validation and code generation for a parsed 'PomlDoc'.
generateDecls :: String -> PomlDoc -> Q [Dec]
generateDecls base doc = do
    mapM_ (validateLetName . letName) (pdLets doc)
    let varTypes =
            Map.fromList [(letName ld, letType ld) | ld <- pdLets doc]
        mArgName =
            if null (pdLets doc)
                then Nothing
                else Just (mkName "arg")
    bodyNode <- requireSingleBody doc
    validateVarRefs varTypes bodyNode
    bodyExp <- genNode varTypes mArgName bodyNode
    pure (genInputRecord base doc <> genFun base mArgName bodyExp)

-- | Validate that a @<let>@ name is a legal lowercase Haskell identifier
-- (not a reserved word), suitable for use as a record field selector. Calls
-- 'fail' at compile time with a clear message if the name would produce an
-- invalid record selector — before 'mkName' is ever applied to it.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: Returns normally only when the name is a legal lowercase
--   Haskell identifier and not a reserved word.
validateLetName :: Text -> Q ()
validateLetName name
    | T.null name = fail "makePoml: <let> name must not be empty"
    | not (isValidHsIdent (T.unpack name)) =
        fail
            ( "makePoml: <let> name '"
                <> T.unpack name
                <> "' is not a valid Haskell identifier \
                   \(use lowercase letters, digits, or underscores; \
                   \first char must be a letter or underscore)"
            )
    | T.unpack name `elem` reservedWords =
        fail
            ( "makePoml: <let> name '"
                <> T.unpack name
                <> "' is a reserved Haskell word and cannot be used as \
                   \a field name"
            )
    | otherwise = pure ()
  where
    -- | Haskell reserved words that cannot be reused as field selectors.
    reservedWords :: [String]
    reservedWords =
        [ "case", "class", "data", "default", "deriving", "do", "else"
        , "foreign", "if", "import", "in", "infix", "infixl", "infixr"
        , "instance", "let", "module", "newtype", "of", "then", "type"
        , "where", "_"
        ]

-- | Is the string a legal lowercase Haskell identifier? The first char must
-- be a lowercase letter or underscore; subsequent chars must be letters,
-- digits, or underscores. ASCII-only to keep diagnostics locale-independent
-- (Haskell also accepts Unicode letters, but POML field names are expected to
-- be plain ASCII).
isValidHsIdent :: String -> Bool
isValidHsIdent [] = False
isValidHsIdent (c : cs) = isLowerStart c && all isIdentChar cs
  where
    -- | Lowercase letter or underscore as the leading character.
    isLowerStart :: Char -> Bool
    isLowerStart ch = ch == '_' || (ch >= 'a' && ch <= 'z')
    -- | Letter, digit, or underscore as a non-leading character.
    isIdentChar :: Char -> Bool
    isIdentChar ch =
        ch == '_'
            || (ch >= 'a' && ch <= 'z')
            || (ch >= 'A' && ch <= 'Z')
            || (ch >= '0' && ch <= '9')

-- | Enforce that the body has exactly one top-level node.
requireSingleBody :: PomlDoc -> Q PomlNode
requireSingleBody doc = case pdBody doc of
    [] -> fail "makePoml: empty body"
    [single] -> pure single
    _ ->
        fail
            "makePoml: multiple top-level body elements not supported \
            \(wrap content in a single root element)"

-- | Fail if any 'TVar' in the body lacks a matching @<let>@ declaration.
-- Both text content and attribute values (e.g. a @<cp>@ @caption@) are walked,
-- so undeclared variables are reported with a clear message before codegen.
validateVarRefs :: Map Text PomlType -> PomlNode -> Q ()
validateVarRefs varTypes = checkNode
  where
    checkNode (NodeText exprs) = mapM_ checkExpr exprs
    checkNode (NodeElement _ attrs children) = do
        mapM_ checkExpr [e | (_, Just e) <- attrs]
        mapM_ checkNode children

    checkExpr (TVar n)
        | Map.member n varTypes = pure ()
        | otherwise = fail ("makePoml: undeclared variable: " <> T.unpack n)
    checkExpr (TLit _) = pure ()
    checkExpr (TConcat parts) = mapM_ checkExpr parts

-- | Emit the @data {Base}Input = ...@ declaration when the document has
-- @<let>@ declarations; otherwise emit nothing.
genInputRecord :: String -> PomlDoc -> [Dec]
genInputRecord base doc
    | null (pdLets doc) = []
    | otherwise = [DataD [] typeName [] Nothing [RecC typeName fields] derivings]
  where
    typeName = mkName (capitalize base <> "Input")
    fields = map mkField (pdLets doc)
    mkField LetDecl{letName = n, letType = ty} =
        (mkName (T.unpack n), recordBang, pomlTypeToHsType ty)
    derivings = [DerivClause Nothing [ConT ''Eq, ConT ''Show]]

-- | Map a 'PomlType' to the corresponding Haskell field type.
pomlTypeToHsType :: PomlType -> Type
pomlTypeToHsType PTString = ConT ''Text
pomlTypeToHsType PTBoolean = ConT ''Bool
pomlTypeToHsType PTNumber = ConT ''Float
pomlTypeToHsType PTPoml = ConT ''POML

-- | Emit the function signature and body. The function takes the input
-- record when @<let>@ declarations exist, otherwise it is a nullary value.
genFun :: String -> Maybe Name -> Exp -> [Dec]
genFun base mArgName body = [SigD funName sigTy, FunD funName [clause]]
  where
    funName = mkName (lowercaseFirst base)
    sigTy = case mArgName of
        Just _ ->
            AppT
                (AppT ArrowT (ConT (mkName (capitalize base <> "Input"))))
                (ConT ''POML)
        Nothing -> ConT ''POML
    clause = case mArgName of
        Just arg -> Clause [VarP arg] (NormalB body) []
        Nothing -> Clause [] (NormalB body) []

-- | Codegen entry point for a single 'PomlNode'.
genNode :: Map Text PomlType -> Maybe Name -> PomlNode -> Q Exp
genNode varTypes mArgName (NodeText exprs) =
    genNodeText varTypes mArgName exprs
genNode varTypes mArgName (NodeElement name attrs children) =
    case name of
        "p" ->
            appE (conE 'Paragraph) (genChildren varTypes mArgName children)
        "h" ->
            appE
                (appE (conE 'Heading) (maybeIntExp (levelFromAttrs attrs)))
                (genChildren varTypes mArgName children)
        "code" ->
            appE
                (appE (conE 'Code) (maybeTextExp (syntaxFromAttrs attrs)))
                (genChildren varTypes mArgName children)
        "b" ->
            appE (conE 'Strong) (genChildren varTypes mArgName children)
        "i" ->
            appE (conE 'Italic) (genChildren varTypes mArgName children)
        "u" ->
            appE (conE 'Underline) (genChildren varTypes mArgName children)
        "s" ->
            appE (conE 'Strikethrough) (genChildren varTypes mArgName children)
        "span" ->
            appE (conE 'Span) (genChildren varTypes mArgName children)
        "br" -> case children of
            [] -> conE 'Br
            _ -> fail "makePoml: <br> must not have children"
        "list" ->
            appE
                (appE (conE 'List) (varE 'defaultListParams))
                (genItems varTypes mArgName children)
        "role" ->
            appE
                (appE (conE 'Role) (varE 'defaultRoleParams))
                (genChildren varTypes mArgName children)
        "task" ->
            appE
                (appE (conE 'Task) (varE 'defaultTaskParams))
                (genChildren varTypes mArgName children)
        "input" ->
            appE
                (appE (conE 'ExampleInput) (varE 'defaultExampleInputParams))
                (genChildren varTypes mArgName children)
        "output" ->
            appE
                (appE (conE 'ExampleOutput) (varE 'defaultExampleOutputParams))
                (genChildren varTypes mArgName children)
        "example" ->
            appE
                (appE (conE 'Example) (varE 'defaultExampleParams))
                (genChildren varTypes mArgName children)
        "cp" ->
            appE
                (appE (conE 'CP) (appE (varE 'defaultCPParams) (genCaptionExpr varTypes mArgName (join (lookup "caption" attrs)))))
                (genChildren varTypes mArgName children)
        "examples" ->
            appE
                (appE (conE 'ExampleSet) (varE 'defaultExampleSetParams))
                (genExamples varTypes mArgName children)
        "item" ->
            fail "makePoml: <item> is only valid directly inside <list>"
        other ->
            fail ("makePoml: unknown element: <" <> T.unpack other <> ">")

-- | Lower a 'NodeText' run into a 'POML' expression.
genNodeText :: Map Text PomlType -> Maybe Name -> [TemplateExpr] -> Q Exp
genNodeText varTypes mArgName exprs =
    case exprs of
        [TLit t] ->
            appE (conE 'Text) (textLitE t)
        [TVar n] ->
            singleTVar n
        _ -> do
            let atoms = concatMap flatten exprs
                partExps = map (genConcatPart varTypes mArgName) atoms
            validateNoPomlInConcat varTypes atoms
            appE (conE 'Text) (combineWith '(<>) partExps)
  where
    singleTVar n =
        case Map.lookup n varTypes of
            Just PTString ->
                appE (conE 'Text) (fieldAccess n mArgName)
            Just PTBoolean ->
                appE
                    (conE 'Text)
                    ( appE
                        ( appE
                            ( appE
                                (varE 'bool)
                                (textLitE "false")
                            )
                            (textLitE "true")
                        )
                        (fieldAccess n mArgName)
                    )
            Just PTNumber ->
                appE
                    (conE 'Text)
                    (appE (varE 'tshow) (fieldAccess n mArgName))
            Just PTPoml ->
                fieldAccess n mArgName
            Nothing ->
                fail ("makePoml: undeclared variable: " <> T.unpack n)

-- | Validate that no @poml@-typed variable appears in a concatenation
-- context (its 'POML' value cannot be appended to 'Text').
validateNoPomlInConcat :: Map Text PomlType -> [TemplateExpr] -> Q ()
validateNoPomlInConcat varTypes = mapM_ check
  where
    check (TVar n)
        | Map.lookup n varTypes == Just PTPoml =
            fail
                ( "makePoml: poml-typed variable '"
                    <> T.unpack n
                    <> "' cannot participate in concatenation"
                )
    check _ = pure ()

-- | Render one atom of a concatenation to a 'Text'-valued expression.
genConcatPart :: Map Text PomlType -> Maybe Name -> TemplateExpr -> Q Exp
genConcatPart _ _ (TLit t) = textLitE t
genConcatPart varTypes mArgName (TVar n) =
    case Map.lookup n varTypes of
        Just PTString ->
            fieldAccess n mArgName
        Just PTBoolean ->
            appE
                ( appE
                    ( appE
                        (varE 'bool)
                        (textLitE "false")
                    )
                    (textLitE "true")
                )
                (fieldAccess n mArgName)
        Just PTNumber ->
            appE (varE 'tshow) (fieldAccess n mArgName)
        Just PTPoml ->
            -- Defensive: 'validateNoPomlInConcat' should have caught this already.
            fail
                ( "makePoml: poml-typed variable '"
                    <> T.unpack n
                    <> "' cannot participate in concatenation"
                )
        Nothing ->
            fail ("makePoml: undeclared variable: " <> T.unpack n)
genConcatPart varTypes mArgName (TConcat parts) =
    combineWith '(<>) (map (genConcatPart varTypes mArgName) parts)

-- | Codegen the children list of an element as @[POML]@.
genChildren :: Map Text PomlType -> Maybe Name -> [PomlNode] -> Q Exp
genChildren varTypes mArgName children =
    listE (map (genNode varTypes mArgName) children)

-- | Build a 'Text'-valued expression for a @<cp>@ @caption@ attribute value.
-- The caller is expected to have collapsed the double-'Maybe' of an attribute
-- lookup (absent attribute = outer 'Nothing', empty value = inner 'Nothing');
-- both cases fail here with a missing-caption error. A literal, a variable, or
-- a concatenation is lowered by reusing the same atom-rendering logic that
-- 'genNodeText' uses for text content. A @poml@-typed variable in the caption
-- fails: @cpCaption :: Text@ cannot hold a 'POML' value.
genCaptionExpr
    :: Map Text PomlType
    -> Maybe Name
    -> Maybe TemplateExpr
    -> Q Exp
genCaptionExpr _ _ Nothing =
    fail "makePoml: <cp> requires a 'caption' attribute"
genCaptionExpr varTypes mArgName (Just expr) = do
    let atoms = flatten expr
    validateNoPomlInConcat varTypes atoms
    case atoms of
        [single] -> genConcatPart varTypes mArgName single
        many -> combineWith '(<>) (map (genConcatPart varTypes mArgName) many)

-- | Codegen the @[[POML]]@ body of a @<list>@ element. Each child must be
-- an @<item>@.
genItems :: Map Text PomlType -> Maybe Name -> [PomlNode] -> Q Exp
genItems varTypes mArgName children =
    listE (map genItem children)
  where
    genItem (NodeElement "item" _ itemChildren) =
        genChildren varTypes mArgName itemChildren
    genItem (NodeElement other _ _) =
        fail
            ( "makePoml: <list> may only contain <item> children, found <"
                <> T.unpack other
                <> ">"
            )
    genItem (NodeText _) =
        fail "makePoml: <list> may not contain direct text; wrap it in <item>"

-- | Codegen the @[[POML]]@ body of an @<examples>@ element. Each child must
-- be an @<example>@.
genExamples :: Map Text PomlType -> Maybe Name -> [PomlNode] -> Q Exp
genExamples varTypes mArgName children =
    listE (map genExample children)
  where
    genExample (NodeElement "example" _ itemChildren) =
        genChildren varTypes mArgName itemChildren
    genExample (NodeElement other _ _) =
        fail
            ( "makePoml: <examples> may only contain <example> children, found <"
                <> T.unpack other
                <> ">"
            )
    genExample (NodeText _) =
        fail "makePoml: <examples> may not contain direct text; wrap it in <example>"

-- | Build a non-empty chain of expressions joined by the named binary
-- operator. Fails on the empty list (which would not type-check).
combineWith :: Name -> [Q Exp] -> Q Exp
combineWith _ [] = fail "makePoml: internal error: empty expression list"
combineWith _ [e] = e
combineWith op (first : rest) = go first rest
  where
    go acc [] = acc
    go acc (x : xs) = go (appE (appE (varE op) acc) x) xs

-- | Build @field arg@ accessing a record field by generated name.
fieldAccess :: Text -> Maybe Name -> Q Exp
fieldAccess n (Just arg) =
    appE (varE (mkName (T.unpack n))) (varE arg)
fieldAccess _ Nothing =
    fail "makePoml: internal error: variable referenced without input record"

-- | Generate a Haskell string literal; the consumer module must have
-- @OverloadedStrings@ enabled so the literal coerces to 'Text'.
textLitE :: Text -> Q Exp
textLitE = litE . stringL . T.unpack

-- | Generate @Nothing@ or @Just n@.
maybeIntExp :: Maybe Int -> Q Exp
maybeIntExp Nothing = conE 'Nothing
maybeIntExp (Just n) = appE (conE 'Just) (litE (integerL (fromIntegral n)))

-- | Generate @Nothing@ or @Just "..."@.
maybeTextExp :: Maybe Text -> Q Exp
maybeTextExp Nothing = conE 'Nothing
maybeTextExp (Just t) = appE (conE 'Just) (textLitE t)

-- | Look up the @level@ attribute as a static integer.
levelFromAttrs :: [(Text, Maybe TemplateExpr)] -> Maybe Int
levelFromAttrs attrs =
    case join (lookup "level" attrs) of
        Just (TLit t) -> readMaybe (T.unpack t)
        _ -> Nothing

-- | Look up the @syntax@ attribute as a static literal.
syntaxFromAttrs :: [(Text, Maybe TemplateExpr)] -> Maybe Text
syntaxFromAttrs attrs =
    case join (lookup "syntax" attrs) of
        Just (TLit t) -> Just t
        _ -> Nothing

-- | Flatten a 'TemplateExpr' (which may contain nested 'TConcat') into the
-- underlying atomic operands.
flatten :: TemplateExpr -> [TemplateExpr]
flatten (TConcat parts) = concatMap flatten parts
flatten atom = [atom]

-- | Capitalise the first character; no-op on the empty string.
capitalize :: String -> String
capitalize [] = []
capitalize (c : cs) = toUpper c : cs

-- | Lowercase the first character; no-op on the empty string.
lowercaseFirst :: String -> String
lowercaseFirst [] = []
lowercaseFirst (c : cs) = toLower c : cs
