# POML in Lazy Circus — Reference and Spec Comparison

This document describes how Lazy Circus's POML implementation (the `LazyCircus.AI.POML.*` modules) maps to the Prompt-Oriented Markup Language format. It is a reference for what is parsed, what is rendered, and where the implementation intentionally stops short of the full POML surface.

POML flows through three layers in this codebase:

1. **Parsing** — `LazyCircus.AI.POML.Parser` turns a `.poml` XML document into an intermediate `PomlDoc`, and (via `toPOML` / `nodeToPOML`) lowers it to the `POML` AST defined in `LazyCircus.AI.POML.Types`.
2. **The AST and eDSL** — `LazyCircus.AI.POML.Types` defines the `POML` algebraic data type plus smart constructors (`role_`, `cp_`, `p_`, `h_`, `var`, …) so POML trees can be built directly in Haskell.
3. **Rendering** — `LazyCircus.AI.POML` (`renderPOMLtoPrompt` / `renderPOMLTag`) turns a `[POML]` back into prompt text.

A compile-time Template Haskell macro, `makePoml` (`LazyCircus.AI.POML.TH`), bridges layers 1 and 2 by reading a `.poml` file and generating a Haskell record plus a function that builds a `POML` value.

---

## The parser (`LazyCircus.AI.POML.Parser`)

The parser **exists and is the entry point** for `.poml` source. It exposes three public lowering functions plus an intermediate document model:

| Name | Type | Purpose |
| --- | --- | --- |
| `parsePoml` | `Text -> Either String PomlDoc` | Parse XML text into the intermediate `PomlDoc` (decls + body nodes). |
| `parsePomlText` | `Text -> Either String [POML]` | Parse and lower in one step (`parsePoml` `>>=` `toPOML`). |
| `toPOML` | `PomlDoc -> Either String [POML]` | Lower a `PomlDoc` to a `[POML]` list — one entry per top-level body node. A document may contain one or more top-level elements. |

Internally, `nodeToPOML :: PomlNode -> Either String POML` does the per-node lowering, and `allowedElementNames :: Set Text` is the whitelist of legal body tag names shared with the TH code generator.

The format is XML with these top-level rules:

- The document root must be `<poml>`.
- `<let>` children of `<poml>` are **declarations**: they declare template variables consumed by `makePoml` codegen and are otherwise ignored by `toPOML`. There are two forms, selected by the attributes:
  - `<let name="…" type="…"/>` — a **runtime input field**. The four declared types are `string`, `boolean`, `number`, and `poml` (see `PomlType`: `PTString`, `PTBoolean`, `PTNumber`, `PTPoml`). It becomes a field of the generated `XInput` record.
  - `<let name="…" src="file"/>` — a **compile-time constant**. The entire contents of `file` (path relative to the `.poml`) are inlined verbatim as a `Text` literal by `makePoml`; it does **not** become a record field. See [File constants (`src`)](#file-constants-src).
  - Specifying both `type` and `src`, or neither, is a parse error.
- The body is made of whitelisted element tags (see [Supported tags](#supported-tags)).
- Template variables can be spliced into text via `{{name}}`, and multiple operands can be concatenated with `+`, e.g. `{{a + " " + b}}`. The placeholders are not special to the XML parser and may appear in text content or attribute values; any literal `<` or `&` inside text must still be XML-escaped by the author.

Illustrative lowering:

```
parsePomlText "<poml><role>Be kind</role></poml>"
  ⇨ Right [role_ ["Be kind"]]

parsePomlText "<poml><p>Hello, {{name}}!</p></poml>"
  ⇨ Right [p_ [text "Hello, ", var "name", text "!"]]

parsePomlText "<poml><role>R</role><task>T</task></poml>"
  ⇨ Right [role_ ["R"], task_ ["T"]]
```

---

## Supported tags

Tags split into two groups: structural/inline (formatting) and semantic (prompt-meaning). Both groups are reachable through all three layers — parse, eDSL smart constructor, and render.

### Structural / inline tags

| Tag | Attributes | AST constructor | Smart constructor(s) | Notes |
| --- | --- | --- | --- | --- |
| `p` | — | `Paragraph` | `p_` | Paragraph block. |
| `h` | `level` (optional) | `Heading (Maybe Int)` | `h_`, `hLvl_` | `h_` uses default level; `hLvl_ n` sets it explicitly. |
| `code` | `syntax` (optional) | `Code (Maybe Text)` | `code_` | Code block; `syntax` is round-tripped when present. |
| `b` | — | `Strong` | `b_` | Bold inline. |
| `i` | — | `Italic` | `i_` | Italic inline. |
| `u` | — | `Underline` | `u_` | Underline inline. |
| `s` | — | `Strikethrough` | `s_` | Strikethrough inline. |
| `span` | — | `Span` | `span_` | Generic inline span. |
| `br` | — | `Br` | `br` | Self-closing (`<br/>`); no children allowed. |
| `list` | — | `List ListParams [[POML]]` | `list_`, `list` | Container whose children must be `<item>`. |
| `item` | — | — | — | Only valid directly inside `<list>`; its children become one `[POML]` entry of the parent `List`. |

The nine single-node tags (`p`, `h`, `code`, `b`, `i`, `u`, `s`, `span`, `br`) plus the `list`/`item` container pair make up the structural surface enumerated in `allowedElementNames`.

### Semantic tags

| Tag | Attributes | AST constructor | Smart constructor(s) | Notes |
| --- | --- | --- | --- | --- |
| `role` | — | `Role RoleParams [POML]` | `role_`, `role` | Role/persona block. |
| `task` | — | `Task TaskParams [POML]` | `task_`, `task` | Task instruction block. |
| `cp` | `caption` (**required**) | `CP CPParams [POML]` | `cp_`, `cp` | Generic captioned block. `cp_ caption` builds default params from the caption. |
| `examples` | — | `ExampleSet ExampleSetParams [[POML]]` | `examples_`, `examples` | Grouped examples; each `<example>` child becomes one `[POML]` entry. |
| `example` | — | `Example ExampleParams [POML]` | `example_`, `example` | A standalone example (outside `<examples>`). See [nesting model](#examples-and-example-nesting-model). |
| `input` | — | `ExampleInput ExampleInputParams [POML]` | `exampleInput_`, `exampleInput` | Example input block. |
| `output` | — | `ExampleOutput ExampleOutputParams [POML]` | `exampleOutput_`, `exampleOutput` | Example output block. |

All seven semantic tags are supported end-to-end via parse, eDSL, and render.

---

## Rendering

`renderPOMLtoPrompt :: [POML] -> Text` concatenates the fragments produced by `renderPOMLTag :: POML -> [Text]` for each node. Block and inline nodes are emitted as a raw **open / content / close** XML triple by the helper `renderTag :: Text -> [(Text, Text)] -> [Text] -> [Text]`, giving a faithful XML round-trip of the AST:

| AST constructor | Rendered output |
| --- | --- |
| `Role` | `<role>…</role>` |
| `Task` | `<task>…</task>` |
| `CP` | `<cp caption="…">…</cp>` |
| `ExampleInput` | `<input>…</input>` |
| `ExampleOutput` | `<output>…</output>` |
| `ExampleSet` | `<examples>…</examples>` (each child rendered as `<example>…</example>`) |
| `Paragraph` | `<p>…</p>` |
| `Heading` | `<h level="n">…</h>` (`level` defaults to `"1"`) |
| `Code` | `<code>…</code>`, or `<code syntax="…">…</code>` when a syntax is set |
| `Strong` / `Italic` / `Underline` / `Strikethrough` / `Span` | `<b>` / `<i>` / `<u>` / `<s>` / `<span>` |
| `List` | `<list>…</list>` with each item rendered as `<item>…</item>` |
| `Br` | `<br/>` (self-closing; emitted directly, no close tag) |
| `Text t` | raw `t` |
| `Var n` | `{{n}}` |
| `Fragment` | transparent — the concatenation of its children (no wrapper tag) |

The emitted tag names are the **standardized** ones above. Note in particular that `ExampleInput` renders as `<input>` and `ExampleOutput` renders as `<output>` — **not** `<example_input>` / `<example_output>`.

### Params styling is intentionally ignored

Each block constructor carries a `*Params` record (`CPParams`, `RoleParams`, `TaskParams`, `ExampleInputParams`, `ExampleOutputParams`, `ExampleSetParams`, `ListParams`) full of styling knobs — `CaptionStyle`, `CaptionTextTransform`, `CaptionEnding`, `Speaker`, the various `*Syntax` / `*BlankLine` / `*ClassName` fields, and so on.

The current renderer **intentionally does not consult these styling fields**. It only reads what is needed to round-trip the tag:

- For `CP`, only `cpCaption` is read (it becomes the `caption` attribute); every other `CPParams` field is ignored.
- For `Role`, `Task`, `ExampleInput`, `ExampleOutput`, `ExampleSet`, and `List`, the params record is matched with a wildcard (`*Params{}`) and **no** field is read.

The `*Params` shapes exist on the AST for future use; they do not affect the rendered output at this stage. (The `Code` and `Table` constructors carry their own syntax information — `Maybe Text` and `TableParams`/`Table` respectively — which *is* emitted; that is separate from the ignored `*Params` styling fields.)

---

## Templates and variables

`{{...}}` template placeholders are parsed into `TemplateExpr` (`TVar`, `TLit`, `TConcat`) and behave differently depending on where they appear and which lowering path you take.

### In text content

| Form | Static path (`parsePomlText`) | TH path (`makePoml`) |
| --- | --- | --- |
| Bare variable `{{name}}` | Lowers to `Var name`; renderer emits `{{name}}`. | The variable is read from the input record field and spliced into the generated `POML`. |
| Concatenation `{{a + " " + b}}` | **Returns `Left`** — the `POML` AST cannot represent concatenations. | Supported. The operands are combined at runtime via `(<>)`; each operand is coerced to `Text` (see below). |

The static `nodeToPOML` rule is: a text run of exactly one literal (`[TLit t]`) becomes `Text t`; exactly one variable (`[TVar n]`) becomes `Var n`; anything else (including concatenations) returns `Left` with the message that the `makePoml` TH macro is required.

### In the `caption` attribute of `<cp>`

- A **static literal** caption works in `parsePomlText` — it is carried as `TLit` and reaches `cpCaption`.
- A **templated** caption such as `caption="{{topic}}"` returns `Left` in the static path; it requires `makePoml`.

Through `makePoml`, the caption template is evaluated against the input record fields with the following coercion (mirrored by `genNodeText` / `genConcatPart` in `TH.hs`):

| Declared `<let>` type | Coercion to `Text` (for the caption) |
| --- | --- |
| `string` | the field value itself |
| `boolean` | `bool "false" "true" field` (i.e. `"true"` / `"false"`) |
| `number` | `tshow field` |
| `poml` | **error** — a `poml`-typed value is not `Text` and cannot be spliced into a caption |

### Control-flow constructs

`for` (loops), `if` (conditionals), and `include` (partial inclusion) are **not supported**. There is no parsing, AST node, or codegen for them. The only template constructs are variable references and `+` concatenation.

### Composing templates: `fragment`

`makePoml` generates a function returning `[POML]` (one entry per top-level body node), while a `type="poml"` slot on another template expects a single `POML`. The bridge is `fragment :: [POML] -> POML` (from `LazyCircus.AI.POML.Types`):

```haskell
fragment []  = Text ""        -- renders to nothing
fragment [x] = x              -- singleton collapses to the node itself
fragment xs  = Fragment xs    -- two or more → transparent group
```

`Fragment` is **eDSL/composition-only** — the parser never produces it. It renders as the concatenation of its children with no wrapper tag, so it is observationally transparent at any nesting level:

```haskell
renderPOMLtoPrompt [fragment xs] == renderPOMLtoPrompt xs
```

Typical use — feed one template's `[POML]` output into another template's `type="poml"` slot:

```haskell
-- outer.poml declares <let name="body" type="poml"/> and references {{body}}
outer (OuterInput{ body = fragment (inner inp), subject = "..." })
```

This works regardless of how many top-level nodes `inner` produces. The single-node case collapses (no `Fragment` wrapper); the multi-node case wraps in one `Fragment`.

### File constants (`src`)

`<let name="…" src="file"/>` inlines an external file as a **compile-time constant**. Unlike a `type="…"` declaration (a runtime input field), a `src` variable's value is fixed at compile time: `makePoml` reads the file — its path relative to the `.poml` file — inlines its **entire contents verbatim** (no JSON parsing, no trimming, no attribute navigation), and bakes the result into the generated code as a `Text` literal. The file is registered with `addDependentFile`, so editing it recompiles the splice.

A `src` variable is **not** a record field. Wherever `{{name}}` appears, the inlined `Text` is substituted directly:

- on its own as a whole text node → `Text "<file contents>"`;
- inside a concatenation, e.g. `{{who + ": " + note}}` → `Text (who <> ": " <> "<file contents>")`;
- in a `<cp caption="{{name}}">` → the caption becomes the literal `Text`.

Because a `src` constant is always `Text`-valued, it may freely participate in concatenations (it is never `poml`-typed). A document whose **only** `<let>` is a `src` constant therefore generates a **nullary** function (no `XInput` record):

```xml
<poml>
  <let name="disclaimer" src="disclaimer.txt"/>
  <p>Read this: {{disclaimer}}</p>
</poml>
```

```haskell
-- disclaimer.txt contents are inlined; no record is generated
renderPOMLtoPrompt disclaimer == "<p>Read this: <…disclaimer.txt…></p>"
```

```haskell
-- a src constant composed with a string runtime input
makePoml "refer" "app/example/prompts/refer.poml"
-- refer :: ReferInput -> [POML]   — ReferInput{ user :: Text } (only the string field; 'notice' is a constant)
refer (ReferInput{user = "Alice"})
```

Specifying both `type` and `src`, or neither, is a parse error. `toPOML`/`parsePomlText` treat `src` declarations as metadata (like `type` ones); the inlining happens only in the `makePoml` TH macro.

---

## The `makePoml` Template Haskell macro

`makePoml :: String -> FilePath -> Q [Dec]` (in `LazyCircus.AI.POML.TH`) reads and parses a `.poml` file at compile time and emits Haskell declarations. A splice like

```haskell
makePoml "contact" "app/example/prompts/contact.poml"
```

against a file declaring `<let name="firstName" type="string"/>` and `<let name="lastName" type="string"/>` produces:

- a record type `ContactInput` with one field per `type`-declared `<let>` (field types follow `pomlTypeToHsType`: `string`→`Text`, `boolean`→`Bool`, `number`→`Float`, `poml`→`POML`), deriving `Eq` and `Show`. `<let src="…"/>` constants are **excluded** — they are inlined as `Text` literals, not record fields;
- a function `contact :: ContactInput -> [POML]` whose body is the lowered `[POML]` list (one entry per top-level body node), with declared variables validated and spliced from the record.

When the document has **no** `type`-declared `<let>` (i.e. no runtime inputs — either no `<let>` at all, or only `src` constants), no record is generated and the function is nullary: `base :: [POML]`.

The macro performs the following compile-time validation (failing the splice on any error):

- every `<let>` name is a legal, non-reserved lowercase Haskell identifier (`validateLetName`, `isValidHsIdent`);
- the body has at least one top-level node (`requireNonEmptyBody`); a document may contain one or more top-level elements;
- every `{{name}}` reference has a matching `<let>` declaration (`validateVarRefs`);
- no `poml`-typed variable appears inside a concatenation, since its `POML` value cannot be appended to `Text` (`validateNoPomlInConcat`). (`src` constants are `Text`-valued and are never restricted here.)
- every `<let src="…"/>` file is readable (resolved relative to the `.poml`); the path is also registered with `addDependentFile` (`resolveSrcLets`).

The source file is registered with `addDependentFile`, so editing the `.poml` triggers a recompile of any module that splices it; each `src`-referenced file is registered the same way.

### Consumer-side imports

The generated splice references several names directly, so a module that calls `makePoml` must keep them in scope (documented in the `TH.hs` module header):

- `POML` and its constructors from `LazyCircus.AI.POML.Types` (`Paragraph`, `Heading`, `Code`, `Strong`, `Italic`, `Underline`, `Strikethrough`, `Span`, `Br`, `Text`, `List`, …) plus `defaultListParams`;
- `Text` (the type) and `bool`, `tshow` from the RIO prelude;
- `OverloadedStrings` must be enabled so the string literals the splice emits coerce to `Text`;
- if two `makePoml` calls in the same module produce records sharing a field name, enable `DuplicateRecordFields`.

---

## `<examples>` and `<example>` nesting model

`<example>` is handled **contextually**, like `<item>` inside `<list>`:

- **Inside `<examples>`**: each `<example>` child is folded into one `[POML]` entry of the surrounding `ExampleSet` (whose AST shape is `ExampleSet ExampleSetParams [[POML]]`, mirroring `List`). The renderer then emits the set as `<examples>` containing one `<example>…</example>` per entry.
- **Standalone** (a `<example>` directly in the body, not wrapped in `<examples>`): it becomes an `Example` AST node.

Both forms render to `<example>…</example>`; the difference is purely whether the node lives inside a grouped `<examples>` container or stands on its own.

---

## Limitations and out-of-scope behavior

- **Params styling is ignored by the renderer.** As noted under [Rendering](#rendering), the `*Params` styling fields (`CaptionStyle`, `CaptionEnding`, `Speaker`, the `*Syntax`/`*BlankLine`/`*ClassName`/… fields) are present on the AST for future use but do not affect rendered output at this stage.
- **Only `caption` on `<cp>` is honored.** Attributes other than `caption` on semantic block tags are silently ignored by the parser — the default `*Params` (e.g. `defaultCPParams`, `defaultRoleParams`) are used. This includes styling attributes like `captionStyle`, `ending`, `speaker`, `blankLine`, etc.
- **No free-text mode.** A `.poml` body must use the whitelisted structural/semantic tags. Free-form text outside the tag set is not supported as a rendering mode; body elements must come from `allowedElementNames` plus the semantic tags.
- **Tables are out of scope for `parsePomlText`.** The `Table TableParams T.Table` constructor uses an existential row type (see `LazyCircus.AI.POML.Table`) so that rows of different record types can share a renderer. This cannot be produced by the static parser; tables are only constructible via the `csvTable` / `csvTable_` smart constructors in Haskell. (The renderer does handle `Table` via `renderTable` and `syntaxFromTable`.)
- **Concatenations and templated captions require `makePoml`.** The static `parsePomlText` path returns `Left` for `{{a + b}}` concatenations and for templated `<cp>` captions; both are only representable through the TH macro.
- **No control flow.** `for`, `if`, and `include` are not implemented in any layer.
