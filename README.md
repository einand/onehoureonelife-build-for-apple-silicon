# One Life — macOS Apple Silicon Build

Build a native **arm64 macOS app bundle** for [One Hour One Life](https://onehouronelife.com/) from source, with no external library dependencies.

The result is a self-contained `OneLifeApp.app` that runs on Apple Silicon Macs without Homebrew, MacPorts, or any installed libraries.

## Prerequisites

- **macOS** on Apple Silicon (arm64)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Apple Containers** — the `container` CLI (`brew install container` or build from source)
- **Git** — usually included with Xcode CLI tools

No other dependencies are needed. SDL 1.2.15 is built from source with macOS compatibility patches. The PNG → TGA conversion runs inside a Debian container using Apple Containers.

## Quick Start

```bash
git clone git@github.com:einand/onehoureonelife-build-for-apple-silicon.git
cd onehoureonelife-build-for-apple-silicon
./pullAndBuildLatest-For-MacOS.sh
```

This will:

1. Clone the game repositories (minorGems, OneLife, OneLifeData7)
2. Clone the patched SDL 1.2.15 fork and build it as a static library
3. Patch the OneLife build system to add a macOS native platform
4. Convert game graphics (PNG → TGA) via Apple Containers
5. Build the OneLife client as a native arm64 binary
6. Create a `OneLifeApp.app` bundle with icon, Info.plist, and launcher

After the build completes, launch the game:

```bash
open OneLifeApp.app
```

## Updating

To update to the latest game version, simply re-run the script:

```bash
./pullAndBuildLatest-For-MacOS.sh
```

The script will:
- Fetch new tags and check out the latest version
- Rebuild the game binary
- Update the app bundle

SDL is **not** rebuilt if already present — this speeds up incremental updates.

## Clean Build

To force a full rebuild (keeps cloned repositories):

```bash
./pullAndBuildLatest-For-MacOS.sh --clean
```

This removes build artifacts (SDL build, OneLife binary, app bundle, compiled graphics) but preserves the cloned git repositories so they don't need to be re-downloaded.

## What Gets Built

```
OneLifeApp.app/
├── Contents/
│   ├── Info.plist          ← NSHighResolutionCapable = NO (fixes Retina)
│   ├── MacOS/
│   │   ├── OneLifeApp      ← Launcher script
│   │   └── OneLifeApp.bin  ← Native arm64 binary
│   └── Resources/
│       ├── AppIcon.icns
│       ├── defaults/        ← Default settings (.ini files)
│       ├── animations → OneLifeData7/animations
│       ├── categories → OneLifeData7/categories
│       ├── ground → OneLifeData7/ground
│       └── ... (other data symlinks)
```

Personal data (settings, recordings, caches) is stored in `~/.onelife/` and never inside the app bundle.

## How It Works

### SDL 1.2.15 Patches

The SDL fork at [`einand/SDL-1.2.15-onelifeonhour-macos`](https://github.com/einand/SDL-1.2.15-onelifeonhour-macos) contains two patches for modern macOS:

1. **CoreAudio:** Replaces deprecated Component Manager APIs (`FindNextComponent`, `OpenAComponent`, `CloseComponent`) with `AudioComponentFindNext`, `AudioComponentInstanceNew`, `AudioComponentInstanceDispose`
2. **Cocoa video:** Replaces removed `CGDirectPaletteRef` type with `void*`

These patches are already applied in the `release-1.2.15` tag — no manual patching needed.

### PNG → TGA Conversion

The game stores graphics as PNG in `graphicsSource/` but requires TGA in `graphics/`. Conversion runs inside a Debian container using Apple Containers and ImageMagick, so nothing is installed on the host system.

### Build System Patches

The script patches `minorGems/game/platforms/SDL/configure` to add **platform 5** (MacOSX local SDL 1.2) and writes a custom `Makefile.MacOSX_local` that links SDL 1.2 statically plus all required macOS frameworks.

### App Bundle

The `Info.plist` sets `NSHighResolutionCapable` to `false`, which fixes Retina/HiDPI display and mouse coordinate issues with SDL 1.2. The launcher script creates `~/.onelife/` directories on first launch and symlinks them into the app bundle.

## Repository Contents

| File | Purpose |
|---|---|
| `pullAndBuildLatest-For-MacOS.sh` | Main build script |
| `Makefile.macOSX_local` | Makefile fragment (depot path placeholder) |
| `Info.plist` | App bundle metadata |
| `defaults/` | Game default settings (75 .ini files) |
| `mac/SDLMain_compat.m` | Cocoa main bridge for SDL 1.2 on macOS |
| `icon_512.png` | Game icon source image |
| `README.md` | This file |

## License

One Hour One Life is © Jason Rohrer. This build script repository contains only build tooling — no game source code.

SDL 1.2.15 is licensed under the [GNU LGPL v2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html).