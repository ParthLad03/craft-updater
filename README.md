# CraftUpdater

Keeps Artcraft's macOS apps (WordCraft, PdfCraft, DeckCraft and the rest) up to date. When you
open one of them, CraftUpdater checks GitHub for a newer version. If there is one, it asks you
whether to install it.

- **Nothing runs in the background.** CraftUpdater starts only when a Craft app opens, and exits
  when it's done.
- **You decide.** Nothing is downloaded or installed unless you click **Update**.
- **Only genuine Artcraft builds get installed.** Every download is checked against the release's
  checksum, Apple's signature and notarization checks, and Artcraft's developer ID before it
  replaces anything.

macOS only. Windows and Linux aren't supported.

> CraftUpdater is a community project. It isn't made or endorsed by Artcraft (yet). It installs
> only builds that Artcraft itself signed; see [Security checks](#security-checks).

---

## Contents

1. [Requirements](#requirements)
2. [Install](#install)
3. [What you'll see](#what-youll-see)
4. [Which apps are covered](#which-apps-are-covered)
5. [Adding another Craft app later](#adding-another-craft-app-later)
6. [Everyday commands](#everyday-commands)
7. [Settings](#settings)
8. [How it works](#how-it-works)
9. [Security checks](#security-checks)
10. [Troubleshooting](#troubleshooting)
11. [Uninstall](#uninstall)
12. [Known limits](#known-limits)
13. [Files](#files)
14. [License](#license)

---

## Requirements

| Need | Why | Check |
|---|---|---|
| macOS 11 or later (tested on macOS 26) | Uses AppKit and `launchd` | `sw_vers` |
| Swift compiler (Xcode or its Command Line Tools) | `install.sh` builds CraftUpdater from source | `swiftc --version`; if missing: `xcode-select --install` |
| A Craft app installed from its `.dmg` | That's what gets updated | `ls /Applications/*Craft.app` |
| Write access to the app's folder | The new version replaces the old one there | True for `/Applications` on an admin account |
| Internet access to `github.com` | Release info and downloads come from GitHub | |

Install the apps the usual way: open the `.dmg` from the app's GitHub releases page
(`https://github.com/storytold/<app>/releases/latest`) and drag the app into **Applications**.
Then **open each app once** before installing CraftUpdater, so the app creates its data folder.

---

## Install

```sh
git clone https://github.com/ParthLad03/craft-updater.git
cd craft-updater
./install.sh
```

You'll see one line for each Craft app it found, for example:

```
watching DeckCraft
watching PdfCraft
watching WordCraft
CraftUpdater installed. It runs only when a Craft app opens. Log: ~/Library/Logs/CraftUpdater.log
```

That's all. There's nothing to keep running and nothing to add to Login Items: the setup survives
restarts.

Re-run `./install.sh` whenever you:

- install another Craft app ([details](#adding-another-craft-app-later));
- change CraftUpdater's code or settings.

The installed copy doesn't depend on this folder, so you can move or delete the folder afterwards.
You'll need it again only to reinstall, change settings or uninstall.

---

## What you'll see

**1. You open a Craft app and an update exists.** Within a few seconds:

```
┌──────────────────────────────────────────────────────┐
│  [icon]  An update to DeckCraft is available         │
│                                                      │
│          Do you want to install DeckCraft v0.7.0?    │
│          You have 0.6.1.                             │
│                                                      │
│          If you choose Update, the new version       │
│          downloads while you keep working. Then you  │
│          choose when to restart DeckCraft to use it. │
│                                                      │
│                              [ Cancel ]  [ Update ]  │
└──────────────────────────────────────────────────────┘
```

The popup stays above the app's windows. **Return** chooses Update and **Esc** chooses Cancel.

**2. You click Update.** A small window shows the download, with its own **Cancel** button:

```
┌ Updating DeckCraft ──────────────────────────────────┐
│  [icon]  Downloading DeckCraft v0.7.0…               │
│          ███████████████░░░░░░░░░░░░░░               │
│                                          [ Cancel ]  │
└──────────────────────────────────────────────────────┘
```

You can keep working in the app while it downloads (most apps are 60–110 MB). Then the window shows
**Checking the download…** for a few seconds.

**3. You choose when to restart.** Once the download has passed every check:

```
┌──────────────────────────────────────────────────────┐
│  [icon]  DeckCraft v0.7.0 is ready                   │
│                                                      │
│          Restart DeckCraft to finish updating. It    │
│          asks you to save any changes first, then    │
│          opens again with the new version.           │
│                                                      │
│          If you choose Later, the update is          │
│          installed when you quit DeckCraft, and the  │
│          new version opens next time.                │
│                                                      │
│                         [ Later ]  [ Restart Now ]   │
└──────────────────────────────────────────────────────┘
```

- **Restart Now:** the app quits the normal way, so **it asks you to save** any unsaved work.
  The new version is put in place and the app opens again, already updated.
- **Later:** keep working. The update is installed when you quit the app, and the next start is
  the new version.
- If you cancel the app's save prompt after **Restart Now**, it behaves like **Later**.
- If you quit the app yourself during the download, the update is installed straight away and a
  popup offers **Open DeckCraft** or **Close**.

**You click Cancel.** Nothing is downloaded or changed, and you aren't asked again while the app
stays open. You're asked again the next time you start the app.

You're asked **once per start of an app**, only about the app that's starting. Apps you already
have open are never interrupted.

**No update, or no internet.** Nothing appears at all. The result goes to the log.

**Something fails** (a bad download, a signature that doesn't match, no write access). You see
"*App* couldn't be updated" with the reason. Your installed app is left exactly as it was.

---

## Which apps are covered

Any app in `/Applications` or `~/Applications` whose bundle ID starts with `ai.storyteller.`.
That's every Artcraft app: WordCraft, PdfCraft, DeckCraft, PhotoCraft, VectorCraft, FilmCraft,
LightCraft, EffectCraft, DesignCraft and so on.

For an app with bundle ID `ai.storyteller.<name>`, CraftUpdater looks for:

| What | Where |
|---|---|
| Latest release | `https://github.com/storytold/<name>/releases/latest` |
| macOS download | the release asset `<name>-<version>-macos-universal.dmg` |
| Checksums | the release asset `SHA256SUMS.txt` |
| Launch signal | `~/Library/Application Support/<App name>/logs/` |

To see an installed app's bundle ID:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/DeckCraft.app/Contents/Info.plist
```

Only the desktop app (`.app`) is updated. The command-line tools (`*-cli-*.zip`) are not.

---

## Adding another Craft app later

1. Install it from its `.dmg` into **Applications**.
2. Open it once and quit it. This creates its `logs` folder.
3. Run `./install.sh` again. Check that the output lists the new app (`watching PhotoCraft`).

Until you re-run `install.sh`, opening the new app won't start CraftUpdater by itself. If
CraftUpdater happens to be running for another Craft app at that moment (downloading, say), the
new app is checked too.

---

## Everyday commands

```sh
# Installed vs latest version of every Craft app (doesn't install anything)
~/Library/Application\ Support/CraftUpdater/craft-updater --status

# What CraftUpdater has done
tail -20 ~/Library/Logs/CraftUpdater.log

# Watch it live while you open an app
tail -f ~/Library/Logs/CraftUpdater.log

# Is it set up? ("runs" counts how often launchd has started it)
launchctl print gui/$(id -u)/local.craft-updater | grep -E 'state|runs|last exit'
```

Example `--status` output:

```
DeckCraft: installed 0.6.1, latest v0.7.0 - update available
PdfCraft: installed 0.8.0, latest v0.8.0 - up to date
WordCraft: installed 0.7.0, latest v0.7.0 - up to date
```

Example log of a successful update:

```
2026-10-16T08:19:22Z DeckCraft: 0.6.1 -> v0.7.0 available
2026-10-16T08:19:30Z DeckCraft: downloading deckcraft-0.7.0-macos-universal.dmg
2026-10-16T08:21:40Z DeckCraft: v0.7.0 verified and staged
2026-10-16T08:21:44Z installed /Applications/DeckCraft.app (now 0.7.0)
2026-10-16T08:21:45Z DeckCraft reopened (0.7.0, pid 41234)
```

---

## Settings

The settings are constants at the top of `Sources/main.swift`. After changing one, run
`./install.sh` again.

| Constant | Default | Meaning |
|---|---|---|
| `githubOwner` | `"storytold"` | The GitHub account the releases come from |
| `bundlePrefix` | `"ai.storyteller."` | Which apps count as Craft apps |
| `artcraftTeamID` | `"DJ6XS33FX8"` | The Apple developer team every update must be signed by |

Every start of a Craft app asks GitHub once. GitHub allows 60 anonymous requests an hour per
network, so you'd have to start Craft apps more than once a minute for an hour to hit it.

---

## How it works

```
 you open DeckCraft
        │
        ▼
 DeckCraft starts a fresh log file in
 ~/Library/Application Support/DeckCraft/logs/
        │  (launchd is watching that folder: WatchPaths)
        ▼
 launchd starts craft-updater
        │
        ├─ ask GitHub for the latest release (< 1 s)
        ├─ not newer ──────────────────────────────────► log "up to date", exit
        ▼
 popup: Update / Cancel ── Cancel ─────────────────────► exit
        │ Update
        ▼
 download with progress → checksum → codesign → team ID → Gatekeeper
        │                                 any check fails ─► error popup, exit
        ▼
 copy to /Applications/.DeckCraft.app.update
        ▼
 popup: Restart Now / Later
        │ Restart Now                       │ Later
        ▼                                   ▼
 quit DeckCraft (it asks to save)     wait until you quit DeckCraft
 → swap in new version → reopen       → swap in new version
        ▼                                   ▼
       exit                                exit
```

- `install.sh` builds `craft-updater`, copies it to `~/Library/Application Support/CraftUpdater/`,
  and writes `~/Library/LaunchAgents/local.craft-updater.plist`. That file lists one watched
  folder per Craft app found.
- Every Craft app starts a new log file when it opens: it renames the old one to `<app>.1.log` and
  creates a new `<app>.log`. That change to the folder is the signal. Ordinary log writes while the
  app runs don't change the folder, so they don't start CraftUpdater.
- It only asks about apps that started in the last minute, so a Craft app you already have open
  doesn't get a popup because a different one started.
- Nothing is saved between runs: every start of an app asks GitHub fresh.
- While a run is still going (downloading, or waiting for an app to quit), it also notices other
  Craft apps that open.

---

## Security checks

The installed app is replaced only after **all** of these pass:

1. **Checksum.** The `.dmg`'s SHA-256 matches its line in the release's `SHA256SUMS.txt`.
2. **Right app.** The `.dmg` contains an app with the same bundle ID as the installed one.
3. **Valid signature.** `codesign --verify --deep --strict` passes on the exact copy that gets
   installed.
4. **Artcraft's team.** The signature's TeamIdentifier is `DJ6XS33FX8`, the same team that signed
   the apps you installed by hand.
5. **Gatekeeper.** `spctl --assess --type execute` accepts it, which means Apple notarized it.

If any check fails, the new copy is deleted, your app is untouched, and you see the reason. The swap
itself is a single `replaceItemAt` on the same disk, so the app is never left half-copied.

CraftUpdater uses only Apple's own tools and frameworks. It has no third-party code and sends nothing
anywhere except the GitHub requests above.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No popup, but `--status` says "update available" | The app was already open; you're asked only when it starts | Quit the app (**⌘Q**, not just closing its window) and open it again |
| No popup, and the log has no line for that app | Its `logs` folder isn't watched (new app, or installed before you ran `install.sh`) | Open the app once, then re-run `./install.sh` |
| `install.sh` says "no Craft apps found" | Apps aren't in `/Applications` or `~/Applications` | Move them there (drag from the `.dmg`) |
| `swiftc: command not found` | No Swift compiler | `xcode-select --install`, then re-run `./install.sh` |
| Log: `update check failed: HTTP 403` | GitHub's hourly limit for your network ran out (often on shared Wi-Fi, where everyone shares it) | Wait up to an hour |
| Log: `release vX has no <name>-X-macos-universal.dmg` | That release has no macOS build (yet) | Nothing to do. It's picked up when a later release has one |
| Popup: "can't write to /Applications" | Not an admin account, or the folder is protected | Put the app in `~/Applications` instead, then re-run `./install.sh` |
| Popup: "signature invalid" or "not signed by Artcraft's team" | The download isn't a genuine Artcraft build | Don't install it by hand either. Check the release on GitHub |
| App reopened without the document you had open | Expected after **Restart Now** | Open the document again |
| Nothing happens and the log says nothing | CraftUpdater isn't set up | `launchctl print gui/$(id -u)/local.craft-updater`; if it's not found, run `./install.sh` |

---

## Uninstall

```sh
./uninstall.sh
```

This stops and removes CraftUpdater and its launch setup. Your apps stay as they are, at whatever
version they're on. The log at `~/Library/Logs/CraftUpdater.log` is kept; delete it by hand if you
like.

---

## Known limits

- **macOS only.**
- After **Restart Now**, the app reopens with no document. Reopen what you were working on.
- An app started from a terminal with `--version`, or with `WORDCRAFT_NO_PREFS` set, writes no
  log file, so no check happens. Opening from the Dock, Finder, Launchpad or Spotlight always works.
- A "portable" copy of an app that keeps its data somewhere other than
  `~/Library/Application Support/<App>/` isn't watched.
- Only the newest release is offered. There's no way to pick an older version or a pre-release.

---

## Files

| Path | What |
|---|---|
| `Sources/main.swift` | All of CraftUpdater |
| `install.sh` | Build, install, and set up the watched folders |
| `uninstall.sh` | Remove it |
| `~/Library/Application Support/CraftUpdater/craft-updater` | The installed program |
| `~/Library/LaunchAgents/local.craft-updater.plist` | Tells `launchd` which folders to watch |
| `~/Library/Logs/CraftUpdater.log` | What it did |

### For testing

```sh
# Run the whole download → verify → install path on a COPY of an app, no popup.
ditto /Applications/DeckCraft.app /tmp/DeckCraft.app
~/Library/Application\ Support/CraftUpdater/craft-updater --simulate /tmp/DeckCraft.app
```

To try the real popup, install an older release of any Craft app from its GitHub releases page
and open the app.

---

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. This is the same dual license the Artcraft apps use.

Unless you explicitly state otherwise, any contribution you intentionally submit for inclusion in
this work, as defined in the Apache-2.0 license, shall be dual licensed as above, without any
additional terms or conditions.
