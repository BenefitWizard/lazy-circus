{-# LANGUAGE DuplicateRecordFields #-}

module LazyCircus.AI.POML.Types
    ( POML(..)
      -- * Smart constructors
      -- ** Captioned blocks, lists, examples, roles, tasks
    , text
    , json
    , cp_
    , cp
    , list_
    , list
    , exampleInput_
    , exampleInput
    , exampleOutput_
    , exampleOutput
    , examples_
    , examples
    , example_
    , example
    , role_
    , role
    , task_
    , task
    , csvTable_
    , csvTable
    , var
    , untrusted_
      -- ** Basic inline / block tags
    , p_
    , h_
    , hLvl_
    , code_
    , b_
    , i_
    , u_
    , s_
    , span_
    , br
      -- ** Composition
    , fragment
      -- * Parameter types and defaults
    , CPParams(..)
    , defaultCPParams
    , CaptionStyle(..)
    , CaptionTextTransform(..)
    , CaptionEnding(..)
    , ContentSyntax(..)
    , Speaker(..)
    , ListParams(..)
    , defaultListParams
    , ListStyle(..)
    , ExampleOutputParams(..)
    , defaultExampleOutputParams
    , ExampleInputParams(..)
    , defaultExampleInputParams
    , ExampleSetParams(..)
    , defaultExampleSetParams
    , RoleParams(..)
    , defaultRoleParams
    , TaskParams(..)
    , defaultTaskParams
    , ExampleParams(..)
    , defaultExampleParams
    , ColumnDef(..)
    , ParserType(..)
    , TableSyntax(..)
    , TableParams(..)
    , defaultTableParams
    ) where

import Data.Aeson (ToJSON)
import Data.Aeson.Text (encodeToLazyText)

-- import Data.Text.Lazy (toStrict)
import LazyCircus.AI.POML.Table qualified as T
import RIO
import RIO.Text.Lazy (toStrict)

-- | Abstract syntax tree for prompt-oriented markup language fragments.
data POML
    = Text Text
    | CP CPParams [POML]
    | List ListParams [[POML]]
    | ExampleInput ExampleInputParams [POML]
    | ExampleOutput ExampleOutputParams [POML]
    | ExampleSet ExampleSetParams [[POML]]
    -- | Standalone example block (@<example>@ outside @<examples>@).
    | Example ExampleParams [POML]
    | Role RoleParams [POML]
    | Task TaskParams [POML]
    | Table TableParams T.Table
    | Var Text
    -- | Untrusted payload (input @type=\"untrusted\"@); rendered inside a protective fence with a hash marker.
    | Untrusted Text
    -- | Paragraph block (@<p>@).
    | Paragraph [POML]
    -- | Heading block (@<h level="n">@); the 'Maybe' 'Int' is the optional
    -- level ('Nothing' = default).
    | Heading (Maybe Int) [POML]
    -- | Code block (@<code syntax="…">@); the 'Maybe' 'Text' is the optional
    -- syntax.
    | Code (Maybe Text) [POML]
    -- | Strong (bold) inline node (@<b>@).
    | Strong [POML]
    -- | Italic inline node (@<i>@).
    | Italic [POML]
    -- | Underline inline node (@<u>@).
    | Underline [POML]
    -- | Strikethrough inline node (@<s>@).
    | Strikethrough [POML]
    -- | Generic inline span (@<span>@).
    | Span [POML]
    -- | Line break (@<br\/>@).
    | Br
    -- | Transparent group of nodes — rendered as the concatenation of its
    -- children with no wrapper tag. Only arises from the 'fragment' smart
    -- constructor (for two or more nodes); the parser never produces it.
    | Fragment [POML]

-- | Structural equality for POML nodes.
-- 'Table' is compared by parameters and the rendered CSV text produced by
-- 'T.renderTable' (the existential row payload cannot be compared directly).
-- Two tables with different row types but identical rendered CSV text are
-- considered equal — acceptable for test assertions.
instance Eq POML where
    Text a == Text b = a == b
    CP pa ca == CP pb cb = pa == pb && ca == cb
    List pa ia == List pb ib = pa == pb && ia == ib
    ExampleInput pa ca == ExampleInput pb cb = pa == pb && ca == cb
    ExampleOutput pa ca == ExampleOutput pb cb = pa == pb && ca == cb
    ExampleSet pa ia == ExampleSet pb ib = pa == pb && ia == ib
    Example pa ca == Example pb cb = pa == pb && ca == cb
    Role pa ca == Role pb cb = pa == pb && ca == cb
    Task pa ca == Task pb cb = pa == pb && ca == cb
    Table pa ta == Table pb tb = pa == pb && T.renderTable ta == T.renderTable tb
    Var a == Var b = a == b
    Untrusted a == Untrusted b = a == b
    Paragraph ca == Paragraph cb = ca == cb
    Heading la ca == Heading lb cb = la == lb && ca == cb
    Code sa ca == Code sb cb = sa == sb && ca == cb
    Strong ca == Strong cb = ca == cb
    Italic ca == Italic cb = ca == cb
    Underline ca == Underline cb = ca == cb
    Strikethrough ca == Strikethrough cb = ca == cb
    Span ca == Span cb = ca == cb
    Br == Br = True
    Fragment ca == Fragment cb = ca == cb
    _ == _ = False

-- | Readable representation of POML nodes.
-- 'Table' is shown via 'T.renderTable' (its existential row payload has no
-- 'Show' instance); every other constructor is shown structurally. Must not
-- crash on any constructor.
instance Show POML where
    show (Text t) = "Text " <> show t
    show (CP ps cs) = "CP " <> show ps <> " " <> show cs
    show (List ps items) = "List " <> show ps <> " " <> show items
    show (ExampleInput ps cs) = "ExampleInput " <> show ps <> " " <> show cs
    show (ExampleOutput ps cs) = "ExampleOutput " <> show ps <> " " <> show cs
    show (ExampleSet ps items) = "ExampleSet " <> show ps <> " " <> show items
    show (Example ps cs) = "Example " <> show ps <> " " <> show cs
    show (Role ps cs) = "Role " <> show ps <> " " <> show cs
    show (Task ps cs) = "Task " <> show ps <> " " <> show cs
    show (Table ps t) = "Table " <> show ps <> " (rendered: " <> show (T.renderTable t) <> ")"
    show (Var x) = "Var " <> show x
    show (Untrusted t) = "Untrusted " <> show t
    show (Paragraph cs) = "Paragraph " <> show cs
    show (Heading lvl cs) = "Heading " <> show lvl <> " " <> show cs
    show (Code syn cs) = "Code " <> show syn <> " " <> show cs
    show (Strong cs) = "Strong " <> show cs
    show (Italic cs) = "Italic " <> show cs
    show (Underline cs) = "Underline " <> show cs
    show (Strikethrough cs) = "Strikethrough " <> show cs
    show (Span cs) = "Span " <> show cs
    show Br = "Br"
    show (Fragment cs) = "Fragment " <> show cs

-- | Allow string literals to become plain text POML leaf nodes.
instance IsString POML where
    fromString = Text . fromString

-- | Wrap plain text as a POML leaf node.
text :: Text -> POML
text = Text

-- | Insert an untrusted payload node (rendered inside a protective fence).
untrusted_ :: Text -> POML
untrusted_ = Untrusted

-- | Encode a JSON value as a plain text POML leaf.
json :: (ToJSON a) => a -> POML
json = Text . toStrict . encodeToLazyText

-- | Build a generic captioned block using default parameters for the supplied caption.
cp_ :: Text -> [POML] -> POML
cp_ caption = CP (defaultCPParams caption)

-- | Build a generic captioned block with explicit parameters.
cp :: CPParams -> [POML] -> POML
cp = CP

-- | Build a list block with default list parameters.
list_ :: [[POML]] -> POML
list_ = List defaultListParams

-- | Build a list block with explicit list parameters.
list :: ListParams -> [[POML]] -> POML
list = List

-- | Build an example-input block with default input parameters.
exampleInput_ :: [POML] -> POML
exampleInput_ = ExampleInput defaultExampleInputParams

-- | Build an example-input block with explicit input parameters.
exampleInput :: ExampleInputParams -> [POML] -> POML
exampleInput = ExampleInput

-- | Build an example-output block with default output parameters.
exampleOutput_ :: [POML] -> POML
exampleOutput_ = ExampleOutput defaultExampleOutputParams

-- | Build an example-output block with explicit output parameters.
exampleOutput :: ExampleOutputParams -> [POML] -> POML
exampleOutput = ExampleOutput

-- | Build an example-set block with default example-set parameters.
examples_ :: [[POML]] -> POML
examples_ = ExampleSet defaultExampleSetParams

-- | Build an example-set block with explicit example-set parameters.
examples :: ExampleSetParams -> [[POML]] -> POML
examples = ExampleSet

-- | Build a standalone example block with default example parameters.
example_ :: [POML] -> POML
example_ = Example defaultExampleParams

-- | Build a standalone example block with explicit example parameters.
example :: ExampleParams -> [POML] -> POML
example = Example

-- | Build a role block with default role parameters.
role_ :: [POML] -> POML
role_ = Role defaultRoleParams

-- | Build a role block with explicit role parameters.
role :: RoleParams -> [POML] -> POML
role = Role

-- | Build a task block with default task parameters.
task_ :: [POML] -> POML
task_ = Task defaultTaskParams

-- | Build a task block with explicit task parameters.
task :: TaskParams -> [POML] -> POML
task = Task

-- | Build a CSV-backed table block with default table parameters.
csvTable_ :: (T.CSVTableConstraint a) => [a] -> POML
csvTable_ = Table defaultTableParams . T.CSV

-- | Build a CSV-backed table block with explicit table parameters.
csvTable :: (T.CSVTableConstraint a) => TableParams -> [a] -> POML
csvTable params = Table params . T.CSV

-- | Insert a template variable placeholder node.
var :: Text -> POML
var = Var

-- | Build a paragraph (@<p>@) block.
p_ :: [POML] -> POML
p_ = Paragraph

-- | Build a heading (@<h>@) block with the default level.
h_ :: [POML] -> POML
h_ = Heading Nothing

-- | Build a heading (@<h>@) block with an explicit level.
hLvl_ :: Int -> [POML] -> POML
hLvl_ lvl = Heading (Just lvl)

-- | Build a code (@<code>@) block with no explicit syntax.
code_ :: [POML] -> POML
code_ = Code Nothing

-- | Build a strong (bold, @<b>@) inline node.
b_ :: [POML] -> POML
b_ = Strong

-- | Build an italic (@<i>@) inline node.
i_ :: [POML] -> POML
i_ = Italic

-- | Build an underline (@<u>@) inline node.
u_ :: [POML] -> POML
u_ = Underline

-- | Build a strikethrough (@<s>@) inline node.
s_ :: [POML] -> POML
s_ = Strikethrough

-- | Build a generic inline span (@<span>@) node.
span_ :: [POML] -> POML
span_ = Span

-- | A standalone line-break (@<br\/>@) node.
br :: POML
br = Br

-- | Collapse a list of POML nodes into a single node for splicing into a
-- @type="poml"@ slot: the empty list becomes 'Text' "" (renders to nothing),
-- a singleton collapses to the node itself, and two or more nodes become a
-- 'Fragment'. Observationally transparent at any nesting level:
--
-- > renderPOMLtoPrompt [fragment xs] == renderPOMLtoPrompt xs
fragment :: [POML] -> POML
fragment [] = Text ""
fragment [x] = x
fragment xs = Fragment xs

-- params

-- | Display style for serialized prompt captions.
data CaptionStyle = Header | Bold | Plain | Hidden
    deriving (Eq, Show)

-- | Text transform applied to serialized prompt captions.
data CaptionTextTransform = Upper | Level | Capitalize | NoTransform
    deriving (Eq, Show)

-- | Suffix appended after a serialized caption.
data CaptionEnding = Colon | Newline | ColonNewline | EndingNone
    deriving (Eq, Show)

-- | Supported content syntaxes for prompt blocks.
data ContentSyntax = Markdown | HTML | JSON | YAML | XML | PlainText | CSV | TSV
    deriving (Eq, Show)

-- | Logical speaker associated with a prompt block.
data Speaker = Human | AI | System
    deriving (Eq, Show)

-- | Serialization parameters for a generic captioned prompt block.
data CPParams = CPParams
    { cpSyntax :: ContentSyntax
    , cpCaption :: Text
    , cpCaptionSerialized :: Maybe Text
    , cpCaptionStyle :: Maybe CaptionStyle
    , cpCaptionTextTransform :: Maybe CaptionTextTransform
    , cpCaptionEnding :: Maybe CaptionEnding
    , cpBlankLine :: Maybe Bool
    , cpClassName :: Maybe Text
    , cpSpeaker :: Maybe Speaker
    , cpName :: Maybe Text
    , cpType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Construct default captioned-paragraph parameters for the supplied caption.
defaultCPParams :: Text -> CPParams
defaultCPParams cpCaption =
    CPParams
        { cpSyntax = PlainText
        , cpCaption = cpCaption
        , cpCaptionSerialized = Nothing
        , cpCaptionStyle = Nothing
        , cpCaptionTextTransform = Nothing
        , cpCaptionEnding = Nothing
        , cpBlankLine = Nothing
        , cpClassName = Nothing
        , cpSpeaker = Nothing
        , cpName = Nothing
        , cpType = Nothing
        }

-- | Bullet style used when serializing list blocks.
data ListStyle = Star | Dash | Plus | Decimal | Latin
    deriving (Eq, Show)

-- | Serialization parameters for list prompt blocks.
data ListParams = ListParams
    { listSyntax :: ContentSyntax
    , listStyle :: ListStyle
    , listBlankLine :: Maybe Bool
    , listClassName :: Maybe Text
    , listSpeaker :: Maybe Speaker
    , listName :: Maybe Text
    , listType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default list serialization parameters.
defaultListParams :: ListParams
defaultListParams =
    ListParams
        { listSyntax = PlainText
        , listStyle = Dash
        , listBlankLine = Nothing
        , listClassName = Nothing
        , listSpeaker = Nothing
        , listName = Nothing
        , listType = Nothing
        }

-- | Serialization parameters for example-output blocks.
data ExampleOutputParams = ExampleOutputParams
    { exampleOutputSyntax :: ContentSyntax
    , exampleOutputCaption :: Text
    , exampleOutputCaptionSerialized :: Maybe Text
    , exampleOutputCaptionStyle :: Maybe CaptionStyle
    , exampleOutputCaptionTextTransform :: Maybe CaptionTextTransform
    , exampleOutputCaptionEnding :: Maybe CaptionEnding
    , exampleOutputBlankLine :: Maybe Bool
    , exampleOutputClassName :: Maybe Text
    , exampleOutputSpeaker :: Maybe Speaker
    , exampleOutputName :: Maybe Text
    , exampleOutputType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Serialization parameters for example-input blocks.
data ExampleInputParams = ExampleInputParams
    { exampleInputSyntax :: ContentSyntax
    , exampleInputCaption :: Text
    , exampleInputCaptionSerialized :: Maybe Text
    , exampleInputCaptionStyle :: Maybe CaptionStyle
    , exampleInputCaptionTextTransform :: Maybe CaptionTextTransform
    , exampleInputCaptionEnding :: Maybe CaptionEnding
    , exampleInputBlankLine :: Maybe Bool
    , exampleInputClassName :: Maybe Text
    , exampleInputSpeaker :: Maybe Speaker
    , exampleInputName :: Maybe Text
    , exampleInputType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default example-input serialization parameters.
defaultExampleInputParams :: ExampleInputParams
defaultExampleInputParams =
    ExampleInputParams
        { exampleInputSyntax = PlainText
        , exampleInputCaption = "Input"
        , exampleInputCaptionSerialized = Just "input"
        , exampleInputCaptionStyle = Nothing
        , exampleInputCaptionTextTransform = Just NoTransform
        , exampleInputCaptionEnding = Nothing
        , exampleInputBlankLine = Nothing
        , exampleInputClassName = Nothing
        , exampleInputSpeaker = Nothing
        , exampleInputName = Nothing
        , exampleInputType = Nothing
        }

-- | Default example-output serialization parameters.
defaultExampleOutputParams :: ExampleOutputParams
defaultExampleOutputParams =
    ExampleOutputParams
        { exampleOutputSyntax = PlainText
        , exampleOutputCaption = "Output"
        , exampleOutputCaptionSerialized = Just "output"
        , exampleOutputCaptionStyle = Nothing
        , exampleOutputCaptionTextTransform = Just NoTransform
        , exampleOutputCaptionEnding = Nothing
        , exampleOutputBlankLine = Nothing
        , exampleOutputClassName = Nothing
        , exampleOutputSpeaker = Nothing
        , exampleOutputName = Nothing
        , exampleOutputType = Nothing
        }

-- | Serialization parameters for grouped example blocks.
data ExampleSetParams = ExampleSetParams
    { exampleSyntax :: ContentSyntax
    , exampleCaption :: Text
    , exampleCaptionSerialized :: Maybe Text
    , exampleChat :: Maybe Bool
    , exampleIntroducer :: Maybe Text
    , exampleCaptionStyle :: Maybe CaptionStyle
    , exampleCaptionTextTransform :: Maybe CaptionTextTransform
    , exampleCaptionEnding :: Maybe CaptionEnding
    , exampleBlankLine :: Maybe Bool
    , exampleClassName :: Maybe Text
    , exampleSpeaker :: Maybe Speaker
    , exampleName :: Maybe Text
    , exampleType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default grouped-example serialization parameters.
defaultExampleSetParams :: ExampleSetParams
defaultExampleSetParams =
    ExampleSetParams
        { exampleSyntax = PlainText
        , exampleCaption = "Examples"
        , exampleCaptionSerialized = Nothing
        , exampleChat = Nothing
        , exampleIntroducer = Nothing
        , exampleCaptionStyle = Just Header
        , exampleCaptionTextTransform = Just NoTransform
        , exampleCaptionEnding = Nothing
        , exampleBlankLine = Nothing
        , exampleClassName = Nothing
        , exampleSpeaker = Nothing
        , exampleName = Nothing
        , exampleType = Nothing
        }

-- | Serialization parameters for role blocks.
data RoleParams = RoleParams
    { roleSyntax :: ContentSyntax
    , roleCaption :: Text
    , roleCaptionSerialized :: Maybe Text
    , roleCaptionStyle :: Maybe CaptionStyle
    , roleCaptionTextTransform :: Maybe CaptionTextTransform
    , roleCaptionEnding :: Maybe CaptionEnding
    , roleBlankLine :: Maybe Bool
    , roleClassName :: Maybe Text
    , roleSpeaker :: Maybe Speaker
    , roleName :: Maybe Text
    , roleType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default role serialization parameters.
defaultRoleParams :: RoleParams
defaultRoleParams =
    RoleParams
        { roleSyntax = PlainText
        , roleCaption = "Role"
        , roleCaptionSerialized = Nothing
        , roleCaptionStyle = Nothing
        , roleCaptionTextTransform = Nothing
        , roleCaptionEnding = Nothing
        , roleBlankLine = Nothing
        , roleClassName = Nothing
        , roleSpeaker = Nothing
        , roleName = Nothing
        , roleType = Nothing
        }

-- | Serialization parameters for task blocks.
data TaskParams = TaskParams
    { taskSyntax :: ContentSyntax
    , taskCaption :: Text
    , taskCaptionSerialized :: Maybe Text
    , taskCaptionStyle :: Maybe CaptionStyle
    , taskCaptionTextTransform :: Maybe CaptionTextTransform
    , taskCaptionEnding :: Maybe CaptionEnding
    , taskBlankLine :: Maybe Bool
    , taskClassName :: Maybe Text
    , taskSpeaker :: Maybe Speaker
    , taskName :: Maybe Text
    , taskType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default task serialization parameters.
defaultTaskParams :: TaskParams
defaultTaskParams =
    TaskParams
        { taskSyntax = PlainText
        , taskCaption = "Task"
        , taskCaptionSerialized = Nothing
        , taskCaptionStyle = Just Header
        , taskCaptionTextTransform = Just NoTransform
        , taskCaptionEnding = Nothing
        , taskBlankLine = Nothing
        , taskClassName = Nothing
        , taskSpeaker = Nothing
        , taskName = Nothing
        , taskType = Nothing
        }

-- | Serialization parameters for a standalone example block (@<example>@).
data ExampleParams = ExampleParams
    { exampleSyntax :: ContentSyntax
    , exampleCaption :: Text
    , exampleCaptionSerialized :: Maybe Text
    , exampleCaptionStyle :: Maybe CaptionStyle
    , exampleCaptionTextTransform :: Maybe CaptionTextTransform
    , exampleCaptionEnding :: Maybe CaptionEnding
    , exampleBlankLine :: Maybe Bool
    , exampleClassName :: Maybe Text
    , exampleSpeaker :: Maybe Speaker
    , exampleName :: Maybe Text
    , exampleType :: Maybe Text
    }
    deriving (Eq, Show)

-- | Default standalone-example serialization parameters.
-- Per the Microsoft spec, an example's default 'exampleCaptionStyle' is 'Hidden'.
defaultExampleParams :: ExampleParams
defaultExampleParams =
    ExampleParams
        { exampleSyntax = PlainText
        , exampleCaption = "Example"
        , exampleCaptionSerialized = Just "example"
        , exampleCaptionStyle = Just Hidden
        , exampleCaptionTextTransform = Nothing
        , exampleCaptionEnding = Nothing
        , exampleBlankLine = Nothing
        , exampleClassName = Nothing
        , exampleSpeaker = Nothing
        , exampleName = Nothing
        , exampleType = Nothing
        }

-- | Column selection and labeling metadata for rendered tables.
data ColumnDef = ColumnDef
    { colField :: Text
    , colHeader :: Maybe Text
    , colDescription :: Maybe Text
    }
    deriving (Eq, Show)

-- | Parser choice for reading external table sources.
data ParserType = ParserAuto | ParserCSV | ParserTSV | ParserExcel | ParserJSON | ParserJSONL
    deriving (Eq, Show)

-- | Output syntax used when serializing table blocks.
data TableSyntax = TableMarkdown | TableHTML | TableJSON | TableText | TableCSV | TableTSV | TableXML
    deriving (Eq, Show)

-- | Serialization and selection parameters for POML table blocks.
data TableParams = TableParams
    { tableSyntax :: TableSyntax
    , tableColumns :: Maybe [ColumnDef]
    , tableSrc :: Maybe Text
    , tableParser :: Maybe ParserType
    , tableSelectedColumns :: Maybe (Either [Text] Text)
    , tableSelectedRecords :: Maybe (Either [Int] Text)
    , tableMaxRecords :: Maybe Int
    , tableMaxColumns :: Maybe Int
    , tableClassName :: Maybe Text
    , tableSpeaker :: Maybe Speaker
    }
    deriving (Eq, Show)

-- | Default table serialization parameters for CSV rendering.
defaultTableParams :: TableParams
defaultTableParams =
    TableParams
        { tableSyntax = TableCSV
        , tableColumns = Nothing
        , tableSrc = Nothing
        , tableParser = Nothing
        , tableSelectedColumns = Nothing
        , tableSelectedRecords = Nothing
        , tableMaxRecords = Nothing
        , tableMaxColumns = Nothing
        , tableClassName = Nothing
        , tableSpeaker = Nothing
        }
