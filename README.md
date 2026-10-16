# App Starter

A Mac app that starts and stops your self-hosted apps **in order, with one click**.

Each of your apps (People Manager, My Business Manager, Junk Tracker, the Trading Desk, App Router,
JARVIS…) has its own way to start and stop. App Starter puts them in **application bundles**:

- A bundle is a list of **steps** that start one after another — and stop in the reverse order (or an
  order you set).
- A step is one application, or a **sub-bundle** of applications that start (and stop) together.
- The next step begins only when **every** app in the one before is up (or, when stopping, down).
- Each application has a **start** and a **stop** command — several lines allowed — run as you in your
  login shell, in a working folder, with its own environment variables (secret ones are kept encrypted).
- An optional **health check** tells when it is up: the command's **return code**, a command's **output
  text**, or a **URL** that answers.
- If something fails, the run pauses: **Retry**, **Skip it and go on**, or **Stop what started**.

The **menu bar item** by the clock lists every bundle with its light — **green** all up, **red** all
down, **yellow** some of each — and a Start or Stop button, plus Open App Starter, Settings and Close App
Starter. Bundles can start when you log in and stop when you log out. Everything stays on this Mac.

## Install

```bash
./INSTALL_APP.sh          # checks the tools, runs the tests, builds, copies to /Applications
```

Then open **App Starter** from Applications. `./INSTALL_APP.sh --help` lists the options (`--check`,
`--to DIR`, `--sign`, `--skip-tests`…). Run it again after pulling new code.

## More

- [Docs/USER_GUIDE.md](Docs/USER_GUIDE.md) — bundles, steps, sub-bundles, the editor, health checks, the menu bar, Settings
- [Docs/SCRIPTS.md](Docs/SCRIPTS.md) — INSTALL_APP.sh, BUILD_APP.sh, signing
- [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md) — how it is built, where things are kept, tests, development hooks
- [CHANGELOG.md](CHANGELOG.md)
