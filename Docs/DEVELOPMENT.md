# App Starter — development

## Layout
```
Sources/AppStarterCore/   Models · Engine · Shell · Health · Runtime · Logs · Store · SecretBox · Status · Transfer · Version
Sources/AppStarter/       AppStarterApp (+ AppDelegate) · AppModel · RunSession · MainWindow · Editors · RunSheet (+ LogViewer)
                          MenuBarPanel · SettingsView (+ BackupPane) · ScriptEditor · Sample
                          Design · Themes · AppearancePane · PlainTextField   ← copies of Data Syncer's, keep in step
Tests/AppStarterCoreTests/  StoreTests · EngineTests · Helpers (Scratch, TinyServer, freePort)
icon/                     icon.svg (Power stack) → make_icns.sh → AppStarter.icns (committed)
```

## Build and test
```bash
swift build          # debug build of everything
swift test           # 22 tests, under 10 seconds
./BUILD_APP.sh       # build/App Starter.app (release, ad-hoc signed)
```

## How a run works
`AppModel.run(bundle, phase)` makes a `RunSession` and a Task that calls `Engine.start` / `Engine.stop`.
The engine walks the steps (`stepsInStopOrder` when stopping); each step's apps run in a task group;
failures go to `decide`, which the session answers from the sheet's buttons (`RunSession.ask/choose`).
Events (`.step`, `.app`) update the session on the main actor; the model passes the session's changes on
(`followers`) so the sidebar, rows and menu bar follow.

`Engine.startApp`:
- already up? only when it can really be told (an output/URL check passes, or our kept-running process is alive)
- *starts itself*: `Shell.run` with the time limit → return-code check → poll output/URL until the deadline
- *kept running*: `Shell.spawn`, remember pid + start time (`Runtime.keep`), poll the check (or wait `settleSeconds`)

`Engine.stopApp` mirrors it: stop command (or SIGTERM/SIGKILL to the group), then wait for the check to fail.

## Where things are kept
`Home.folder()` = `~/Library/Application Support/App Starter/`, or `$APPSTARTER_HOME`.
`bundles.json` (secret values blank) · `secrets.enc` (AES-GCM, `{varId: value}`) · `secret.key` (32 random
bytes, 0600) · `state.json` (per app: started, pid, pidStart; the last autostart login session) ·
`settings.json` · `logs/<app id>.log` (trimmed to half once over the limit, in place).

## Development hooks (harmless when unset)
- `APPSTARTER_HOME=<folder>` — use a scratch folder instead of Application Support. **Always** for trying things.
- `APPSTARTER_SAMPLE=1` — with an empty home, fill in example bundles whose commands only touch marker files in `<home>/sample-apps`.
- `APPSTARTER_AUTOSTART="<bundle name>"` — start that bundle a second after launch.
- `APPSTARTER_AUTOSHEET=newApp | editApp | editBundle | log | menubar | settings[:tab]` — open that sheet
  (`menubar` shows the panel in a plain window, for a screenshot).

Screenshots: run the built app's binary with those variables, then `screencapture -x -l <window id>` (after
`caffeinate -u -t 2`; the window id from `CGWindowListCopyWindowInfo`).

## Adding a setting
`AppSettings` in AppModel.swift: add the field, decode it with `decodeIfPresent` and a default (old files must
still load), show it in SettingsView.
