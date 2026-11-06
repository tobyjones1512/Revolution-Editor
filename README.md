# Revolution Editor

A macOS app for modding Wii and GameCube games and writing Wii homebrew. It started as a disc
image tool and grew into a small IDE: a project navigator, editors for the common Nintendo file
formats, a 3D track preview, and a build pipeline for homebrew.

Useful links:
- [Discord](https://discord.gg/nXFSaFZbHf)
- [Original Author's Guide](https://thecaffeinemediacompany.com/revolution-editor/guide/)

It is alpha software. Expect rough edges, and keep backups of anything you care about.

## What it does

- **Disc tools.** Open a Wii or GameCube image, browse its files, extract or replace them,
  scrub unused space, and unscrub again later using the `.dif` file the scrub wrote.
- **Editors** for the formats used by Mario Kart Wii, Mario Kart: Double Dash!! and
  New Super Mario Bros. Wii: KMP, KCL, BRRES, SZS/U8/RARC archives, BMG, BRSTM, BRSAR, BRLYT,
  BRLAN, TPL, and plain images, text and hex.
- **Track tools.** A 3D preview, collision from OBJ/DAE models, checkpoint and route checks,
  and porting between Mario Kart Wii and Double Dash.
- **Hot Swap.** Play a mod straight from a loose folder in Dolphin, without rebuilding an ISO.
- **Homebrew.** Write a small Swift-like language, design a UI or wire up a node graph, and
  the app turns it into C and builds a `.dol` with devkitPro.

## Requirements

- macOS 15 or later and Xcode to build it.
- Your own game images and keys. Nothing from Nintendo is included, and this project isn't
  affiliated with Nintendo.
- Optional: [Dolphin](https://dolphin-emu.org) for running mods, and
  [devkitPro](https://devkitpro.org/wiki/Getting_Started) for building homebrew.

## Building

Open `Revolution IDE.xcodeproj` in Xcode and run the `Revolution IDE` scheme. The project
doesn't set a signing team, so pick your own under Signing & Capabilities if Xcode asks.

## Layout

```
Revolution IDE/
  RevolutionIDEApp.swift   app entry point, windows and menus
  Core/
    Disc/                  disc images, partitions, encryption, scrubbing
    Formats/               file format readers and writers (Formats/MKDD for Double Dash)
    Homebrew/              Swift-to-C translator, UI and node-graph code generation
    Workbench/             project state, emulator launching, git, hot swap
    Editor/                code editor support: highlighting, completion, undo history
  Views/
    App/                   settings, welcome, help, about and other app-level windows
    Disc/                  the disc browser window
    Workbench/             the project window and all of its editors
Tests/                     standalone check programs, one folder per feature
```

## Tests

Each folder in `Tests/` is a small command-line program that compiles the pieces it needs with
`swiftc` and prints `ok` or `FAIL`. The build command is in a comment at the top of each
`main.swift`, or in a `run.sh` next to it.

Many checks read real game files. Put your images under one folder and point `ROMS_DIR` at it
(the checks look for paths like `$ROMS_DIR/Wii/MKWii/...`). Checks that can't find a file
skip or fail, so don't expect every one to pass without the matching games.

## Licence

GPL v3. See [LICENSE](LICENSE).
