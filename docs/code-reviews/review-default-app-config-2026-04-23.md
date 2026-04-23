# Code Review — DefaultAppConfig and newDefaultApp

**Date:** 2026-04-23
**Plan:** `docs/plans/2026-04-23-default-app-config.md`
**Scope:** Files modified during plan execution.

---

## Reviewer Findings

### Summary

The `DefaultAppConfig` / `newDefaultApp` design is clean and well-documented — it correctly replaces a hand-assembled `App{…}` with a parameterized config record and a smart constructor that hides IO plumbing. The type design is honest about what's raw vs. derived.

### Critical (Fixed)

1. **DB connections leaked in `newDefaultApp` on partial failure** — If `connectPostgreSQL` succeeds but a later step throws, connections were never closed. **Fixed**: Added `onException` cleanup to close connections on partial failure.

2. **DB connections never closed in `withDemoApp` even on success** — The bracket release action only cancelled threads but never closed `pgDbConnection` or `pgDbConnectionReadOnly`. **Fixed**: Added `close` calls to the bracket release action.

### High (Fixed)

3. **`MailCreds` derives `Show`, leaking SMTP password** — `deriving Show` printed `mailPassword` in full. **Fixed**: Replaced with manual `Show` instance that masks the password with `***`.

4. **Dummy AI client silently targets `example.com`** — When `cfgAiApiKey` is `Nothing`, AI calls hit an unrelated host, producing confusing errors. **Fixed**: Changed fallback URL to `http://127.0.0.1:1` (immediate connection refused) and updated Haddock to warn about runtime failures.

### Medium (Not fixed — deferred)

5. **`unsafeCoerce` pattern in `LogSpec` is fragile** — Nine fields use `unsafeCoerce ()` to construct a dummy `DefaultApp`. Pre-existing pattern; no change made.

6. **Import hiding creates fragile coupling in `DemoEnv.hs`** — The `hiding (cfgAiApiKey, cfgAiBaseUrl, DefaultAppConfig)` clause could silently become incomplete. The qualified import `LAD` is the right direction; full migration deferred.

### Low (Fixed)

7. **Missing Haddock on `HasServiceLib` instance** — Added.
8. **`putStrLn` import lacks clarifying comment** — Added comment about String-based usage.
9. **`MailCreds` field `-- ^` annotations on wrong line** — Converted to inline format per project convention.

---

## Review-Driven Fixes Summary

**Iterations:** 1/3
**Fixed:**
- Critical: Connection leak in `newDefaultApp` (onException cleanup)
- Critical: Connection leak in `withDemoApp` (bracket release closes connections)
- High: `MailCreds` password exposure (manual Show instance)
- High: Dummy AI URL targeting example.com (changed to 127.0.0.1:1)
- Low: Missing Haddock on HasServiceLib instance
- Low: Missing comment on putStrLn import
- Low: MailCreds field annotation format

**Remaining:**
- Medium: `unsafeCoerce` pattern in LogSpec (pre-existing, deferred)
- Medium: Import hiding coupling in DemoEnv (architectural, deferred)

---

## Files Modified

| File | Changes |
|------|---------|
| `package.yaml` | Added `jose` to library dependencies |
| `src/LazyCircus/App/Default.hs` | Added explicit export list, `DefaultAppConfig` data type, `newDefaultApp` smart constructor with `onException` cleanup, manual `Show MailCreds` instance, inline field docs, AI fallback URL fix |
| `common/DemoEnv.hs` | Removed `createDemoAppWithConn`, added `demoConfigToAppConfig`, changed `setupDatabase` to `IO ()`, rewrote `withDemoApp` with connection cleanup, cleaned up imports |
| `test/BotScenariosSpec.hs` | Fixed `DefaultApp` type to `DefaultApp NoServiceLib`, added `NoServiceLib` import |
| `test/LogSpec.hs` | Added missing `serviceLib` field to dummy App construction |

---

## Verification Verdict

**Overall: PASSED**

### Criteria Table

| Criterion | Status | Comment |
|-----------|--------|---------|
| C1: `DefaultAppConfig serviceLib` defined with all raw fields | ✅ | 9-field parameterized record with all raw configuration values |
| C2: `newDefaultApp` performs all IO actions | ✅ | connectPostgreSQL, newTlsManager, makeBotEnv, genJWK, newTQueueIO, mkDefaultProcessContext, getClientEnv/makeMethods — all present. Includes onException cleanup. |
| C3: `DemoEnv.hs` refactored to use config + smart constructor | ✅ | `createDemoAppWithConn` removed, `demoConfigToAppConfig` added, `withDemoApp` uses `newDefaultApp` |
| C4: `hpack && stack build && stack test` pass | ✅ | 33 tests, 0 failures |
| T1: Module exports `DefaultAppConfig(..)` and `newDefaultApp` | ✅ | Explicit export list includes both |
| T2: DemoEnv compiles, BotScenariosSpec/LogSpec pass | ✅ | Pre-existing type bugs fixed; test logic unchanged |
| T3: Build and tests pass | ✅ | Library, common-circus, bot, all tests green |

### Summary

All plan acceptance criteria are fully met. The `DefaultAppConfig` type and `newDefaultApp` smart constructor provide a clean, safe entry point for library consumers to create fully initialized applications from raw configuration values. Review-driven fixes addressed 2 Critical resource leak issues and 2 High security/robustness issues, going beyond the plan's original scope to improve production readiness.
