# Code Review — ServiceLib TemplateHaskell Generation

**Date:** 2026-04-24
**Plan:** `docs/plans/2026-04-24-servicelib-th.md`
**Scope:** Files modified during plan execution.

---

## Reviewer Output

### Summary

The `makeServiceLib` TH macro is well-structured and generates correct boilerplate — the types,
instances, and builder function all compose properly. The implementation successfully replaces
manual service library boilerplate with a single TH splice, reducing ~40 lines of repetitive code
to a 3-line macro call.

### Issues Found

#### Critical (Pre-existing — NOT from our changes)

- **Missing `callService'` implementation in `Performer.hs`** — The `ScenarioPerformer Script serviceLib m`
  orphan instance does not implement `callService'`, which would crash at runtime if `run` from
  `Scenario.hs` were called. This is a pre-existing issue; our changes do not touch `Performer.hs`.

#### High — Fixed During Review

1. **`runAllWorkers` discarded `Async` handles (FIXED)** — Originally returned `m ()` via
   `mapM_ (void . async)`. Changed to return `m [Async ()]` via `mapM async`, enabling graceful
   shutdown. Updated `ServiceCallSpec.hs` to explicitly discard handles.

2. **Misleading PRE-CONTRACT on `runAllWorkers` (FIXED)** — Originally stated "Worker list is
   non-empty" but the function was total. Updated contract to "None".

#### Medium — Acknowledged, Not Fixed

1. **TH-generated types derive nothing** — `AllServices` and `AllServicesConfig` don't derive
   `Show`. Low impact; `AllServicesConfig` can't derive `Show` due to function fields.

2. **Missing Haddock on `SimpleService.hs` types** — Request/response types lack documentation.
   Pre-existing; not introduced by this change.

3. **Empty pairs validation (FIXED)** — Added `when (null rawPairs) $ fail "..."` to `makeServiceLib`.

#### Low

- No test for `HasFailbackValue` fallback behavior (handler throwing → fallback value returned).
- `typeToFieldName` doesn't handle multi-uppercase-initial names like `XMLParser` → `xMLParser`.
  Matches current convention; acceptable.

---

## Review-Driven Fixes Summary

**Iterations:** 1/3
**Fixed:**
- `runAllWorkers` now returns `[Async ()]` instead of discarding handles
- Misleading PRE-CONTRACT removed
- Empty pairs validation added to `makeServiceLib`

**Remaining (pre-existing / acknowledged):**
- Missing `callService'` in `Performer.hs` (pre-existing, not from our changes)
- Variable shadowing in `worker` function (pre-existing)
- No `Show` derivation on generated types (low impact)
- Missing Haddock on SimpleService types (pre-existing)

---

## Verification Verdict

**VERDICT: PASSED** — All 8 verification criteria met.

| Criterion | Status |
|-----------|--------|
| `makeServiceLib` generates `AllServices` type | ✅ |
| Generates `AllServicesConfig m` config type | ✅ |
| Generates `IsInServiceLib` instances for each pair | ✅ |
| Generates `mkAllServices` builder function | ✅ |
| `ServiceCallSpec` passes through generated code (5/5 tests) | ✅ |
| Field names follow convention (`simpleRequest` / `simpleRequestService`) | ✅ |
| `runAllWorkers` exists and is exported | ✅ |
| Documentation updated with TH section | ✅ |

**Build:** `hpack && stack build` — SUCCESS
**Tests:** `stack test` — 38 examples, 0 failures
**Review-driven fixes:** 1 iteration, 3 issues fixed (runAllWorkers return type, contract, empty pairs validation)
