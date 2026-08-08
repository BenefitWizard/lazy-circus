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

## 0.1.0.0 - YYYY-MM-DD
