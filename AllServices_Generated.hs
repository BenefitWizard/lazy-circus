data AllServices
  = AllServices {simpleRequestService :: (LazyCircus.App.Service.ServiceHandler SimpleRequest SimpleResponse),
                 addExpressionRequestService :: (LazyCircus.App.Service.ServiceHandler AddExpressionRequest AddExpressionResponse)}
data AllServicesConfig m
  = AllServicesConfig {simpleRequest :: (SimpleRequest
                                         -> m SimpleResponse),
                       addExpressionRequest :: (AddExpressionRequest
                                                -> m AddExpressionResponse)}
data AllServicesTool
  = AddTool | SubtractTool | AddExpressionRequestTool
  deriving (Show, Read, Eq, Ord, Enum, Bounded)
toolSchema :: AllServicesTool -> Maybe Value
toolSchema AddTool = Nothing
toolSchema SubtractTool = Nothing
toolSchema AddExpressionRequestTool = Nothing
toolInfo ::
  AllServicesTool -> LazyCircus.App.Service.ToolDescription
toolInfo AddTool
  = LazyCircus.App.Service.ToolDescription
      "add_numbers" "Add two numbers together" (toolSchema AddTool)
toolInfo SubtractTool
  = LazyCircus.App.Service.ToolDescription
      "subtract_numbers" "Subtract two numbers" (toolSchema SubtractTool)
toolInfo AddExpressionRequestTool
  = LazyCircus.App.Service.ToolDescription
      "add_expression" "Add an expression"
      (toolSchema AddExpressionRequestTool)
allToolDescriptions :: [LazyCircus.App.Service.ToolDescription]
allToolDescriptions = map toolInfo [minBound .. maxBound]
instance LazyCircus.App.Service.IsInServiceLib AllServices SimpleRequest SimpleResponse where
  LazyCircus.App.Service.callFromServiceLib
    = \ x
        -> LazyCircus.App.Service.callService (simpleRequestService x)
instance LazyCircus.App.Service.IsInServiceLib AllServices AddExpressionRequest AddExpressionResponse where
  LazyCircus.App.Service.callFromServiceLib
    = \ x
        -> LazyCircus.App.Service.callService
             (addExpressionRequestService x)
mkAllServices ::
  forall m_aYml. (MonadUnliftIO m_aYml,
                  LazyCircus.App.Service.HasFailbackValue SimpleResponse,
                  FromJSON SimpleRequest,
                  ToJSON SimpleResponse,
                  LazyCircus.App.Service.HasFailbackValue AddExpressionResponse,
                  FromJSON AddExpressionRequest,
                  ToJSON AddExpressionResponse) =>
                 AllServicesConfig m_aYml -> m_aYml (AllServices, [m_aYml ()])
mkAllServices config
  = do (h0_aYmm, w0_aYmn) <- LazyCircus.App.Service.createService
                               (simpleRequest config)
       (h1_aYmo, w1_aYmp) <- LazyCircus.App.Service.createService
                               (addExpressionRequest config)
       pure (AllServices h0 h1, [w0, w1])
data AllServicesToolCall
  = SimpleRequestToolCall Text SimpleRequest |
    AddExpressionRequestToolCall Text AddExpressionRequest
  deriving (Show, Eq)
data AllServicesToolResponse
  = SimpleResponseToolResponse SimpleResponse |
    AddExpressionResponseToolResponse AddExpressionResponse
  deriving (Show, Eq)
instance FromJSON AllServicesToolCall where
  parseJSON
    = sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON.withObject
        "AllServicesToolCall"
        (\ o
           -> do name <- (sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON..:)
                           o "tool_name"
                 case name of
                   "add_numbers"
                     -> (<$>)
                          (SimpleRequestToolCall name)
                          ((sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON..:) o "arguments")
                   "subtract_numbers"
                     -> (<$>)
                          (SimpleRequestToolCall name)
                          ((sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON..:) o "arguments")
                   "add_expression"
                     -> (<$>)
                          (AddExpressionRequestToolCall name)
                          ((sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON..:) o "arguments")
                   _ -> fail
                          (text-2.1.2-b3a1:Data.Text.Show.unpack
                             ((<>) "Unknown tool: " name)))
executeToolCall ::
  forall m. MonadUnliftIO m =>
            AllServices -> AllServicesToolCall -> m AllServicesToolResponse
executeToolCall sl (SimpleRequestToolCall _ req_aYmq)
  = (<$>)
      SimpleResponseToolResponse
      (LazyCircus.App.Service.callService
         (simpleRequestService sl) req_aYmq)
executeToolCall sl (AddExpressionRequestToolCall _ req_aYmr)
  = (<$>)
      AddExpressionResponseToolResponse
      (LazyCircus.App.Service.callService
         (addExpressionRequestService sl) req_aYmr)
toolCallName :: AllServicesToolCall -> Text
toolCallName (SimpleRequestToolCall name_aYms _) = name_aYms
toolCallName (AddExpressionRequestToolCall name_aYmt _) = name_aYmt
encodeToolResponse :: Text -> AllServicesToolResponse -> Value
encodeToolResponse name_aYmu (SimpleResponseToolResponse resp_aYmv)
  = sn-2.2.3.0-be54e5ea:Data.Aeson.Types.Internal.object
      [(sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
         "tool_name" name_aYmu,
       (sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
         "result" (toJSON resp_aYmv)]
encodeToolResponse
  name_aYmu
  (AddExpressionResponseToolResponse resp_aYmw)
  = sn-2.2.3.0-be54e5ea:Data.Aeson.Types.Internal.object
      [(sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
         "tool_name" name_aYmu,
       (sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
         "result" (toJSON resp_aYmw)]
mkToolCallExec ::
  AllServices -> LazyCircus.App.Service.ToolCallExec
mkToolCallExec sl
  = LazyCircus.App.Service.ToolCallExec
      (\ toolName argsValue
         -> do let dispatchJson
                     = sn-2.2.3.0-be54e5ea:Data.Aeson.Types.Internal.object
                         [(sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
                            "tool_name" toolName,
                          (sn-2.2.3.0-be54e5ea:Data.Aeson.Types.ToJSON..=)
                            "arguments" argsValue]
               case
                   sn-2.2.3.0-be54e5ea:Data.Aeson.Types.FromJSON.fromJSON dispatchJson
               of
                 sn-2.2.3.0-be54e5ea:Data.Aeson.Types.Internal.Success tc
                   -> do resp <- executeToolCall sl tc
                         pure (encodeToolResponse (toolCallName tc) resp)
                 sn-2.2.3.0-be54e5ea:Data.Aeson.Types.Internal.Error err
                   -> fail err)
aiScriptWithAll ::
  LazyCircus.Scene.AI.Lang.AIScript b -> LazyCircus.Script.Script b
aiScriptWithAll = LazyCircus.Script.AIScriptDef allToolDescriptions
aiScriptWith ::
  [AllServicesTool]
  -> LazyCircus.Scene.AI.Lang.AIScript b
     -> LazyCircus.Script.Script b
aiScriptWith tools
  = LazyCircus.Script.AIScriptDef (map toolInfo tools)
