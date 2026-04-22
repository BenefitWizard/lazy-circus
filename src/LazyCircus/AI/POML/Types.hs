module LazyCircus.AI.POML.Types where

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
    | Role RoleParams [POML]
    | Task TaskParams [POML]
    | Table TableParams T.Table
    | Var Text

-- | Allow string literals to become plain text POML leaf nodes.
instance IsString POML where
    fromString = Text . fromString

-- | Wrap plain text as a POML leaf node.
text :: Text -> POML
text = Text

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
