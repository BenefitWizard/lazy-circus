{-# LANGUAGE TemplateHaskell #-}

{- |
PURPOSE: Generate POML AST values (and optional input record types) from
  @.poml@ source files at compile time via a Template Haskell macro.
SCOPE: Reading and parsing @.poml@ files, building the variable type
  environment, validating the parsed document (declared variables, valid
  element names, no @poml@- or @untrusted@-typed variables inside
  concatenations), and
  emitting a record type plus a function definition whose body constructs a
  @[POML]@ list (one entry per top-level body node).
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
    @ExampleSet@, @Example@, @ExampleInput@, @ExampleOutput@,
    @Untrusted@), plus the
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

import Control.Exception (IOException)
import Data.Char (toLower, toUpper)
import Data.Text qualified as T
import RIO.Map (Map)
import RIO.Map qualified as Map
import Language.Haskell.TH hiding (Code)
import Language.Haskell.TH.Syntax (addDependentFile)
import RIO.FilePath (takeDirectory, (</>))
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

-- | How a declared template variable is realised in generated code. A runtime
-- input is read from the generated record argument at runtime; a compile-time
-- constant is a 'Text' literal baked into the splice (the entire contents of a
-- @<let src=\"...\"\/>@ file, already read by 'resolveSrcLets').
data VarKind
    = VKInput PomlType
    -- ^ runtime input field carrying a declared 'PomlType'.
    | VKConst Text
    -- ^ compile-time constant whose value is the inlined file contents.
    deriving (Eq)

-- | Total accessor for a 'LetDecl' variable name, regardless of constructor.
letDeclName :: LetDecl -> Text
letDeclName (LetInput n _) = n
letDeclName (LetFile n _) = n

-- | 'True' for a runtime input declaration ('LetInput'); 'False' for a
-- compile-time file constant ('LetFile').
isInputLet :: LetDecl -> Bool
isInputLet LetInput{} = True
isInputLet LetFile{} = False

{- | Compile-time macro that reads, parses, and lowers a @.poml@ file into a
Haskell record type (when the document declares template variables) and a
function returning a @[POML]@ list.

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
  declaration whose body is a @[POML]@ list (one element per top-level body
  node). Calls 'fail' on any parse error, undeclared variable reference,
  empty body, invalid element name, or @poml@- or @untrusted@-typed
  variable inside a concatenation.
-}
makePoml :: String -> FilePath -> Q [Dec]
makePoml base filePath = do
    content <- runIO (readFileUtf8 filePath)
    addDependentFile filePath
    case parsePoml content of
        Left err -> fail ("makePoml: failed to parse " <> filePath <> ": " <> err)
        Right doc -> do
            constContents <- resolveSrcLets filePath doc
            generateDecls base constContents doc

-- | Drive validation and code generation for a parsed 'PomlDoc'. The
-- @constContents@ map carries the already-read contents of each @<let src=…>@
-- file (keyed by variable name); runtime input variables are taken from the
-- 'PomlDoc' declarations.
generateDecls :: String -> Map Text Text -> PomlDoc -> Q [Dec]
generateDecls base constContents doc = do
    mapM_ (validateLetName . letDeclName) (pdLets doc)
    let inputLets = [ld | ld <- pdLets doc, isInputLet ld]
        varEnv = buildVarEnv constContents (pdLets doc)
        mArgName =
            if null inputLets
                then Nothing
                else Just (mkName "arg")
    bodyNodes <- requireNonEmptyBody doc
    mapM_ (validateVarRefs varEnv) bodyNodes
    bodyExp <- genBodyList varEnv mArgName bodyNodes
    funDecs <- genFun base mArgName bodyExp
    pure (genInputRecord base inputLets <> funDecs)

-- | Read each 'LetFile' source file (path relative to the @.poml@ directory),
-- register it with 'addDependentFile', and return a map from variable name to
-- the file's entire contents, read verbatim. Fails the splice with a clear
-- message naming the resolved path if a file cannot be read.
resolveSrcLets :: FilePath -> PomlDoc -> Q (Map Text Text)
resolveSrcLets pomlPath doc = fmap Map.fromList (traverse readSrc fileLets)
  where
    dir = takeDirectory pomlPath
    fileLets = [ld | ld <- pdLets doc, not (isInputLet ld)]
    readSrc (LetFile n src) = do
        let path = dir </> T.unpack src
        addDependentFile path
        result <- runIO (try (readFileUtf8 path) :: IO (Either IOException Text))
        case result of
            Right c -> pure (n, c)
            Left exc ->
                fail
                    ( "makePoml: cannot read <let name=\""
                        <> T.unpack n
                        <> "\" src=\""
                        <> T.unpack src
                        <> "\"> (resolved to "
                        <> path
                        <> "): "
                        <> show exc
                    )
    readSrc LetInput{} =
        error "makePoml: internal error: LetInput reached resolveSrcLets"

-- | Build the variable environment consumed by validation and codegen. Runtime
-- inputs map to their declared 'PomlType'; file constants map to their inlined
-- (already-read) contents as 'VKConst'. A missing entry for a 'LetFile' is an
-- internal error — 'resolveSrcLets' guarantees one exists.
buildVarEnv :: Map Text Text -> [LetDecl] -> Map Text VarKind
buildVarEnv constContents = Map.fromList . map mk
  where
    mk (LetInput n ty) = (n, VKInput ty)
    mk (LetFile n _) = case Map.lookup n constContents of
        Just c -> (n, VKConst c)
        Nothing ->
            error
                ("makePoml: internal error: missing src content for " <> T.unpack n)

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

-- | Enforce that the body has at least one top-level node; return all of them.
-- A @.poml@ body with multiple top-level elements is supported and lowered to
-- a @[POML]@ list (one entry per element). An empty body fails.
requireNonEmptyBody :: PomlDoc -> Q [PomlNode]
requireNonEmptyBody doc = case pdBody doc of
    [] -> fail "makePoml: empty body"
    nodes -> pure nodes

-- | Fail if any 'TVar' in the body lacks a matching @<let>@ declaration.
-- Both text content and attribute values (e.g. a @<cp>@ @caption@) are walked,
-- so undeclared variables are reported with a clear message before codegen.
validateVarRefs :: Map Text VarKind -> PomlNode -> Q ()
validateVarRefs varEnv = checkNode
  where
    checkNode (NodeText exprs) = mapM_ checkExpr exprs
    checkNode (NodeElement _ attrs children) = do
        mapM_ checkExpr [e | (_, Just e) <- attrs]
        mapM_ checkNode children

    checkExpr (TVar n)
        | Map.member n varEnv = pure ()
        | otherwise = fail ("makePoml: undeclared variable: " <> T.unpack n)
    checkExpr (TLit _) = pure ()
    checkExpr (TConcat parts) = mapM_ checkExpr parts

-- | Emit the @data {Base}Input = ...@ declaration when the document has
-- runtime-input @<let>@ declarations; otherwise emit nothing. Compile-time file
-- constants ('LetFile') are excluded — they are inlined as literals, not record
-- fields.
genInputRecord :: String -> [LetDecl] -> [Dec]
genInputRecord base inputLets
    | null inputLets = []
    | otherwise = [DataD [] typeName [] Nothing [RecC typeName fields] derivings]
  where
    typeName = mkName (capitalize base <> "Input")
    fields = map mkField inputLets
    mkField (LetInput n ty) =
        (mkName (T.unpack n), recordBang, pomlTypeToHsType ty)
    mkField LetFile{} =
        error "makePoml: internal error: LetFile reached genInputRecord"
    derivings = [DerivClause Nothing [ConT ''Eq, ConT ''Show]]

-- | Map a 'PomlType' to the corresponding Haskell field type.
pomlTypeToHsType :: PomlType -> Type
pomlTypeToHsType PTString = ConT ''Text
pomlTypeToHsType PTBoolean = ConT ''Bool
pomlTypeToHsType PTNumber = ConT ''Float
pomlTypeToHsType PTPoml = ConT ''POML
-- | @type="untrusted"@ fields stay 'Text'; the protective fence is applied at
-- render time ('renderPOMLTag'), and the splice wraps the field access in
-- 'Untrusted'.
pomlTypeToHsType PTUntrusted = ConT ''Text

-- | Emit the function signature and body. The function takes the input
-- record when @<let>@ declarations exist, otherwise it is a nullary value.
-- The body type is always @[POML]@ — one element per top-level body node.
genFun :: String -> Maybe Name -> Exp -> Q [Dec]
genFun base mArgName body = do
    resultTy <- [t| [POML] |]
    let funName = mkName (lowercaseFirst base)
        sigTy = case mArgName of
            Just _ ->
                AppT
                    (AppT ArrowT (ConT (mkName (capitalize base <> "Input"))))
                    resultTy
            Nothing -> resultTy
        clause = case mArgName of
            Just arg -> Clause [VarP arg] (NormalB body) []
            Nothing -> Clause [] (NormalB body) []
    pure [SigD funName sigTy, FunD funName [clause]]

-- | Codegen a @[POML]@ list literal from the document body nodes — one entry
-- per top-level node.
genBodyList :: Map Text VarKind -> Maybe Name -> [PomlNode] -> Q Exp
genBodyList varEnv mArgName nodes =
    listE (map (genNode varEnv mArgName) nodes)

-- | Codegen entry point for a single 'PomlNode'.
genNode :: Map Text VarKind -> Maybe Name -> PomlNode -> Q Exp
genNode varEnv mArgName (NodeText exprs) =
    genNodeText varEnv mArgName exprs
genNode varEnv mArgName (NodeElement name attrs children) =
    case name of
        "p" ->
            appE (conE 'Paragraph) (genChildren varEnv mArgName children)
        "h" ->
            appE
                (appE (conE 'Heading) (maybeIntExp (levelFromAttrs attrs)))
                (genChildren varEnv mArgName children)
        "code" ->
            appE
                (appE (conE 'Code) (maybeTextExp (syntaxFromAttrs attrs)))
                (genChildren varEnv mArgName children)
        "b" ->
            appE (conE 'Strong) (genChildren varEnv mArgName children)
        "i" ->
            appE (conE 'Italic) (genChildren varEnv mArgName children)
        "u" ->
            appE (conE 'Underline) (genChildren varEnv mArgName children)
        "s" ->
            appE (conE 'Strikethrough) (genChildren varEnv mArgName children)
        "span" ->
            appE (conE 'Span) (genChildren varEnv mArgName children)
        "br" -> case children of
            [] -> conE 'Br
            _ -> fail "makePoml: <br> must not have children"
        "list" ->
            appE
                (appE (conE 'List) (varE 'defaultListParams))
                (genItems varEnv mArgName children)
        "role" ->
            appE
                (appE (conE 'Role) (varE 'defaultRoleParams))
                (genChildren varEnv mArgName children)
        "task" ->
            appE
                (appE (conE 'Task) (varE 'defaultTaskParams))
                (genChildren varEnv mArgName children)
        "input" ->
            appE
                (appE (conE 'ExampleInput) (varE 'defaultExampleInputParams))
                (genChildren varEnv mArgName children)
        "output" ->
            appE
                (appE (conE 'ExampleOutput) (varE 'defaultExampleOutputParams))
                (genChildren varEnv mArgName children)
        "example" ->
            appE
                (appE (conE 'Example) (varE 'defaultExampleParams))
                (genChildren varEnv mArgName children)
        "cp" ->
            appE
                (appE (conE 'CP) (appE (varE 'defaultCPParams) (genCaptionExpr varEnv mArgName (join (lookup "caption" attrs)))))
                (genChildren varEnv mArgName children)
        "examples" ->
            appE
                (appE (conE 'ExampleSet) (varE 'defaultExampleSetParams))
                (genExamples varEnv mArgName children)
        "item" ->
            fail "makePoml: <item> is only valid directly inside <list>"
        other ->
            fail ("makePoml: unknown element: <" <> T.unpack other <> ">")

-- | Lower a 'NodeText' run into a 'POML' expression.
genNodeText :: Map Text VarKind -> Maybe Name -> [TemplateExpr] -> Q Exp
genNodeText varEnv mArgName exprs =
    case exprs of
        [TLit t] ->
            appE (conE 'Text) (textLitE t)
        [TVar n] ->
            singleTVar n
        _ -> do
            let atoms = concatMap flatten exprs
                partExps = map (genConcatPart varEnv mArgName) atoms
            validateNoPomlInConcat varEnv atoms
            appE (conE 'Text) (combineWith '(<>) partExps)
  where
    singleTVar n =
        case Map.lookup n varEnv of
            Just (VKInput PTString) ->
                appE (conE 'Text) (fieldAccess n mArgName)
            Just (VKInput PTBoolean) ->
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
            Just (VKInput PTNumber) ->
                appE
                    (conE 'Text)
                    (appE (varE 'tshow) (fieldAccess n mArgName))
            Just (VKInput PTPoml) ->
                fieldAccess n mArgName
            Just (VKInput PTUntrusted) ->
                appE (conE 'Untrusted) (fieldAccess n mArgName)
            Just (VKConst c) ->
                appE (conE 'Text) (textLitE c)
            Nothing ->
                fail ("makePoml: undeclared variable: " <> T.unpack n)

-- | Validate that no variable whose type cannot be concatenated appears in a
-- concatenation context: @poml@-typed (a 'POML' value cannot be appended to
-- 'Text') and @untrusted@-typed (the value must be spliced as an 'Untrusted'
-- node, not text) variables are both rejected.
validateNoPomlInConcat :: Map Text VarKind -> [TemplateExpr] -> Q ()
validateNoPomlInConcat varEnv = mapM_ check
  where
    check (TVar n) = case Map.lookup n varEnv of
        Just (VKInput PTPoml) -> reject "poml" n
        Just (VKInput PTUntrusted) -> reject "untrusted" n
        _ -> pure ()
    check _ = pure ()

    -- | Fail the splice, naming the variable and its offending type.
    reject kind n =
        fail
            ( "makePoml: "
                <> kind
                <> "-typed variable '"
                <> T.unpack n
                <> "' cannot participate in concatenation"
            )

-- | Render one atom of a concatenation to a 'Text'-valued expression.
genConcatPart :: Map Text VarKind -> Maybe Name -> TemplateExpr -> Q Exp
genConcatPart _ _ (TLit t) = textLitE t
genConcatPart varEnv mArgName (TVar n) =
    case Map.lookup n varEnv of
        Just (VKInput PTString) ->
            fieldAccess n mArgName
        Just (VKInput PTBoolean) ->
            appE
                ( appE
                    ( appE
                        (varE 'bool)
                        (textLitE "false")
                    )
                    (textLitE "true")
                )
                (fieldAccess n mArgName)
        Just (VKInput PTNumber) ->
            appE (varE 'tshow) (fieldAccess n mArgName)
        Just (VKInput PTPoml) ->
            -- Defensive: 'validateNoPomlInConcat' should have caught this already.
            fail
                ( "makePoml: poml-typed variable '"
                    <> T.unpack n
                    <> "' cannot participate in concatenation"
                )
        Just (VKInput PTUntrusted) ->
            -- Defensive: 'validateNoPomlInConcat' should have caught this already.
            fail
                ( "makePoml: untrusted-typed variable '"
                    <> T.unpack n
                    <> "' cannot participate in concatenation"
                )
        Just (VKConst c) ->
            textLitE c
        Nothing ->
            fail ("makePoml: undeclared variable: " <> T.unpack n)
genConcatPart varEnv mArgName (TConcat parts) =
    combineWith '(<>) (map (genConcatPart varEnv mArgName) parts)

-- | Codegen the children list of an element as @[POML]@.
genChildren :: Map Text VarKind -> Maybe Name -> [PomlNode] -> Q Exp
genChildren varEnv mArgName children =
    listE (map (genNode varEnv mArgName) children)

-- | Build a 'Text'-valued expression for a @<cp>@ @caption@ attribute value.
-- The caller is expected to have collapsed the double-'Maybe' of an attribute
-- lookup (absent attribute = outer 'Nothing', empty value = inner 'Nothing');
-- both cases fail here with a missing-caption error. A literal, a variable, or
-- a concatenation is lowered by reusing the same atom-rendering logic that
-- 'genNodeText' uses for text content. A @poml@- or @untrusted@-typed variable
-- in the caption fails: @cpCaption :: Text@ cannot hold a 'POML' value nor a
-- fence-isolated 'Untrusted' node.
genCaptionExpr
    :: Map Text VarKind
    -> Maybe Name
    -> Maybe TemplateExpr
    -> Q Exp
genCaptionExpr _ _ Nothing =
    fail "makePoml: <cp> requires a 'caption' attribute"
genCaptionExpr varEnv mArgName (Just expr) = do
    let atoms = flatten expr
    validateNoPomlInConcat varEnv atoms
    case atoms of
        [single] -> genConcatPart varEnv mArgName single
        many -> combineWith '(<>) (map (genConcatPart varEnv mArgName) many)

-- | Codegen the @[[POML]]@ body of a @<list>@ element. Each child must be
-- an @<item>@.
genItems :: Map Text VarKind -> Maybe Name -> [PomlNode] -> Q Exp
genItems varEnv mArgName children =
    listE (map genItem children)
  where
    genItem (NodeElement "item" _ itemChildren) =
        genChildren varEnv mArgName itemChildren
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
genExamples :: Map Text VarKind -> Maybe Name -> [PomlNode] -> Q Exp
genExamples varEnv mArgName children =
    listE (map genExample children)
  where
    genExample (NodeElement "example" _ itemChildren) =
        genChildren varEnv mArgName itemChildren
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

