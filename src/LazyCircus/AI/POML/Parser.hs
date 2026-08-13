{- |
Parser for the @.poml@ (Prompt-Oriented Markup Language) file format.

A @.poml@ document is an XML document whose root element is @<poml>@. The body
uses a whitelisted set of structural tags: inline/block tags (@p@, @h@, @code@,
@b@, @i@, @u@, @s@, @span@, @br@), list tags (@list@, @item@), and the seven
semantic prompt tags (@role@, @task@, @cp@, @examples@, @example@, @input@,
@output@) that map onto the 'POML' AST. Template variables can be spliced into
text via the @{{name}}@ syntax, and multiple operands may be concatenated with
@+@, e.g. @{{a + " " + b}}@.

@<let name=\"...\" type=\"...\"\/>@ children of @<poml>@ are /metadata/: they declare
template variables consumed by the Template-Haskell code generator (T5) and are
ignored by 'toPOML'.

Because the document is XML, any literal @<@ or @&@ that appears inside template
text must be XML-escaped (@&lt;@, @&amp;@) by the author. The @{{ ... }}@
delimiters themselves are not special to the XML parser and may appear freely in
text content or attribute values.

/Note on the @caption@ attribute of @<cp>@/: 'parsePomlText' requires a static
literal caption (it cannot represent a runtime template in @cpCaption :: Text@).
A templated caption such as @<cp caption=\"{{name}}\">…<\/cp>@ is rejected here
and must instead be spliced via the @makePoml@ TH macro, which can build a
'CPParams' whose @cpCaption@ references an input field at runtime.
-}
module LazyCircus.AI.POML.Parser
    ( -- * Intermediate parse representation
      LetDecl (..)
    , PomlType (..)
    , TemplateExpr (..)
    , PomlNode (..)
    , ElName
    , PomlDoc (..)
      -- * Element registry (shared with TH codegen)
    , allowedElementNames
      -- * Parsing entry points
    , parsePoml
    , parsePomlText
    , toPOML
    ) where

import Data.Char (isAlpha, isAlphaNum)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import LazyCircus.AI.POML.Types
import RIO
import RIO.Map qualified as Map
import RIO.Set qualified as Set
import Text.XML
    ( Document
    , Element
    , Name
    , Node
    , def
    , documentRoot
    , elementAttributes
    , elementName
    , elementNodes
    , nameLocalName
    , parseText
    )
-- 'Text.XML' also exports the 'NodeElement' constructor of its 'Node' type,
-- which clashes with our 'PomlNode' constructor of the same name (required by
-- the spec). We therefore import the XML 'Node' constructors qualified and use
-- the bare name for our own 'PomlNode' constructor.
import Text.XML qualified as XML (Node (NodeContent, NodeElement))

--------------------------------------------------------------------------------
-- Intermediate types
--------------------------------------------------------------------------------

-- | Local name of an XML element, used as the structural tag identifier.
type ElName = Text

-- | Declaration of a template variable produced from a @<let>@ element. A
-- variable is either a runtime input (carrying a declared 'PomlType', supplied
-- via the generated record) or a compile-time constant whose value is the
-- entire contents of an external file, inlined verbatim by the @makePoml@ TH
-- macro.
data LetDecl
    = LetInput Text PomlType
    -- ^ @<let name=\"...\" type=\"...\"\/>@ — a runtime input field: the
    -- variable name and its declared 'PomlType'.
    | LetFile Text Text
    -- ^ @<let name=\"...\" src=\"...\"\/>@ — a compile-time constant: the
    -- variable name and a path (relative to the @.poml@ file) whose entire
    -- contents are inlined at compile time.
    deriving (Eq, Show)

-- | POML template variable type — the @type@ attribute of @<let>@.
data PomlType
    = PTString   -- ^ @type=\"string\"@
    | PTBoolean  -- ^ @type=\"boolean\"@
    | PTNumber   -- ^ @type=\"number\"@
    | PTPoml     -- ^ @type=\"poml\"@
    deriving (Eq, Show)

-- | Expression inside a @{{ ... }}@ template placeholder.
data TemplateExpr
    = TVar Text               -- ^ single variable reference, e.g. @{{name}}@
    | TLit Text               -- ^ string literal piece, e.g. @" "@ inside a concatenation
    | TConcat [TemplateExpr]  -- ^ concatenation with @+@, e.g. @{{a + " " + b}}@
    deriving (Eq, Show)

-- | A parsed node of the @.poml@ body, prior to POML code generation.
data PomlNode
    = NodeText [TemplateExpr]
    -- ^ a run of text possibly containing @{{...}}@ placeholders
    | NodeElement ElName [(Text, Maybe TemplateExpr)] [PomlNode]
    -- ^ element: tag name, attributes, child nodes. Each attribute is a pair of
    -- the attribute name and its value parsed as a 'TemplateExpr' ('Nothing'
    -- for an empty value).
    deriving (Eq, Show)

-- | A complete parsed @.poml@ document.
data PomlDoc = PomlDoc
    { pdLets :: [LetDecl]   -- ^ @<let>@ declarations (codegen metadata)
    , pdBody :: [PomlNode]  -- ^ body content nodes
    }
    deriving (Eq, Show)

-- | Whitelisted element tag names allowed in the @.poml@ body.
--   Shared between this parser and the Template-Haskell code generator (T5).
allowedElementNames :: Set Text
allowedElementNames =
    Set.fromList
        [ "p"
        , "h"
        , "code"
        , "b"
        , "i"
        , "u"
        , "s"
        , "span"
        , "br"
        , "list"
        , "item"
        , "role"
        , "task"
        , "cp"
        , "examples"
        , "example"
        , "input"
        , "output"
        ]

--------------------------------------------------------------------------------
-- Parsing entry points
--------------------------------------------------------------------------------

-- | Parse a @.poml@ document into its intermediate 'PomlDoc' representation.
-- PRE-CONTRACT: The input is a piece of XML text.
-- POST-CONTRACT: On @Right@, the root element is @<poml>@, every @<let>@
-- declaration is collected in 'pdLets', and every body node carries a tag name
-- from 'allowedElementNames'.
parsePoml :: Text -> Either String PomlDoc
parsePoml input =
    case parseText def (TL.fromStrict input) of
        Left exc -> Left (displayException exc)
        Right doc -> docToPomlDoc doc

-- | Parse a @.poml@ document and lower it to a list of 'POML' AST nodes — one
-- per top-level body element.
--
-- Returns @Left@ for template concatenations (@{{a + b}}@), which cannot be
-- expressed in the 'POML' AST and require the @makePoml@ TH macro instead.
-- PRE-CONTRACT: The body contains at least one top-level element.
parsePomlText :: Text -> Either String [POML]
parsePomlText input = parsePoml input >>= toPOML

-- | Lower an intermediate 'PomlDoc' to a list of 'POML' AST nodes — one per
-- top-level body element.
--
-- Discards 'pdLets' (metadata consumed by codegen). An empty body is rejected
-- (@Left@); a non-empty body is lowered element-wise via 'nodeToPOML'. Returns
-- @Left@ when any body node uses template concatenation, which only the TH
-- macro can represent.
toPOML :: PomlDoc -> Either String [POML]
toPOML doc = case pdBody doc of
    [] -> Left "Empty .poml body (expected at least one top-level element)"
    nodes -> traverse nodeToPOML nodes

--------------------------------------------------------------------------------
-- XML document → PomlDoc
--------------------------------------------------------------------------------

-- | Convert a parsed XML 'Document' into a 'PomlDoc'.
docToPomlDoc :: Document -> Either String PomlDoc
docToPomlDoc doc = do
    let root = documentRoot doc
    if nameLocalName (elementName root) /= "poml"
        then Left "Expected <poml> root element"
        else do
            (lets, body) <- walkRootChildren (elementNodes root)
            pure PomlDoc{pdLets = lets, pdBody = body}

-- | Classified piece of a @<poml>@ root element's children (internal).
data RootPart = RLet LetDecl | RBody PomlNode | RSkip

-- | Walk the children of @<poml>@, separating @<let>@ declarations from body.
walkRootChildren :: [Node] -> Either String ([LetDecl], [PomlNode])
walkRootChildren nodes = do
    parts <- traverse classifyRoot nodes
    pure ([ld | RLet ld <- parts], [pn | RBody pn <- parts])
  where
    classifyRoot (XML.NodeElement e)
        | nameLocalName (elementName e) == "let" = RLet <$> parseLetDecl e
        | otherwise = RBody <$> elementToNode e
    classifyRoot (XML.NodeContent t)
        | T.null (T.strip t) = Right RSkip
        | otherwise = RBody . NodeText <$> parseTemplateExprs t
    classifyRoot _ = Right RSkip

-- | Parse a @<let>@ element into a 'LetDecl'. The presence of a @src@
-- attribute selects the constructor: @src@ inlines an external file as a
-- compile-time constant ('LetFile'); otherwise a @type@ attribute declares a
-- runtime input field ('LetInput'). Specifying both or neither is an error.
parseLetDecl :: Element -> Either String LetDecl
parseLetDecl e = do
    let attrs = elementAttributes e
    name <-
        maybe (Left "<let> requires a 'name' attribute") Right $
            Map.lookup "name" attrs
    case (Map.lookup "type" attrs, Map.lookup "src" attrs) of
        (Just typeText, Nothing) ->
            LetInput name <$> parsePomlType typeText
        (Nothing, Just src) ->
            pure (LetFile name src)
        (Just _, Just _) ->
            Left "<let> may not specify both 'type' and 'src'"
        (Nothing, Nothing) ->
            Left "<let> requires either a 'type' or a 'src' attribute"

-- | Map a @<let>@ @type@ attribute value to its 'PomlType'.
parsePomlType :: Text -> Either String PomlType
parsePomlType "string" = Right PTString
parsePomlType "boolean" = Right PTBoolean
parsePomlType "number" = Right PTNumber
parsePomlType "poml" = Right PTPoml
parsePomlType other =
    Left
        ( "Invalid <let> type: "
            <> T.unpack other
            <> " (expected one of: string, boolean, number, poml)"
        )

-- | Convert an XML 'Element' (whose tag is whitelisted) into a body 'PomlNode'.
elementToNode :: Element -> Either String PomlNode
elementToNode e = do
    let nm = nameLocalName (elementName e)
    if not (Set.member nm allowedElementNames)
        then Left ("Unknown element: <" <> T.unpack nm <> ">")
        else do
            attrs <- traverse parseAttr (Map.toAscList (elementAttributes e))
            children <- elementChildrenToNodes nm (elementNodes e)
            pure (NodeElement nm attrs children)

-- | Parse a single XML attribute into a @(name, maybe-template-expr)@ pair.
parseAttr :: (Name, Text) -> Either String (Text, Maybe TemplateExpr)
parseAttr (k, v) = do
    mexpr <- parseAttrValue v
    pure (nameLocalName k, mexpr)

-- | Convert the child nodes of a body element. Whitespace-only text is
--   preserved as inline content everywhere except inside block containers
--   (currently @<list>@ and @<examples>@), where it is treated as XML
--   formatting noise.
elementChildrenToNodes :: ElName -> [Node] -> Either String [PomlNode]
elementChildrenToNodes parentName nodes = do
    maybeNodes <- traverse (xmlNodeToPomlNode parentName) nodes
    pure (catMaybes maybeNodes)

-- | Convert a single XML 'Node' to @Maybe PomlNode@ (@Nothing@ for ignorable).
--   Whitespace-only text is preserved as a 'NodeText' everywhere except inside
--   block containers like @<list>@ and @<examples>@, where it is dropped as
--   formatting noise.
xmlNodeToPomlNode :: ElName -> Node -> Either String (Maybe PomlNode)
xmlNodeToPomlNode _ (XML.NodeElement e) = Just <$> elementToNode e
xmlNodeToPomlNode parentName (XML.NodeContent t)
    | T.null (T.strip t) && isBlockContainer parentName = Right Nothing
    | otherwise = Just . NodeText <$> parseTemplateExprs t
xmlNodeToPomlNode _ _ = Right Nothing

-- | Whether the parent element is a block container whose direct child
--   whitespace should be ignored as XML formatting noise.
isBlockContainer :: ElName -> Bool
isBlockContainer "list" = True
isBlockContainer "examples" = True
isBlockContainer _ = False

-- | Parse an XML attribute value into a template expression, if non-empty.
-- @Nothing@ is produced for empty/whitespace-only values; otherwise the value
-- is parsed for @{{...}}@ the same way as text content.
parseAttrValue :: Text -> Either String (Maybe TemplateExpr)
parseAttrValue v
    | T.null (T.strip v) = Right Nothing
    | otherwise = do
        es <- parseTemplateExprs v
        case es of
            [] -> Right Nothing
            [e] -> Right (Just e)
            _ -> Right (Just (TConcat es))

--------------------------------------------------------------------------------
-- Template expression parsing ({{...}} inside text)
--------------------------------------------------------------------------------

-- | Parse a text run into a list of template expressions, splitting on
-- @{{ ... }}@ placeholders. Plain text becomes 'TLit'; @{{name}}@ becomes
-- 'TVar'; @{{a + " " + b}}@ becomes 'TConcat'.
-- PRE-CONTRACT: None.
-- POST-CONTRACT: On @Right@, every placeholder is closed with @}}@; the result
-- is empty only when the input is empty.
parseTemplateExprs :: Text -> Either String [TemplateExpr]
parseTemplateExprs input0 = go input0
  where
    go text
        | T.null text = Right []
        | otherwise =
            -- 'T.breakOn needle haystack' returns @(before, rest)@ where @rest@
            -- begins with the needle (or is empty when the needle is absent).
            let (before, restWithOpen) = T.breakOn "{{" text
            in if T.null restWithOpen
                then -- no "{{" anywhere: the whole run is a literal
                    Right (litNonEmpty before)
                else
                    let afterOpen = T.drop 2 restWithOpen
                        (exprRaw, restWithClose) = T.breakOn "}}" afterOpen
                    in if T.null restWithClose
                        then Left "Unterminated {{...}} in template"
                        else do
                            expr <- parseInside exprRaw
                            let afterClose = T.drop 2 restWithClose
                            restNodes <- go afterClose
                            Right (litNonEmpty before <> [expr] <> restNodes)

    -- | Emit @[TLit t]@ for non-empty @t@, otherwise @[]@.
    litNonEmpty t
        | T.null t = []
        | otherwise = [TLit t]

-- | Parse the contents of a single @{{ ... }}@ placeholder into one expression.
parseInside :: Text -> Either String TemplateExpr
parseInside raw
    | T.null (T.strip raw) = Left "Empty template expression {{}}"
    | otherwise =
        let parts = map T.strip (splitTopLevelPlus raw)
        in case parts of
            [single] -> parseExprPart single
            many -> TConcat <$> traverse parseExprPart many

-- | Parse a single operand: a variable reference or a quoted string literal.
parseExprPart :: Text -> Either String TemplateExpr
parseExprPart part
    | T.null part = Left "Empty template operand in {{...}}"
    | T.head part == '"' && T.length part >= 2 && T.last part == '"' =
        Right (TLit (unescapeString (T.init (T.tail part))))
    | T.head part == '"' =
        Left ("Unterminated string literal in template: " <> T.unpack part)
    | isValidIdent part = Right (TVar part)
    | otherwise =
        Left ("Invalid template operand: " <> T.unpack part)

-- | Split on top-level @+@, ignoring @+@ that occurs inside double quotes.
splitTopLevelPlus :: Text -> [Text]
splitTopLevelPlus = map T.pack . go False [] [] . T.unpack
  where
    go :: Bool -> [Char] -> [[Char]] -> [Char] -> [[Char]]
    go _ cur acc [] = reverse (reverse cur : acc)
    go inStr cur acc (c : cs)
        | c == '"' = go (not inStr) (c : cur) acc cs
        | c == '+' && not inStr = go False [] (reverse cur : acc) cs
        | otherwise = go inStr (c : cur) acc cs

-- | Is the text a valid bare variable identifier?
isValidIdent :: Text -> Bool
isValidIdent t = case T.uncons t of
    Nothing -> False
    Just (c, rest) -> isIdentStart c && T.all isIdentChar rest
  where
    isIdentStart :: Char -> Bool
    isIdentStart c = c == '_' || isAlpha c
    isIdentChar :: Char -> Bool
    isIdentChar c = c == '_' || isAlphaNum c

-- | Minimally unescape @\\"@, @\\\\@, @\\n@, @\\t@ in a string literal body.
unescapeString :: Text -> Text
unescapeString = T.pack . go . T.unpack
  where
    go [] = []
    go ('\\' : c : cs) = case c of
        '"' -> '"' : go cs
        '\\' -> '\\' : go cs
        'n' -> '\n' : go cs
        't' -> '\t' : go cs
        other -> '\\' : other : go cs
    go (c : cs) = c : go cs

--------------------------------------------------------------------------------
-- PomlDoc → POML AST
--------------------------------------------------------------------------------

-- | Lower a single 'PomlNode' to a 'POML' AST node.
--
-- Template concatenations in text become @Left@ (use the @makePoml@ TH macro
-- instead, since the 'POML' AST cannot represent them).
nodeToPOML :: PomlNode -> Either String POML
nodeToPOML (NodeText exprs) = case exprs of
    [TLit t] -> Right (Text t)
    [TVar n] -> Right (Var n)
    _ ->
        Left
            "Template concatenation cannot be represented in POML AST; use makePoml TH macro instead."
nodeToPOML (NodeElement nm attrs children) = case nm of
    "p" -> Paragraph <$> traverse nodeToPOML children
    "h" -> Heading (levelFromAttrs attrs) <$> traverse nodeToPOML children
    "code" -> Code (syntaxFromAttrs attrs) <$> traverse nodeToPOML children
    "b" -> Strong <$> traverse nodeToPOML children
    "i" -> Italic <$> traverse nodeToPOML children
    "u" -> Underline <$> traverse nodeToPOML children
    "s" -> Strikethrough <$> traverse nodeToPOML children
    "span" -> Span <$> traverse nodeToPOML children
    "br" -> case children of
        [] -> Right Br
        _ -> Left "<br/> must not have children"
    "list" -> listToPOML children
    "role" -> Role defaultRoleParams <$> traverse nodeToPOML children
    "task" -> Task defaultTaskParams <$> traverse nodeToPOML children
    "input" -> ExampleInput defaultExampleInputParams <$> traverse nodeToPOML children
    "output" -> ExampleOutput defaultExampleOutputParams <$> traverse nodeToPOML children
    "example" -> Example defaultExampleParams <$> traverse nodeToPOML children
    "cp" -> do
        caption <- cpCaptionStatic attrs
        CP (defaultCPParams caption) <$> traverse nodeToPOML children
    "examples" -> examplesToPOML children
    "item" -> Left "<item> is only valid directly inside <list>"
    other -> Left ("Unknown element: <" <> T.unpack other <> ">")

-- | Lower a @<list>@ element: each child must be an @<item>@, whose children
-- become one @[POML]@ entry of the resulting 'List'.
listToPOML :: [PomlNode] -> Either String POML
listToPOML childNodes = List defaultListParams <$> traverse itemToPOMLs childNodes
  where
    itemToPOMLs (NodeElement "item" _ itemChildren) = traverse nodeToPOML itemChildren
    itemToPOMLs (NodeElement other _ _) =
        Left ("<list> may only contain <item> children, found <" <> T.unpack other <> ">")
    itemToPOMLs (NodeText _) =
        Left "<list> may not contain direct text; wrap it in <item>"

-- | Lower an @<examples>@ element: each child must be an @<example>@, whose
-- children become one @[POML]@ entry of the resulting 'ExampleSet'.
examplesToPOML :: [PomlNode] -> Either String POML
examplesToPOML childNodes =
    ExampleSet defaultExampleSetParams <$> traverse exampleItem childNodes
  where
    exampleItem (NodeElement "example" _ itemChildren) = traverse nodeToPOML itemChildren
    exampleItem (NodeElement other _ _) =
        Left ("<examples> may only contain <example> children, found <" <> T.unpack other <> ">")
    exampleItem (NodeText _) =
        Left "<examples> may not contain direct text; wrap it in <example>"

-- | Extract the mandatory static @caption@ attribute of a @<cp>@ element.
-- Template expressions (variables/concatenations) are rejected here because
-- @cpCaption :: Text@ cannot hold a runtime template — use the @makePoml@ TH
-- macro for templated captions.
cpCaptionStatic :: [(Text, Maybe TemplateExpr)] -> Either String Text
cpCaptionStatic attrs =
    case lookup "caption" attrs of
        Nothing -> Left "<cp> requires a 'caption' attribute"
        Just Nothing -> Left "<cp> 'caption' must not be empty"
        Just (Just (TLit t)) -> Right t
        Just (Just (TVar _)) ->
            Left "<cp> 'caption' uses a template expression; use the makePoml TH macro"
        Just (Just (TConcat _)) ->
            Left "<cp> 'caption' uses a template expression; use the makePoml TH macro"

-- | Extract a static integer level from the @level@ attribute, if it is a literal.
levelFromAttrs :: [(Text, Maybe TemplateExpr)] -> Maybe Int
levelFromAttrs attrs = attrLiteral "level" attrs >>= readMaybe . T.unpack

-- | Extract a static syntax from the @syntax@ attribute, if it is a literal.
syntaxFromAttrs :: [(Text, Maybe TemplateExpr)] -> Maybe Text
syntaxFromAttrs attrs = attrLiteral "syntax" attrs

-- | Look up an attribute by name and return its value when it is a static literal.
attrLiteral :: Text -> [(Text, Maybe TemplateExpr)] -> Maybe Text
attrLiteral attrName attrs =
    case join (lookup attrName attrs) of
        Just (TLit t) -> Just t
        _ -> Nothing
