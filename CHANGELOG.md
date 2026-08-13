# Changelog for `lazy-circus`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## Unreleased

### Added
- `runArbitraryIO :: IO a -> ScenarioProgram script serviceLib a`: escape-hatch
  scenario operation that runs an arbitrary `IO` action. Documented as a
  last-resort fallback when no structured effect (DB, Telegram, AI, Mail, HTTP,
  or a registered service) fits. Runs for real in both production and test
  interpreters — it cannot be mocked.
- POML: a `.poml` body may now contain **one or more** top-level elements (e.g.
  `<role>` and `<task>` as siblings). Each top-level element is lowered to one
  entry of the resulting `[POML]` list, so a real prompt no longer needs to be
  wrapped in a single outer tag.
- POML: new `Fragment [POML]` AST node and `fragment :: [POML] -> POML` smart
  constructor (`LazyCircus.AI.POML.Types`). `fragment` collapses a `[POML]`
  fragment into a single `POML` for splicing into a `type="poml"` slot of
  another template: empty → `Text ""`, singleton → the node itself, otherwise
  `Fragment`. It is observationally transparent —
  `renderPOMLtoPrompt [fragment xs] == renderPOMLtoPrompt xs`. The parser never
  produces `Fragment`; it is eDSL/composition-only.
- POML: `<let name="..." src="file"/>` now inlines an external file's entire
  contents verbatim as a **compile-time constant** (no JSON parsing, no
  attribute navigation). `LetDecl` is now a sum type: `LetInput` (a `type`-declared
  runtime field, as before) and `LetFile` (a `src` constant). In `makePoml`:
  the file is read relative to the `.poml` and registered with
  `addDependentFile`; a `src` variable is **not** a record field (it is baked
  into the generated code as a `Text` literal), so a document whose only `<let>`
  is a `src` yields a nullary function. Specifying both `type` and `src` (or
  neither) is a parse error.

### Changed
- **(Breaking)** POML public API now returns `[POML]` instead of a single
  `POML`:
  - `parsePomlText` / `toPOML` (`LazyCircus.AI.POML.Parser`) now return
    `Either String [POML]`.
  - `makePoml` (`LazyCircus.AI.POML.TH`) now generates `<base> :: <Base>Input -> [POML]`
    (and a nullary `<base> :: [POML]` when there are no `<let>` declarations).
  Consumers should migrate call sites like `renderPOMLtoPrompt [hello x]` to
  `renderPOMLtoPrompt (hello x)` (the generated function already returns a list).
  An empty `.poml` body is still rejected (`Left` / compile-time `fail`).

## 0.1.0.0 - YYYY-MM-DD
