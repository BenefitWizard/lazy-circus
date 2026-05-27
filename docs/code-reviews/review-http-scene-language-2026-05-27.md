# Code Review — HTTP Scene Language

**Date:** 2026-05-27
**Plan:** `docs/plans/2026-05-27-http-scene-language.md`
**Scope:** Files modified during plan execution.

---

## Review Summary

The HTTP effect language addition is **architecturally sound** and follows the existing Lazy Circus patterns (Mail, AI, Telegram) consistently across all layers: functor definition, performer class, runner, `Script` coproduct extension, smart constructor, environment wiring, and dispatch. The code compiles, the type-level integration is correct, and the `HasLogLang` / `handleLogLang` plumbing is properly threaded.

## Files Modified/Created

| File | Action | Purpose |
|------|--------|---------|
| `src/LazyCircus/Scene/HTTP/Lang.hs` | Created | `HTTPLangF` functor, `runClient` smart constructor, `HTTPScript` type alias |
| `src/LazyCircus/Scene/HTTP/Class.hs` | Created | `HTTPPerformer` class, `runHTTP` interpreter |
| `src/LazyCircus/Scene/HTTP.hs` | Created | Public facade with re-exports |
| `src/LazyCircus/Script.hs` | Modified | Added `HTTPScriptDef` constructor |
| `src/LazyCircus.hs` | Modified | Added `httpScript` smart constructor |
| `src/LazyCircus/App/Default.hs` | Modified | Added `httpManager` field and `HasHttpManager` typeclass |
| `src/LazyCircus/Performer/Default.hs` | Modified | Added `AppWithClientEnv`, `HTTPPerformer` instance, dispatch case |
| `src/LazyCircus/Testing/Performer.hs` | Modified | Added `HasHttpManager` for `EnvWithMocks`, test `HTTPPerformer`, dispatch case |

## Findings

### High

**[H1] Test HTTP performer makes real network calls — no mock capture**
- **Location:** `HTTPPerformer` instance in `Testing/Performer.hs` (lines 258–261)
- **Issue:** The test `HTTPPerformer` instance is identical to the production instance — it calls `runClientM` against a real `ClientEnv`, meaning tests using HTTP scripts will hit real external services. Every other mocked effect (Telegram, Mail, AI) captures side-effects for assertion.
- **Status:** **Accepted (MVP design choice).** The plan explicitly states: "В test-рантайме HTTP-запросы выполняются реально (как DB) — нет нужды в mocking для MVP". This is the same pattern as DB using real PostgreSQL.
- **Recommendation:** For post-MVP, consider adding an `HttpMock` to `Mocks` with request capture, or at minimum a safe stub that returns `Left` to prevent CI flakiness.

### Medium

**[M1] Missing `-- ^` field documentation on `AppWithClientEnv`**
- **Location:** `Performer/Default.hs` (lines 69–72)
- **Issue:** The record fields lack `-- ^` annotations per AGENTS.md conventions.
- **Status:** Deferred. Consistent with pre-existing `AppWithBotEnv` in `Telegram/Types.hs`.

**[M2] Test instance Haddock should document real-network behavior**
- **Location:** `Testing/Performer.hs` (line 257)
- **Issue:** The test `HTTPPerformer` instance comment reads "Executes servant-client actions against the real HTTP backend" — should explicitly call out that this is not mocked for the MVP.
- **Status:** Deferred.

### Low

**[L1] Missing `PURPOSE/SCOPE/DEPENDS` header block in new HTTP modules**
- **Location:** `Scene/HTTP/Lang.hs`, `Scene/HTTP/Class.hs`, `Scene/HTTP.hs`
- **Issue:** New modules use only `-- |` Haddock. The Mail pattern uses `--   PURPOSE:` / `--   SCOPE:` / `--   DEPENDS:` block comments.
- **Status:** Deferred.

**[L2] Facade import style — multiple separate imports from same module**
- **Location:** `Scene/HTTP.hs` (lines 18–24)
- **Issue:** Four separate import lines from `LazyCircus.Scene.HTTP.Lang`. This is identical to the Mail facade pattern (likely fourmolu output).
- **Status:** No change needed — consistent with existing formatter behavior.

## Review-Driven Fixes Summary

**Iterations:** 0/3 (the single High issue is an intentional MVP design choice per plan)
**Fixed:** N/A
**Remaining:** H1 (accepted for MVP)

---

## Verification Verdict

**Date:** 2026-05-27
**Verifier:** subtask-verifier (automated)

### Criteria Table

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | Can define servant API, generate client functions via `client`, execute inside `ScenarioProgram` via `evalScript $ httpScript baseUrl $ runClient myAction` | ✅ | `httpScript` defined in `LazyCircus.hs:46-47`, `runClient` in `Lang.hs:38-39`, dispatch in `evalScriptDefault` and `runScript`. 5 tests pass in `HTTPLangSpec`. |
| 2 | `runClient` returns `Either ClientError a`, mirroring `runClientM` | ✅ | `RunClient` constructor yields `Either ClientError b`, production uses `liftIO $ runClientM`. Test verifies `Left` on connection failure. |
| 3 | `slogInfo`/`slogWarn`/`slogError`/`slogSensitive`/`swithLogCtx` available inside `HTTPScript` | ✅ | `HasLogLang HTTPLangF HTTPScript` instance, facade re-exports all 5. Tests verify `slogInfo`, `slogWarn`, `swithLogCtx` with context propagation. |
| 4 | Production runtime uses shared `Manager` from `DefaultApp` | ✅ | `httpManager` field in `DefaultApp`, `HasHttpManager` class, `evalScriptDefault` constructs `mkClientEnv manager baseUrl`. |
| 5 | Test runtime executes real HTTP requests | ✅ | Test `HTTPPerformer` uses `liftIO $ runClientM act clientEnv`, `HasHttpManager` for `EnvWithMocks`. |
| 6 | Project compiles and existing tests pass | ✅ | `hpack && stack build` succeeds. 78 tests total (73 existing + 5 new), 1 pre-existing failure unrelated to HTTP. |

### Test Coverage

| Scenario | Test | Result |
|----------|------|--------|
| FR1: HTTPScript dispatch with runClient returning Left on connection error | `HTTPLangSpec` "dispatches HTTPScriptDef and returns Left on connection failure" | ✅ Pass |
| FR1: HTTPScript dispatch with logging-only script | `HTTPLangSpec` "dispatches HTTPScriptDef with logging-only script" | ✅ Pass |
| FR3: slogInfo inside HTTPScript with HTTP language tag | `HTTPLangSpec` "captures slogInfo messages with HTTP language tag" | ✅ Pass |
| FR3: slogWarn inside HTTPScript | `HTTPLangSpec` "captures slogWarn messages" | ✅ Pass |
| FR3: swithLogCtx context propagation | `HTTPLangSpec` "propagates logging context through swithLogCtx" | ✅ Pass |

### Overall Verdict: ✅ PASSED

All 6 acceptance criteria met. 5 automated tests cover dispatch, return type, and logging. The single High finding (test performer uses real network calls) is an intentional MVP design choice documented in the plan.
