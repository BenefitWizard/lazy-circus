# Code Review — Agent Loop Bot

**Date:** 2026-05-13
**Plan:** `docs/plans/2026-05-13-agent-loop-bot.md`
**Scope:** Files modified during plan execution.

---

## Summary

The `NoServiceLib` → `AllServices` migration and agent loop wiring is **architecturally sound**. The `DemoEnv` correctly creates service workers, sets both `toolDescriptionsL` and `toolCallExecL` on the app, and manages the lifecycle with `bracket`. The `askAgent` scenario correctly uses `aiScriptWithAll` + `solveWithAgent` at the scene layer and stays properly polymorphic over `serviceLib`. The `BotApp` Idle routing handles all three outcomes (exception, no result, success). No critical issues were found.

## Issues Found

### High

#### [Agent system prompt lacks few-shot examples] — `circusAgentSystemPrompt` in `common/BotScenarios.hs`

**Problem:** The agent prompt provided zero examples and relied on prose instructions for JSON output format. Because `solveWithAgentLoop` does not set `response_format = JSON_Object` (intentionally, to allow tool-call rounds), the model's final response could deviate from expected JSON format, causing `decodeContent` to return `Nothing`.

**Fix applied:** Added two example input/output pairs using the `examples_` / `exampleInput_` / `exampleOutput_` POML combinators. Changed rule from prose `"Output format: {...}"` to `"Always output ONLY valid JSON as your final response — no markdown, no explanation."`

### Medium

#### [`agentMaxIterations` hardcoded] — `askAgent` in `common/BotScenarios.hs`

**Problem:** `agentMaxIterations = 10` was embedded directly in the function body.

**Fix applied:** Extracted as a named constant `defaultAgentMaxIterations :: Natural`.

### Low

#### [1. Duplicate import in `DemoEnv.hs`]

**Problem:** `LazyCircus.Script (Script)` was imported twice; `LazyCircus.Scenario` was imported from two separate lines.

**Fix applied:** Merged into single import lines.

#### [2. Incomplete Haddock on `AgentResponse`]

**Problem:** `AgentResponse` lacked field documentation and JSON key contract description.

**Fix applied:** Enriched Haddock with contract note and field `-- ^` annotation.

## What's Done Well

1. **Layer discipline** — `askAgent` delegates to the scene layer via `evalScript $ aiScriptWithAll $ solveWithAgent req`. No scene-level logic leaks into the scenario layer.
2. **Polymorphic design preserved** — `askAgent` stays polymorphic over `serviceLib`, like all existing scenarios.
3. **Tool wiring is complete** — `DemoEnv` sets both `toolDescriptionsL` and `toolCallExecL`. `aiScript` (no tools) and `aiScriptWithAll` (all tools) coexist in the same app.
4. **Worker lifecycle** — `bracket` manages creation and cleanup of all worker threads.
5. **Error handling at the right level** — `BotApp` catches at the boundary with `CE.try @SomeException`, maps all failure modes to user-facing messages.

## Files Modified

| File | Change |
|------|--------|
| `common/DemoEnv.hs` | `NoServiceLib` → `AllServices` wiring, `mkAllServices`, worker lifecycle, lens setup |
| `common/BotScenarios.hs` | New `askAgent`, `AgentResponse`, `circusAgentSystemPrompt`, `defaultAgentMaxIterations` |
| `common/BotApp.hs` | Idle → agent loop routing, `askAgent` import, error handling |
| `test/AIAgentSpec.hs` | Type signature cascade: `NoServiceLib` → `AllServices` |
| `test/BotScenariosSpec.hs` | Type signature cascade: `NoServiceLib` → `AllServices` |
| `test/LogSpec.hs` | Type signature cascade: `NoServiceLib` → `AllServices` |
| `app/example/Example.hs` | Type signature cascade: `NoServiceLib` → `AllServices` |

---

## Review-Driven Fixes Summary

**Iterations:** 1/3
**Fixed:**
- High: Added few-shot examples to `circusAgentSystemPrompt`
- Medium: Extracted `defaultAgentMaxIterations` constant
- Low: Removed duplicate import in `DemoEnv.hs`
- Low: Enriched `AgentResponse` Haddock

**Remaining:** None

---

## Verification Verdict

**Status: PASSED** (after test additions)

### Acceptance Criteria Evaluation

| Criterion | Status | Notes |
|-----------|--------|-------|
| T1: `withDemoApp` compiles with `DefaultApp AllServices` | ✅ | Signature confirmed at line 166 |
| T1: `appToolDescriptions` contains 3 tools | ✅ | `toolDescriptionsL .~ allToolDescriptions` sets 3 TH-generated tools |
| T1: `toolCallExec` does not fail | ✅ | `toolCallExecL .~ mkToolCallExec allServices` replaces stub |
| T2: `askAgent` compiles, exported, type correct | ✅ | Polymorphic `ScenarioProgram Script serviceLib (Maybe Text)` |
| T2: System prompt describes tools and requires JSON | ✅ | With 2 few-shot examples added in review fix |
| T3: `BotApp` compiles with `AllServices` | ✅ | All type applications updated |
| T3: Idle → `askAgent` routing works | ✅ | Lines 162-174: sends "Thinking...", calls `askAgent`, handles 3 outcomes |
| T3: Existing commands preserved | ✅ | 8 BotAppSpec tests pass: `/start`, `/newact`, `/list`, `/act`, `/react`, `/delete`, arbitrary text |
| T4: `hpack && stack build` succeeds | ✅ | Clean build with no errors |
| T4: `stack test` passes | ✅ | ToolSchema 7/7, BotApp 8/8, Log unit 4/4 pass. DB tests fail due to no PostgreSQL server (pre-existing) |

### Test Coverage Added

| Test | File | Description |
|------|------|-------------|
| `askAgent` returns Nothing in test env | `test/BotScenariosSpec.hs` | Verifies `solveWithAgent'` default returns Nothing |
| `askAgent` logs "Agent: processing query" | `test/BotScenariosSpec.hs` | Log message verification |
| `askAgent` logs warning on no response | `test/BotScenariosSpec.hs` | Warning path verification |
| `askAgent` adds query to log context | `test/BotScenariosSpec.hs` | `withLogContext` context capture |
| 8 BotApp routing tests | `test/BotAppSpec.hs` | All command routes + arbitrary text routing |

### Additional Changes for Tests

| File | Change |
|------|--------|
| `common/BotApp.hs` | Added `handleUpdate` to exports, derived `Show`/`Eq` for `Action` |
| `package.yaml` | Added `telegram-bot-api` to test dependencies |
| `test/BotScenariosSpec.hs` | Added `askAgent` to imports, added 4 `askAgent` test cases |
| `test/BotAppSpec.hs` | New file: 8 pure routing tests for `handleUpdate` |
