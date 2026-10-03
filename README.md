# MacDown2.0

A native Markdown editor for macOS 26+ — source on the left, live preview on the right.
Swift 6 + SwiftUI, rendering by markdown-it, optional Quarto (`.qmd`) support.

> **Status:** pre-alpha, under construction (milestone M0). See [PLAN.md](PLAN.md) for the full design.

## Not affiliated

MacDown2.0 is an independent project. It is **not affiliated with, endorsed by, or a continuation of**
[MacDown](https://github.com/MacDownApp/macdown) or [MacDown 3000](https://github.com/schuyler/macdown3000).
No code from those projects is used.

## Install

MacDown2.0 is not signed with an Apple Developer ID and is not notarized (ad-hoc signed only), so macOS Gatekeeper
treats a directly downloaded copy as coming from an unidentified developer. Pick one of these:

**Homebrew (recommended)**

```sh
brew install --cask xuanji86/tap/macdown2
```

The cask removes the quarantine flag after installing, so the app starts without a prompt.
(The official `homebrew/cask` tap does not accept non-notarized apps, hence the separate tap. Homebrew has removed
`--no-quarantine`; you do not need it.)

**Manual download**

1. Download `MacDown2-<version>.dmg` from [Releases](https://github.com/xuanji86/MacDown2.0/releases) and drag
   MacDown2 to Applications.
2. Open it once. macOS says it cannot verify the app. Click **Done** (not "Move to Bin").
3. Open **System Settings → Privacy & Security**, scroll down to the message about "MacDown2", click **Open Anyway**
   and confirm (macOS 15 and later no longer offers this via right-click → Open). This is needed only once.

   Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/MacDown2.app`

After the first launch the app updates itself (MacDown2 → Check for Updates…); updates do not need these steps again.

Every release ships with the exact source it was built from (AGPL-3.0, see below).

## Requirements

- macOS 26 or later, Apple Silicon
- To build: Xcode 27; Node.js 23.6+ only when changing the JavaScript renderer (`Web/`)

## Development

```sh
make test        # JS tests, drift + module-boundary checks, Swift package tests
make app         # build the app (Debug, ad-hoc signed) into build/DerivedData/Build/Products/Debug
make web         # rebuild the committed web assets after editing Web/ (CI fails on drift)
Scripts/release.sh 0.1.0   # dry run of a release: ad-hoc signed zip + dmg, appcast, Homebrew cask in build/release/0.1.0
```

`--publish` creates a draft GitHub Release; it needs a Sparkle EdDSA key (`generate_keys`) and the public key in
`App/Info.plist`. See PLAN.md §4.14 and §6.3.

## License

[AGPL-3.0](LICENSE). Each release on GitHub includes the exact source it was built from (the tag's source archive, linked in the release
notes), as the AGPL requires.
