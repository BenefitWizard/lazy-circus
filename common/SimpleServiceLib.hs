{-# LANGUAGE TemplateHaskell #-}

{- | TH-generated service library assembly.

Separated from 'SimpleService' to avoid constructor name clashes between
request types and the generated tool enum. Imports only type-level names
(no data constructors) so the TH-generated enum constructors ('Add', 'Subtract',
'AddExpressionRequest') don't clash with request-type constructors of the same name.
Constructor 'Name's are created via 'mkName' for validation without bringing them into scope.
-}
module SimpleServiceLib where

import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import LazyCircus.App.Service.TH (makeServiceLib)
import RIO

-- Import only type names and instances — NO constructors.
-- This prevents TH-generated enum constructors from clashing with request constructors.
import SimpleService (
    AddExpressionRequest (..),
    AddExpressionResponse (..),
    SimpleRequest (..),
    SimpleResponse (..),
 )

{- | Generate the AllServices service library with non-empty tool specs.
Tool specs exercise the full TH code generation path:
enum type, ToolCall\/ToolResponse, FromJSON dispatch, executeToolCall,
toolCallName, encodeToolResponse, and smart constructors.
-}
makeServiceLib
    "AllServices"
    [
        ( ''SimpleRequest
        , ''SimpleResponse
        ,
            [ ('Add, "add_numbers", "Add two numbers together")
            , ('Subtract, "subtract_numbers", "Subtract two numbers")
            ]
        )
    ,
        ( ''AddExpressionRequest
        , ''AddExpressionResponse
        ,
            [ ('AddExpressionRequest, "add_expression", "Add an expression")
            ]
        )
    ]
