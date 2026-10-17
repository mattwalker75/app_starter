# App Starter — user guide

## The idea
Your apps each start and stop their own way. In App Starter you describe that once, group the apps into
**bundles**, and from then on a bundle starts or stops with one click — in the right order, waiting for
each app to be really up before starting the ones that need it.

## Bundles, steps and sub-bundles
- **New bundle** (bottom of the sidebar, or ⌘N) makes an empty bundle. Give it a name.
- **Add application** adds an app. Each app you add is a **step**; steps start from top to bottom.
- **Add sub-bundle** makes a step that holds several apps which start **together** (at the same time).
  Add apps to it with **Add to this sub-bundle**, or choose it under *Where it goes* in the app's editor.
- The next step begins only when **every** app in the step before is up.
- **Stopping** goes from the bottom up, unless you set your own stop order (Edit → Stop order).
- **Drag a card to rearrange** (hold it, then drag): a step moves up or down the order — a whole sub-bundle by
  grabbing its card anywhere but on one of its apps; an app goes into a sub-bundle (drop it on the sub-bundle, or on an app in it to land just before that
  one), out of one (drop it between steps), or from one to another. A blue line shows where it will land.
- **Pause** an app with the ❚❚ button on its card: it is left out when its bundle starts or stops (and at login /
  logout) and stays exactly as it is. A paused card fades, has a dashed amber edge and a yellow ▶ to resume it.
  Paused apps don't count toward the bundle's light. (Also in the ⋯ menu, right-click, and the editor's **Paused**
  switch.) Sub-bundles can't be paused — pause their apps.
- **Logs** at the top of a bundle's page shows its apps' logs: pick an app on the left; the log follows along
  while it is open (Follow along), with Show in Finder and Clear.
- The **⋯** menu on a step: **Edit…** (the app, or a sub-bundle's name), Move up / Move down, Delete, and for a sub-bundle Start or Stop just that sub-bundle.
- Right-click an app: **Start this one**, **Stop this one**, **Show log**, Edit, Delete.
- Deleting a step, an app or a bundle only makes App Starter forget it — nothing is stopped.

## An application
Click an app to edit it.
- **Start / Stop** at the top of the editor, beside the app's light, start or stop just this app now — even when
  it is paused. The result shows under the buttons. They wait until the app is added and its changes saved.
- **Name** and **Where it goes**: its own step at the end, a sub-bundle, or a new sub-bundle.
- **Working folder** (optional): the commands run there, as you, in your login shell — just as if you typed
  them in Terminal (your PATH and Homebrew work; `~/.zshrc` is read too, quietly).
- **Environment variables**: name and value, for start, stop and the check. Tick **Secret** for passwords
  and keys: the value is kept encrypted on disk, never in the bundles file, and hidden in the log.
- **Start**
  - *Starts itself in the background*: the command sets the app going and finishes
    (`./TRACKER.sh --start`, `open -a Docker`, `docker start open-webui`).
  - *App Starter keeps it running*: the command **is** the app and keeps running (`npm start`,
    `ollama serve`). App Starter keeps it going, writes its output to the log, and can stop it.
  - The box takes **several lines**; they run one after another.
- **Stop**: the command that stops it (several lines allowed). An app App Starter keeps running can leave it
  empty: App Starter asks it to quit and forces it after 10 seconds.
- **Health check** (optional) — how App Starter knows it is up:
  - *None*: up when the start command has finished (kept running: when the process is running).
  - *Return code*: the start command must finish with exit code 0 (and the stop command, to count as down).
  - *Output text*: run a command (for example `./TRACKER.sh --status`); up when its output contains your text.
    *Ignore capitals* if you like.
  - *URL*: up when anything answers at the address (any page, any certificate — your HTTPS and Tailscale apps work).
  - **Wait up to** N seconds (default 60) for it to come up or go down. **Test check** tries the check now.
- Only *Output text* and *URL* checks (and apps App Starter keeps running) can notice an app going down by
  itself; the others show what App Starter last did.

## Starting and stopping
- **Start bundle** (or *Start the rest* when some apps are already up — those are left alone) and **Stop
  bundle** (it asks first, naming the apps) at the top of the bundle's page.
- A sheet shows the run step by step. **Hide — keep it going** closes it; the run carries on (the sidebar
  shows a spinner; **Show progress** brings it back).
- When a step fails the run **pauses** and shows the end of that app's log:
  - **Retry** runs it again,
  - **Skip it and go on** leaves it and starts the next step,
  - **Stop what started** stops what this run started (newest first) and ends.
- **Cancel** stops waiting; whatever has started — even a start command still running — stays as it is.
- **Retry** on an app App Starter keeps running waits for the same process again; it never starts a second copy.

## The lights
- 🟢 **green** — every app in the bundle is up
- 🔴 **red** — every app is down
- 🟡 **yellow** — some up, some down

They are checked every 30 seconds (Settings → General); **Check now** at the bottom of a bundle's page checks at once.

## The menu bar
The power symbol by the clock opens a panel: every bundle with its light and a **Start** / **Start the
rest** / **Stop** button (a busy bundle shows **Show**), then **Open App Starter**, **Settings…** and
**Close App Starter** (your apps keep running). Closing the main window keeps App Starter in the menu bar.

## Settings
- **General**: open App Starter when you log in; show it in the menu bar; how often to check; where its files are.
- **Login**: for each bundle, *Start when I log in* and *Stop when I log out*. Starting at login happens once per
  login, when App Starter first opens (turn on "open at login"). Stopping at logout also happens on restart and
  shut down; a failure is skipped, since nobody is there to answer.
- **Appearance**: Light, Dark, Follow the system, your own themes, the accent colour (as in Data Syncer).
- **Logs**: how big an app's log may grow; open the folder; clear them.
- **Backup**: **Export** the bundles to a file (secret values left out unless you tick *Include secret
  values*), **Import** them — for example on your other Mac. A bundle that is already there can be replaced
  or added as a copy.

## Where things are kept
`~/Library/Application Support/App Starter/`: `bundles.json`, `secrets.enc` + `secret.key`,
`state.json`, `settings.json`, `logs/`. Settings → General → Show in Finder.
