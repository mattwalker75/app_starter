# Changelog

All notable changes to App Starter (Keep a Changelog style; dates are when the change was made).

## [0.1.0] — unreleased

### Added
- 2026-10-16: **The app** — Matt's picks from the mockups: layout **A · Sidebar + step list** and the
  **Power stack** icon.
  - **Main window:** bundles down the left with their lights (green all up, red all down, yellow some of
    each) or a spinner while busy; the selected bundle's numbered steps top to bottom, a sub-bundle as one
    card with its apps side by side; Edit, **Start bundle** / **Start the rest**, **Stop bundle** (asks
    first, naming the apps); Add application, Add sub-bundle, Check now. Right-click an app: start or stop
    just that one, Show log, Edit, Delete; the step menu moves, renames, starts or stops a sub-bundle.
  - **Application editor:** name, where it goes (own step, a sub-bundle, a new sub-bundle), working folder
    (Choose…), how it runs, **multi-line Start and Stop boxes** (Matt: an app may need a second command),
    environment variables with a Secret tick-box, the health check (None / Return code / Output text / URL)
    with its wait and **Test check**.
  - **Bundle editor:** name, start at login, stop at logout, the stop order (reverse, or your own), delete.
  - **Progress sheet:** each step with its apps; on a failure the end of the app's log with **Retry**,
    **Skip it and go on**, **Stop what started**; Hide — keep it going; Cancel.
  - **Menu bar item** by the clock: every bundle with its light and Start / Start the rest / Stop / Show,
    Open App Starter, Settings…, Close App Starter (your apps keep running).
  - **Settings:** open at login, show in the menu bar, how often to check; bundles at login and logout;
    Appearance (Data Syncer's themes); log size; Backup (export, with or without secret values; import,
    replacing or copying bundles already there).
  - Login: start-at-login bundles run once per login session; stop-at-logout bundles stop before logout,
    restart or shutdown.
  - **INSTALL_APP.sh** and **BUILD_APP.sh** (like Data Syncer's), `icon/make_icns.sh`; docs (README,
    CLAUDE.md, Docs/USER_GUIDE, DEVELOPMENT, SCRIPTS).
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
