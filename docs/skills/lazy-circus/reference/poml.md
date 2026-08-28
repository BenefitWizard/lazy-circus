# Lazy Circus Reference: Prompt Templates (POML)

Read this when:

- authoring or reviewing `.poml` prompt template files
- using `makePoml` (TH), `parsePoml` / `parsePomlText` (pure parser), or the `POML` AST
- composing templates (`fragment`, `type="poml"` slots, `<let src>` file constants)

## Contents

- Three Ways To Build A POML
- Hand-Built AST
- Pure Parser
- Compile-Time TH Macro
- Review Checklist

## Three Ways To Build A POML

The `prompt` and `systemPrompt` fields of `AIRequest` / `AgentRequest` (see [ai.md](ai.md))
are `[POML]` lists. A `POML` value is a node of the Prompt-Oriented Markup Language AST.
There are three ways to build one, in increasing order of type safety:

| Approach | Module | When to use |
|---|---|---|
| Hand-built AST + smart constructors | `LazyCircus.AI.POML.Types` | small, static, programmatic prompts |
| Pure parse of `.poml` text | `LazyCircus.AI.POML.Parser` (`parsePomlText`) | runtime/test construction from a template string |
| Compile-time TH macro | `LazyCircus.AI.POML.TH` (`makePoml`) | authored `.poml` files with template variables (preferred for real prompts) |

`renderPOMLtoPrompt :: [POML] -> Text` (from `LazyCircus.AI.POML`) flattens any `[POML]` into the
prompt text handed to the model. It is called internally by the AI interpreter; you normally do
not call it yourself.

## Hand-Built AST

The `POML` constructors group into:

- **Leaf / inline:** `Text`, `Var`, `Untrusted Text` (smart: `text`, `var`, `untrusted_`; `IsString` instance makes string literals coerce to `Text`)
- **Basic block / inline tags:** `Paragraph`, `Heading`, `Code`, `Strong`, `Italic`, `Underline`, `Strikethrough`, `Span`, `Br` (smart: `p_`, `h_`, `hLvl_`, `code_`, `b_`, `i_`, `u_`, `s_`, `span_`, `br`)
- **Semantic prompt blocks:** `CP`, `List`, `Role`, `Task`, `Example`, `ExampleSet`, `ExampleInput`, `ExampleOutput`, `Table` (smart: `cp_`/`cp`, `list_`/`list`, `role_`/`role`, `task_`/`task`, `example_`/`example`, `examples_`/`examples`, `exampleInput_`/`exampleInput`, `exampleOutput_`/`exampleOutput`, `csvTable_`/`csvTable`)
- **Composition:** `Fragment` (smart: `fragment :: [POML] -> POML`) — collapses a `[POML]` fragment into a single `POML` for splicing into a `type="poml"` slot of another template. Empty → `Text ""`, singleton → the node itself, otherwise `Fragment` (transparent under rendering). EDSL/composition-only; the parser never produces it.

Each semantic block takes a `*Params` record with a `default*Params` base (e.g. `defaultCPParams`, `defaultListParams`). The `_`-suffixed smart constructors use the defaults; the non-suffixed variants take explicit params.

```haskell
import LazyCircus.AI.POML.Types (POML, p_, cp_, text)

myPrompt :: [POML]
myPrompt =
    [ p_ ["Summarize the following:"]
    , cp_ "Input" [text someUserText]
    ]
```

## Pure Parser

`parsePomlText :: Text -> Either String [POML]` parses a `.poml` document (XML root `<poml>`,
whitelisted body tags) into a `[POML]` list — one entry per top-level body element. A document
may contain **one or more** top-level elements (e.g. a `<role>` and a `<task>` as siblings), so
the same template no longer needs to be wrapped in a single outer tag. Static text lowers to
`Text`; a bare `{{name}}` placeholder lowers to `Var "name"`. Template concatenations
(`{{a + " " + b}}`) and templated `<cp caption="{{...}}">` cannot be expressed in the AST and
return `Left` — use the TH macro for those.

```haskell
import LazyCircus.AI.POML.Parser (parsePomlText)

parsed :: Either String [POML]
parsed = parsePomlText "<poml><p>Hello</p></poml>"
```

## Compile-Time TH Macro

`makePoml :: String -> FilePath -> Q [Dec]` (from `LazyCircus.AI.POML.TH`) reads a `.poml` file at
compile time and generates:

- a record type `{Base}Input` (only when the document has `<let name="…" type="…"/>` **runtime-input** declarations), with one typed field per variable (`string` → `Text`, `boolean` → `Bool`, `number` → `Float`, `poml` → `POML`, `untrusted` → `Text`);
- a function `{base} :: {Base}Input -> [POML]` (or a nullary `{base} :: [POML]` when there are no runtime-input `<let>`s) whose body is a `[POML]` list — one element per top-level body node. A document may contain **one or more** top-level elements, each lowered to one list entry.

The `base` argument drives the generated names; the file is registered with `addDependentFile`
so edits trigger recompilation (a stale build means the splice did not re-run).

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell    #-}

import LazyCircus.AI.POML (renderPOMLtoPrompt)
import LazyCircus.AI.POML.TH (makePoml)
import LazyCircus.AI.POML.Types (POML (..), defaultListParams)  -- must stay in scope

-- prompts/hello.poml:
--   <poml>
--     <let name="name" type="string"/>
--     <p>Hello, {{name}}!</p>
--   </poml>
$(makePoml "hello" "prompts/hello.poml")
-- generates: data HelloInput = HelloInput { name :: Text }
--             hello :: HelloInput -> [POML]

greeting :: Text
greeting = renderPOMLtoPrompt (hello HelloInput{ name = "World" })
```

Concatenations (`{{firstName + " " + lastName}}`) and templated `<cp caption="{{topic}}">` are
only representable through the macro — they are spliced at the AST level inside the generated
function. A `poml`- or `untrusted`-typed variable may appear as a subtree / standalone placeholder
but cannot participate in a text concatenation (the splice fails with a clear message).

**Untrusted inputs (`type="untrusted"`).** Declare `<let name="resume" type="untrusted"/>` when a
runtime value is model-hostile data (user prose, pasted documents, tool output) that must never be
interpreted as prompt markup. A standalone `{{resume}}` placeholder splices an AST node that
renders inside a protective markdown fence:

- the fence is one backtick longer than the longest backtick run anywhere in the content, so no
  line of the value can close the block (parser-level protection);
- the opening fence's info-string carries a deterministic marker — the first 8 hex characters of
  SHA-256 of the content — so the model can tell where the untrusted region begins; forging that
  marker inside the content would require finding a SHA-256 fixed point;
- rendering stays pure and deterministic: identical content always yields identical output
  (expectations can be hardcoded in tests), and no signature changed.

For example, `"hello"` renders as `` ```2cf24dba\nhello\n``` ``. Use `untrusted_` (hand-built AST)
or `makePoml` with `type="untrusted"`; the pure `parsePomlText` path keeps lowering bare
placeholders to plain `Var` (isolation is applied by the splice/hand-built node, not by the
parser). Worked example: `app/example/prompts/untrusted.poml`.

**Composing one template into another.** A generated function returns `[POML]`, while a
`type="poml"` slot expects a single `POML`. Bridge them with `fragment`:

```haskell
import LazyCircus.AI.POML.Types (fragment)

-- outer.poml: <let name="body" type="poml"/> … {{body}} …
outer (OuterInput{ body = fragment (inner inp), subject = "..." })
```

`fragment` collapses the `[POML]` to one node (singleton → the node itself, multi-node →
`Fragment`), so it works regardless of how many top-level nodes `inner` produces.

**File constants (`<let src="..."/>`).** A `<let>` may instead name an external file to inline as
a **compile-time constant**:

```xml
<let name="schema" src="response-format.json"/>
```

The file is read at compile time (path relative to the `.poml`), registered with
`addDependentFile`, and its **entire contents are inlined verbatim** as a `Text` literal wherever
`{{name}}` appears — on its own (`Text "<file contents>"`), inside a concatenation, or in a `<cp
caption>`. There is **no JSON parsing and no attribute navigation**: the raw file text becomes the
prompt text, which is exactly what you want to embed an expected response-format schema.

A `src` variable is **not** a record field. Consequently a document whose `<let>`s are all `src`
constants generates a **nullary** function (no `{Base}Input` record):

```haskell
-- jsonFmt.poml: <let name="schema" src="response-format.json"/> … {{schema}} …
-- response-format.json is baked in at compile time; no input record is generated.
jsonFmt :: [POML]
```

Internally `LetDecl` is a sum type: `LetInput` (a `type`-declared runtime field) and `LetFile` (a
`src` constant). Specifying both `type` and `src`, or neither, is a parse error. `toPOML` /
`parsePomlText` treat `src` declarations as metadata (like `type` ones); the inlining happens only
in the `makePoml` TH macro.

Consumer requirements for `makePoml`: keep `POML(..)` and the referenced `default*Params` values
in scope, and enable `OverloadedStrings` (already a library default) — the generated splice
references these names directly. If two splices in the same module produce record types that
share a field name, also enable `DuplicateRecordFields`.

See `app/example/Example/PomlDemo.hs` and the `app/example/prompts/*.poml` templates
(`hello.poml`, `greeting.poml`, `contact.poml`, `caption.poml`, `multi.poml`, `untrusted.poml`)
for canonical worked examples. `multi.poml` demonstrates a document with multiple top-level body
elements
(`<role>` and `<task>` as siblings), lowered to a multi-element `[POML]` list. Template
composition is exercised by `outer.poml` / `inner.poml` / `innerMulti.poml`, and the `src` file
constants by `refer.poml` / `notice.poml` / `jsonFmt.poml` (with `refer-disclaimer.txt`
and `response-format.json`) — see `test/PomlTHSpec.hs`.

## Review Checklist

- Does the consumer module keep `POML(..)` + the referenced `default*Params` values in scope, with `OverloadedStrings` enabled?
- Does the generated `Input -> [POML]` function match the `<let>` declarations?
- If `<let src="..."/>` is used: is the referenced file present (relative to the `.poml`), registered for recompilation, and treated as a compile-time constant — not a record field?
- Are template concatenations / templated captions done via `makePoml` (not `parsePomlText`, which returns `Left` for them)?
- Are `type="untrusted"` variables used as standalone `{{var}}` placeholders only (never inside concatenations), with `POML(..)` kept in scope so the spliced `Untrusted` constructor resolves?
