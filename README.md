# MacDown2.0

A native Markdown editor for macOS 26+ — source on the left, live preview on the right.
Swift 6 + SwiftUI, rendering by markdown-it, optional Quarto (`.qmd`) support.

> **Status:** pre-alpha, under construction (milestone M0). See [PLAN.md](PLAN.md) for the full design.

## Not affiliated

MacDown2.0 is an independent project. It is **not affiliated with, endorsed by, or a continuation of**
[MacDown](https://github.com/MacDownApp/macdown) or [MacDown 3000](https://github.com/schuyler/macdown3000).
No code from those projects is used.

## Requirements

- macOS 26 or later, Apple Silicon
- To build: Xcode 27; Node.js 23.6+ only when changing the JavaScript renderer (`Web/`)

## Development

```sh
make test        # JS tests, drift + module-boundary checks, Swift package tests
make app         # build the app (Debug, ad-hoc signed) into build/DerivedData/Build/Products/Debug
make web         # rebuild the committed web assets after editing Web/ (CI fails on drift)
```

## License

[AGPL-3.0](LICENSE). Each release on GitHub links to the exact source it was built from.
