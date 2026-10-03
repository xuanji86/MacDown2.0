# macdown3000 fixtures

The `*.md` files in this directory are copied unmodified from `MacDownTests/Fixtures/` of
[schuyler/macdown3000](https://github.com/schuyler/macdown3000) (commit `962df74793d1d98a0ad9e85628f0a1d6c24769e2`).
They are used as the corpus for the rendering snapshot tests (`Snapshots/`, see `SnapshotTests.swift`).

macdown3000 is a fork of [MacDown](https://github.com/MacDownApp/macdown) by Tzu-ping Chung and is released under the
MIT License. `LICENSE.txt` next to this file is upstream's `LICENSE/macdown.txt`
("Copyright (c) 2014 Tzu-ping Chung" and the macdown3000 contributors); it applies to these files.

Upstream also keeps a `.html` file per fixture. Those are Hoedown output, not CommonMark, so they are not copied.
The golden files in `../../Snapshots/` are this project's own renderer output, reviewed by hand once and regenerated
with `SNAPSHOT_UPDATE=1 swift test` (never use the upstream `.html` as the oracle).
