<p align="center">
  <img src="Icon/icon.png" width="128" alt="GitHub Switcher icon">
</p>

<h1 align="center">GitHub Switcher</h1>

<p align="center">
  A tiny macOS menu bar app for switching between GitHub CLI (<code>gh</code>) accounts,<br>
  while keeping your global git identity exactly the way you set it.
</p>

---

## Features

- **One-click account switching** – lists every account you are logged in to with `gh` and runs `gh auth switch` for you.
- **Fixed global git identity** – set `user.name` / `user.email` once in the app; it is written to `git config --global` and put back after every switch, so changing the `gh` account never changes who your commits are from.
- **Stays in sync with the CLI** – switch with `gh auth switch` in a terminal and the menu bar updates instantly.
- **Notifications** – a native macOS notification with the account's avatar every time the active account changes, from the app or from the CLI.
- **Avatars** – GitHub profile pictures in the menu bar and the account list (cached locally, refreshed daily).
- **Native look** – styled after the system Wi‑Fi / Bluetooth menus, light and dark mode.
- **English and Vietnamese** – follows your system language.

## Requirements

- macOS 13 Ventura or later
- [GitHub CLI](https://cli.github.com) with at least one account logged in (`gh auth login`)
- Xcode or the Command Line Tools (`xcode-select --install`) to build

## Download

Grab `GitHub-Switcher-<version>.zip` from the [latest release](https://github.com/ptnzzn/github-switcher/releases/latest), unzip it and move **GitHub Switcher.app** to `/Applications` or `~/Applications`. It is a universal build (Apple silicon and Intel).

The app is ad-hoc signed, not notarized, so macOS blocks it on first launch. Either right-click the app → **Open** → **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/GitHub Switcher.app"
```

## Build & install

```bash
git clone https://github.com/ptnzzn/github-switcher.git
cd github-switcher
./build.sh
open ~/Applications/"GitHub Switcher.app"
```

`build.sh` compiles a universal binary with `swiftc`, generates the icon set, ad-hoc signs the bundle and installs it to `~/Applications` (`--no-install` to skip that). `release.sh` builds and packages `dist/GitHub-Switcher-<version>.zip`.

To start it at login, add it in **System Settings → General → Login Items**.

## Usage

Click the avatar in the menu bar:

| Section | What it does |
| --- | --- |
| **Accounts** | Click an account to make it the active `gh` account. The current one has a checkmark. |
| **Git global** | Shows `git config --global user.name` / `user.email`. Click to edit and save. If something else changes them, a **Restore** item appears. |
| **Show username in menu bar** | Toggle the username next to the avatar. |
| **Add Account…** | Opens Terminal with `gh auth login`. |
| **Refresh** | Re-reads accounts and git config and reloads avatars. |

The first time an account changes, macOS asks whether GitHub Switcher may send notifications.

## How it works

- Accounts and the active account are read from `~/.config/gh/hosts.yml`. The app watches that file, so switches made anywhere are picked up immediately.
- Switching runs `gh auth switch -h github.com -u <login>`, then re-applies the saved git identity with `git config --global`.
- The saved git identity lives in the app's user defaults (`com.ptnzzn.github-switcher`). On first launch it is taken from your current global git config.
- Avatars are cached in `~/.config/gh-switcher/avatars/`.

## Project layout

```
Sources/main.swift      The whole app (SwiftUI MenuBarExtra)
Icon/make_icon.swift    Draws Icon/icon.png (1024×1024)
Icon/icon.png           Source image for the app icon
build.sh                Build, sign and install script
release.sh              Build and zip a release
```

To change the icon, edit `Icon/make_icon.swift`, then:

```bash
swiftc Icon/make_icon.swift -o /tmp/make_icon && /tmp/make_icon Icon/icon.png
./build.sh
```
