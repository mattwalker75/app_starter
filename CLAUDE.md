# CLAUDE.md — working on App Starter

Read this before changing anything. `Docs/` has the detail.

## What it is
A Mac app (Swift + SwiftUI, macOS 14+, no Xcode project — SwiftPM + `BUILD_APP.sh`, modelled on
`../data_syncer`) that starts and stops **application bundles** of Matt's self-hosted apps in order, with
one click, from a window or the menu bar. This Mac only — never remote machines. The person using it is not
a developer: every message is a plain sentence.

## Map
- `Sources/AppStarterCore/` — no UI, tested on its own.
  - `Models.swift` — AppBundle → Step (one app, or a sub-bundle) → AppItem (start/stop scripts, mode, env, health, waitSeconds), ASError.
  - `Engine.swift` — start/stop a bundle (serial steps, parallel within a step, Failure → `decide` → Choice) and one app.
  - `Shell.swift` — commands through the login shell (`-l -c`), posix_spawn in their own process group, output straight to the log file.
  - `Health.swift` (URL / output checks), `Runtime.swift` (state.json: started, kept-running pid + start time, autostart session),
    `Logs.swift`, `Store.swift` (bundles.json, Home), `SecretBox.swift`, `Status.swift`, `Transfer.swift` (export/import).
- `Sources/AppStarter/` — the app. `AppModel` drives the core; `RunSession` is one run as the UI sees it.
  `MainWindow` (sidebar + BundleDetail + StepRow + AppRow), `Editors` (bundle, sub-bundle, AppEditor), `RunSheet` (+ LogViewer),
  `MenuBarPanel`, `SettingsView` (+ BackupPane), `ScriptEditor` (multi-line command box). The look is data_syncer's:
  `Design.swift`, `Themes.swift`, `AppearancePane.swift`, `PlainTextField.swift` are copies — keep them in step.
- `Tests/AppStarterCoreTests/` — XCTest against throwaway folders (`Scratch`) and a fast `Engine`.

## Rules that exist for a reason (Matt's decisions, Oct 16 2026)
1. **Design:** mockup layout A "Sidebar + step list" (canvas VcL2yivX8zn8AuGXs8UVkk); icon "2 · Power stack"
   (`icon/icon.svg`; menu bar glyph = SF Symbol `power`). Keep it.
2. **A bundle is stand-alone:** created empty, its apps are made inside it; the same app typed into two bundles is
   the user's business (no shared library of apps).
3. **Order:** steps run one after another; a sub-bundle (one level only) runs its apps in parallel; every app in a step
   must be up (down) before the next step. Stop order = reverse unless `stopOrder` is set. Next step waits for the health
   check; no check → the command finishing. Each app has its own wait (default 60 s).
4. **Failure** pauses the run: Retry / Skip it and go on / Stop what started (only what THIS run started). Nobody to
   answer (login, logout) → skip.
5. **Commands:** run as the user, in their login shell, in the optional working folder; **several lines** allowed
   (Matt asked); each command in its own process group; output into the log file directly (never a pipe — a kept-running
   app must survive App Starter quitting). `APPSTARTER_*` variables are never passed on.
6. **Two run modes:** starts itself in the background (needs a stop command) / App Starter keeps it running (no stop
   command = SIGTERM to the group, SIGKILL after 10 s; found again after a relaunch by pid + start time).
7. **Health checks:** none · return code (start/stop command exit 0) · output text (contains, optional ignore capitals) ·
   URL (ANY answer = up, any certificate, redirects not followed). Lights re-check every `checkEvery` s; only output/URL
   checks (and kept-running processes) can see an app go down by itself.
8. **Lights:** green all up, red all down, yellow some of each — the same in the sidebar, the window and the menu bar.
9. **Env vars** belong to one app (used for start, stop and the check); no shared ones. **Secrets: encrypted on disk,
   NOT the Keychain** (Matt): AES-GCM `secrets.enc` + `secret.key` (0600); never in bundles.json; hidden in App Starter's
   log lines; left out of exports unless asked.
10. **Menu bar** (Matt insisted): every bundle with its light and Start / Stop, Open App Starter, Settings, Close App
    Starter (apps keep running). Closing the window keeps the app in the menu bar. `MenuBarExtra(isInserted:)` must get a
    binding that writes only real changes — writing the same value back looped the scene graph and crashed at launch.
11. **Login/logout:** "Open App Starter at login" is a toggle (SMAppService); each bundle can start at login (once per login
    session — `LoginSession.current`) and stop at logout/restart/shutdown (`applicationShouldTerminate` → `.terminateLater`).
12. **Confirm before stopping a bundle** (names its apps); confirm buttons have no destructive role, Cancel is default
    (data_syncer rule 14a).
13. **Scripts:** BUILD_APP.sh / INSTALL_APP.sh like data_syncer's; idempotent, plain-spoken. **Commits:** one per feature
    with a dated CHANGELOG entry; explicit `git add <paths>`; never push — Matt pushes.
14. **Testing:** `swift test`; never the real Application Support — `APPSTARTER_HOME=<scratch>` for the app, `Scratch` in
    tests. Never run Matt's real start/stop commands while testing; the sample bundles (`APPSTARTER_SAMPLE=1`) only touch
    marker files. Dev hooks: `APPSTARTER_AUTOSTART`, `APPSTARTER_AUTOSHEET` (Docs/DEVELOPMENT.md).
