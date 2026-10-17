# Changelog

All notable changes to App Starter (Keep a Changelog style; dates are when the change was made).

## [0.1.0] — unreleased

### Changed
- 2026-10-16: **INSTALL_APP.sh moves the app** out of build/ into /Applications by default (Matt's choice);
  `-p` / `--copy` copies it instead, leaving build/App Starter.app in place (the old behaviour).
- 2026-10-16: **Application editor order** (Matt's tweak): name / where it goes / working folder, then
  **Environment variables**, then Start, Stop and the health check.

### Fixed
- 2026-10-16: **Code review and deeper testing** (three reviewers; every finding reproduced or read in the code
  before fixing; a test for each). The engine:
  - Two apps of a sub-bundle starting at once could lose one's process number from state.json.
  - Stopping a kept-running multi-line command now waits for, and forces, everything it started (it used to give up
    once the shell itself had quit).
  - **Retry** after a failed check waits for the same process instead of starting a second copy; **Stop what
    started** also stops a kept-running app whose check failed.
  - A kept-running command that hands over to a child (and ends) still counts as running and is stopped properly.
  - The wait starts after the first "already up?" look, and each look is held to the time left.
  - A damaged bundles.json is kept aside (never overwritten by the next save); unreadable secret values no longer
    stop the bundles loading (they are kept aside, and you are told to type them again).
  - Import → Replace keeps the secret values already on this Mac when the file has none.
  - Commands read your `~/.zshrc` (bash: `~/.bashrc`) as Terminal does, so PATH lines there (conda, LM Studio,
    ~/.local/bin) work; its output stays out of the log.
  - **Cancel** stops waiting and leaves a command that is starting alone (it used to kill it and what it started).
  - "Start the rest" no longer runs the start command of an app App Starter already started (no check that can be run).
  - Logs are trimmed with every round of checks (a chatty kept-running app no longer grows its log without limit);
    App Starter's own lines are appended the same way the apps' output is.
  - A kept-running app can't use a return-code check (it would be ignored); older bundles files with missing
    fields still load.
- The app:
  - Start-at-login no longer stops at the first failure (it skips it and starts the next bundle), and runs once per
    **login** (the session id App Starter used doesn't exist on recent macOS, so it was once per restart).
  - Stop-at-logout works when only the menu bar item is open, and a cancelled logout no longer makes a later
    ordinary quit stop those bundles.
  - The bundle editor's Save changes only what it shows (it could undo a login switch made in Settings meanwhile);
    an app moved to a step of its own keeps its place in a custom stop order; the lights can no longer be set by
    an older or cancelled round of checks; Full log from the progress sheet opens reliably; Refresh in the log
    viewer no longer shares ⌘R with Start; Clear every log asks first; the Rename sub-bundle box shows the name.
- Scripts: URL checks to plain `http://` on a Tailscale or LAN name were still blocked by macOS (one Info.plist key
  cancelled the other) — fixed; replacing an open App Starter offers to close it and opens the new one; the new app
  is copied beside the old one and swapped in; commands may use `osascript` (usage description added);
  `--check` reports without the compiler; the test count adds up both test bundles.
- 59 tests (48 engine, 11 app).

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
