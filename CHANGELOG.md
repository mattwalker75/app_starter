# Changelog

All notable changes to App Starter (Keep a Changelog style; dates are when the change was made).

## [0.1.0] — unreleased

### Added
- 2026-10-16: **The engine** (`AppStarterCore`, no UI): application bundles of ordered steps, each step one
  app or a sub-bundle whose apps start and stop together; the next step waits until every app in the one
  before is up (or down). Start and stop commands run as you in your login shell, several lines allowed, in an
  optional working folder, with the app's environment variables; each command gets its own process group and
  writes to the app's log. An app either starts itself in the background or is kept running by App Starter
  (stopped by App Starter when it has no stop command, and found again after App Starter reopens). Health
  checks: none, return code, output text (contains, optionally ignoring capitals) or a URL (any answer counts,
  any certificate). A failed step pauses with Retry / Skip / Stop what started. Stopping goes in the reverse
  order, or a custom one. Secret variables are encrypted on disk (AES-GCM, key file readable by you only),
  never in bundles.json, hidden in logs. Export/import of the bundles. 22 tests.
