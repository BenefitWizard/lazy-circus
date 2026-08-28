{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- The 'LazyCircus.AI.POML.Types' import is flagged as redundant because the
-- @makePoml@ splice uses fully-qualified 'Name's. We keep the import anyway to
-- honour the documented consumer-side contract of "LazyCircus.AI.POML.TH"
-- (its Haddock lists @POML(..)@ and @defaultListParams@ as required in scope).
{-# OPTIONS_GHC -Wno-unused-imports #-}

-- | Demonstration of the @makePoml@ Template Haskell macro, which reads
-- @.poml@ files at compile time and generates a record type plus a function
-- that builds a @[POML]@ list.
module Example.PomlDemo
    ( runPomlDemo
    , HelloInput (..)
    , ContactInput (..)
    , UntrustedInput (..)
    , hello
    , greeting
    , contact
    , untrusted
    ) where

import RIO
import Data.Text qualified as Text
import System.IO (putStrLn)

import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.TH (makePoml)
import LazyCircus.AI.POML.Types (POML (..), defaultListParams)

-- | Generates @HelloInput@ and @hello :: HelloInput -> [POML]@ from
-- @app/example/prompts/hello.poml@.
$(makePoml "hello" "app/example/prompts/hello.poml")

-- | Generates @greeting :: [POML]@ (no input record) from
-- @app/example/prompts/greeting.poml@.
$(makePoml "greeting" "app/example/prompts/greeting.poml")

-- | Generates @ContactInput@ and @contact :: ContactInput -> [POML]@ from
-- @app/example/prompts/contact.poml@.
$(makePoml "contact" "app/example/prompts/contact.poml")

-- | Generates @UntrustedInput@ and @untrusted :: UntrustedInput -> [POML]@ from
-- @app/example/prompts/untrusted.poml@.
$(makePoml "untrusted" "app/example/prompts/untrusted.poml")

-- | Render the four demo templates and print the resulting prompt text.
runPomlDemo :: IO ()
runPomlDemo = do
    putStrLn "\n=== POML Template Demo ==="
    putStrLn
        ( "hello:    "
            <> Text.unpack (renderPOMLtoPrompt (hello HelloInput{name = "World"}))
        )
    putStrLn
        ( "greeting: "
            <> Text.unpack (renderPOMLtoPrompt greeting)
        )
    putStrLn
        ( "contact:  "
            <> Text.unpack
                ( renderPOMLtoPrompt
                    (contact ContactInput{firstName = "Jane", lastName = "Doe"})
                )
        )
    putStrLn
        ( "untrusted:"
            <> Text.unpack
                ( renderPOMLtoPrompt
                    (untrusted UntrustedInput{resume = "Jane Doe, Haskell engineer"})
                )
        )
