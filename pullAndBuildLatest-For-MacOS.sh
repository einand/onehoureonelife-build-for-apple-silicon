#!/bin/bash
set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly BASEDIR="$(cd "$(dirname "$0")" && pwd)"
readonly DEPOT="$BASEDIR/depot"
readonly APP_NAME="OneLifeApp"
readonly APP_BUNDLE="$BASEDIR/$APP_NAME.app"
readonly REPO_SDL="https://github.com/einand/SDL-1.2.15-onelifeonhour-macos.git"
readonly REPO_MINOR="https://github.com/jasonrohrer/minorGems.git"
readonly REPO_OL="https://github.com/jasonrohrer/OneLife.git"
readonly REPO_OL_DATA="https://github.com/jasonrohrer/OneLifeData7.git"
readonly ICON_URL="https://onehouronelife.com/press/icon_512.png"
readonly CONTAINER_IMAGE="docker.io/library/debian:bookworm-slim"
readonly BUNDLE_RESOURCES="$APP_BUNDLE/Contents/Resources"
readonly BUNDLE_MACOS="$APP_BUNDLE/Contents/MacOS"

CLEAN=0

log()  { echo "[$SCRIPT_NAME] $*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

require_tools() {
    local missing=0
    for cmd in git make clang sed container; do
        if ! command -v "$cmd" &>/dev/null; then
            log "Missing required tool: $cmd"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "Install the missing tools above and re-run."
}

clone_repos() {
    log "Cloning repositories (if not already present)..."
    [ -d "$BASEDIR/minorGems" ]    || git clone "$REPO_MINOR"    "$BASEDIR/minorGems"
    [ -d "$BASEDIR/OneLife" ]      || git clone "$REPO_OL"       "$BASEDIR/OneLife"
    [ -d "$BASEDIR/OneLifeData7" ] || git clone "$REPO_OL_DATA"  "$BASEDIR/OneLifeData7"
    [ -d "$DEPOT/SDL-1.2.15" ]     || git clone "$REPO_SDL"      "$DEPOT/SDL-1.2.15"
}

checkout_latest() {
    log "Checking out latest tagged versions..."

    local tag_mg tag_ol tag_data

    cd "$BASEDIR/minorGems"
    git fetch --tags
    tag_mg=$(git for-each-ref --sort=-creatordate --format='%(refname:short)' --count=1 refs/tags/OneLife_v* | sed 's/OneLife_v//')
    git checkout -q "OneLife_v$tag_mg"
    log "minorGems → OneLife_v$tag_mg"

    cd "$BASEDIR/OneLife"
    git fetch --tags
    tag_ol=$(git for-each-ref --sort=-creatordate --format='%(refname:short)' --count=1 refs/tags/OneLife_v* | sed 's/OneLife_v//')
    git checkout -q "OneLife_v$tag_ol"
    log "OneLife → OneLife_v$tag_ol"

    cd "$BASEDIR/OneLifeData7"
    git fetch --tags
    tag_data=$(git for-each-ref --sort=-creatordate --format='%(refname:short)' --count=1 refs/tags/OneLife_v* | sed 's/OneLife_v//')
    git checkout -q "OneLife_v$tag_data"
    log "OneLifeData7 → OneLife_v$tag_data"

    cd "$DEPOT/SDL-1.2.15"
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true

    cd "$BASEDIR"

    LATEST_VERSION=$tag_data
    [ "$tag_ol" -gt "$tag_data" ] && LATEST_VERSION=$tag_ol
    log "Game version: $LATEST_VERSION"
}

build_sdl() {
    if [ -f "$DEPOT/sdl1/lib/libSDL.a" ] && [ -f "$DEPOT/sdl1/lib/libSDLmain.a" ]; then
        log "SDL 1.2 already built — skipping. Use --clean to rebuild."
        return 0
    fi

    log "Building SDL 1.2.15 (static, arm64 Cocoa backend)..."

    cd "$DEPOT/SDL-1.2.15"
    mkdir -p "$DEPOT/sdl1"

    ./configure \
        --prefix="$DEPOT/sdl1" \
        --disable-shared \
        --enable-static \
        --disable-video-x11 \
        --enable-video-opengl \
        --enable-video-quartz

    make -j"$(sysctl -n hw.ncpu)"
    make install

    cd "$BASEDIR"
    log "SDL 1.2 built and installed to $DEPOT/sdl1/"
}

patch_configure() {
    local configure="$BASEDIR/minorGems/game/platforms/SDL/configure"

    if grep -q "MacOSX_local" "$configure"; then
        log "configure already patched — skipping."
        return 0
    fi

    log "Patching minorGems configure script..."

    cp "$configure" "$configure.bak"

    sed -i '' 's/if \[ "$1" -lt "4" \]/if [ "$1" -lt "5" ]/' "$configure"
    sed -i '' 's/if \[ "$platformSelection" -gt "4" \]/if [ "$platformSelection" -gt "5" ]/' "$configure"
    sed -i '' '/echo "  4 --  Raspbian on Raspberry Pi (experimental)"/a\
\    echo "  5 --  MacOSX (local SDL 1.2)"' "$configure"

    awk '
    /"4" \)/ { in_raspbian=1 }
    in_raspbian && /;;/ {
        print
        print ""
        print "    \"5\" )"
        print "        platformName=\"MacOSX_local\""
        print "        platformMakefile=\"$makefilePath/Makefile.MacOSX_local\""
        print "    ;;"
        in_raspbian=0
        next
    }
    { print }
    ' "$configure" > "$configure.tmp" && mv "$configure.tmp" "$configure" && chmod +x "$configure"

    log "configure patched with platform 5 (MacOSX_local)."
}

install_makefile() {
    local target="$BASEDIR/minorGems/game/platforms/SDL/Makefile.MacOSX_local"
    local src="$BASEDIR/Makefile.macOSX_local"

    [ ! -f "$src" ] && src="$BASEDIR/Makefile.macOSX_local"

    sed "s|__DEPOT_PATH__|$DEPOT|g" "$src" > "$target"
    log "Makefile.MacOSX_local written to minorGems (depot=$DEPOT)."
}

install_sdlmain() {
    local target_dir="$BASEDIR/minorGems/game/platforms/SDL/mac"
    local src="$BASEDIR/mac/SDLMain_compat.m"

    [ ! -f "$src" ] && src="$BASEDIR/minorGems/game/platforms/SDL/mac/SDLMain_compat.m"

    if [ ! -f "$target_dir/SDLMain_compat.m" ] || ! diff -q "$src" "$target_dir/SDLMain_compat.m" &>/dev/null; then
        cp "$src" "$target_dir/SDLMain_compat.m"
        log "SDLMain_compat.m installed."
    else
        log "SDLMain_compat.m already up to date."
    fi
}

patch_freeSprite_null() {
    local file="$BASEDIR/minorGems/game/platforms/openGL/gameGraphicsGL.cpp"

    if grep -q 'if.*inSprite.*NULL' "$file"; then
        log "freeSprite null-check already patched — skipping."
        return 0
    fi

    log "Patching freeSprite() with null-pointer guard..."

    sed -i '' 's/void freeSprite( SpriteHandle inSprite ) {/void freeSprite( SpriteHandle inSprite ) {\
    if( inSprite == NULL ) return;/' "$file"

    log "freeSprite null-check patched."
}

convert_png_to_tga() {
    local gfx_src="$BASEDIR/OneLife/gameSource/graphicsSource"
    local gfx_dst="$BASEDIR/OneLife/gameSource/graphics"

    if [ -f "$gfx_dst/font_32_64.tga" ]; then
        log "TGA files already converted — skipping. Use --clean to reconvert."
        return 0
    fi

    log "Converting PNG → TGA via Apple Container ($CONTAINER_IMAGE)..."

    mkdir -p "$gfx_dst"

    container run --rm \
        -v "$gfx_src:/src:ro" \
        -v "$gfx_dst:/dst" \
        "$CONTAINER_IMAGE" \
        bash -c 'apt-get update -qq && apt-get install -y -qq imagemagick > /dev/null 2>&1 && cd /src && for f in *.png; do convert "$f" -auto-orient -type truecolormatte "/dst/${f%.png}.tga" 2>/dev/null; done && echo "Done"'

    log "TGA conversion complete."
}

configure_and_build() {
    log "Configuring OneLife build (platform 5 = MacOSX_local)..."

    cd "$BASEDIR/OneLife"
    echo "5" | ./configure
    cd gameSource

    log "Building OneLife client..."
    make -j"$(sysctl -n hw.ncpu)"

    cd "$BASEDIR"
    log "Build complete: $(file OneLife/gameSource/OneLife | sed 's/.*: //')"
}

download_icon() {
    local icon_dir="$BUNDLE_RESOURCES"
    local icon_png="$icon_dir/icon_512.png"
    local icon_src="$BASEDIR/icon_512.png"

    if [ -f "$icon_png" ]; then
        log "Icon already present — skipping."
        return 0
    fi

    mkdir -p "$icon_dir"

    if [ -f "$icon_src" ]; then
        cp "$icon_src" "$icon_png"
        log "Icon copied from repo."
    else
        log "Downloading app icon..."
        curl -sL "$ICON_URL" -o "$icon_png"
    fi
}

create_icns() {
    local icon_png="$BUNDLE_RESOURCES/icon_512.png"
    local iconset="$BASEDIR/icon.iconset"
    local icns="$BUNDLE_RESOURCES/AppIcon.icns"

    if [ -f "$icns" ] && [ "$icns" -nt "$icon_png" ]; then
        log "AppIcon.icns already exists — skipping."
        return 0
    fi

    log "Creating AppIcon.icns..."
    mkdir -p "$iconset"
    sips -z 16 16     "$icon_png" --out "$iconset/icon_16x16.png"     &>/dev/null
    sips -z 32 32     "$icon_png" --out "$iconset/icon_16x16@2x.png"   &>/dev/null
    sips -z 32 32     "$icon_png" --out "$iconset/icon_32x32.png"     &>/dev/null
    sips -z 64 64     "$icon_png" --out "$iconset/icon_32x32@2x.png"   &>/dev/null
    sips -z 128 128   "$icon_png" --out "$iconset/icon_128x128.png"   &>/dev/null
    sips -z 256 256   "$icon_png" --out "$iconset/icon_128x128@2x.png" &>/dev/null
    sips -z 256 256   "$icon_png" --out "$iconset/icon_256x256.png"   &>/dev/null
    sips -z 512 512   "$icon_png" --out "$iconset/icon_256x256@2x.png" &>/dev/null
    sips -z 512 512   "$icon_png" --out "$iconset/icon_512x512.png"   &>/dev/null
    sips -z 1024 1024 "$icon_png" --out "$iconset/icon_512x512@2x.png" &>/dev/null
    iconutil -c icns "$iconset" -o "$icns"
    rm -rf "$iconset"
    log "AppIcon.icns created."
}

create_app_bundle() {
    log "Creating app bundle..."

    mkdir -p "$BUNDLE_MACOS"
    mkdir -p "$BUNDLE_RESOURCES/defaults"

    cp "$BASEDIR/OneLife/gameSource/OneLife" "$BUNDLE_MACOS/OneLifeApp.bin"
    chmod +x "$BUNDLE_MACOS/OneLifeApp.bin"

    local launcher="$BUNDLE_MACOS/$APP_NAME"
    cat > "$launcher" << 'LAUNCHER'
#!/bin/bash
ONELIFE_HOME="$HOME/.onelife"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES="$APP_DIR/../Resources"

mkdir -p "$ONELIFE_HOME"/{settings,reverbCache,groundTileCache,recordGame,keepPastRecordings}

if [ ! -f "$ONELIFE_HOME/settings/fullscreen.ini" ]; then
    cp "$RESOURCES/defaults/"* "$ONELIFE_HOME/settings/" 2>/dev/null
fi

printf '%s' "$APP_DIR" > "$HOME/Library/Preferences/OneLifeApp_prefs.txt"

cd "$RESOURCES" || exit 1
ln -sf "$ONELIFE_HOME/settings" . 2>/dev/null
ln -sf "$ONELIFE_HOME/reverbCache" . 2>/dev/null
ln -sf "$ONELIFE_HOME/groundTileCache" . 2>/dev/null
ln -sf "$ONELIFE_HOME/recordGame" . 2>/dev/null
ln -sf "$ONELIFE_HOME/keepPastRecordings" . 2>/dev/null

exec "$APP_DIR/OneLifeApp.bin" "$@"
LAUNCHER
    chmod +x "$launcher"

    local plist_src="$BASEDIR/Info.plist"
    [ ! -f "$plist_src" ] && plist_src="$BASEDIR/Info.plist"
    cp "$plist_src" "$APP_BUNDLE/Contents/Info.plist"

    local defaults_src="$BASEDIR/defaults"
    if [ ! -d "$defaults_src" ] || [ -z "$(ls -A "$defaults_src" 2>/dev/null)" ]; then
        defaults_src="$BASEDIR/OneLife/gameSource/settings"
    fi
    cp "$defaults_src/"*.ini "$BUNDLE_RESOURCES/defaults/"

    log "App bundle created at $APP_BUNDLE"
}

link_game_data() {
    log "Linking game data into app bundle..."

    local res="$BUNDLE_RESOURCES"

    for d in animations categories ground music objects sounds sprites transitions contentSettings; do
        if [ ! -e "$res/$d" ]; then
            ln -sf "../../../OneLifeData7/$d" "$res/$d"
        fi
    done

    if [ ! -e "$res/dataVersionNumber.txt" ]; then
        ln -sf "../../OneLifeData7/dataVersionNumber.txt" "$res/dataVersionNumber.txt"
    fi

    mkdir -p "$res/graphics"
    mkdir -p "$res/otherSounds"
    mkdir -p "$res/languages"

    cp -n "$BASEDIR/OneLife/gameSource/graphics/"*.tga "$res/graphics/" 2>/dev/null || true
    cp -n "$BASEDIR/OneLife/gameSource/otherSounds/"* "$res/otherSounds/" 2>/dev/null || true
    cp -n "$BASEDIR/OneLife/gameSource/languages/"* "$res/languages/" 2>/dev/null || true

    cp "$BASEDIR/OneLife/gameSource/language.txt" "$res/" 2>/dev/null || true
    cp "$BASEDIR/OneLife/gameSource/us_english_60.txt" "$res/" 2>/dev/null || true
    cp "$BASEDIR/OneLife/gameSource/reverbImpulseResponse.aiff" "$res/" 2>/dev/null || true
    cp "$BASEDIR/OneLife/gameSource/wordList.txt" "$res/" 2>/dev/null || true
    cp "$BASEDIR/OneLife/documentation/Readme.txt" "$res/" 2>/dev/null || true
    cp "$BASEDIR/OneLife/no_copyright.txt" "$res/" 2>/dev/null || true

    for f in animations categories ground music objects sounds sprites transitions; do
        if [ ! -e "$BASEDIR/$f" ]; then
            ln -sf "OneLifeData7/$f" "$BASEDIR/$f"
        fi
    done
    if [ ! -e "$BASEDIR/dataVersionNumber.txt" ]; then
        ln -sf "OneLifeData7/dataVersionNumber.txt" "$BASEDIR/dataVersionNumber.txt"
    fi

    log "Game data linked."
}

clean_build() {
    log "Cleaning build artifacts (keeping cloned repos)..."

    rm -rf "$DEPOT/sdl1"
    rm -rf "$APP_BUNDLE"
    rm -f "$BASEDIR/minorGems/game/platforms/SDL/Makefile.MacOSX_local"
    rm -f "$BASEDIR/minorGems/game/platforms/SDL/configure"
    if [ -f "$BASEDIR/minorGems/game/platforms/SDL/configure.bak" ]; then
        mv "$BASEDIR/minorGems/game/platforms/SDL/configure.bak" "$BASEDIR/minorGems/game/platforms/SDL/configure"
    fi
    rm -f "$BASEDIR/OneLife/gameSource/OneLife"
    rm -rf "$BASEDIR/OneLife/gameSource/graphics"
    rm -rf "$BASEDIR/OneLife/gameSource/Makefile"
    rm -rf "$BASEDIR/OneLife/gameSource/Makefile.temp"
    rm -f "$BASEDIR/OneLifeApp"

    log "Clean complete."
}

print_result() {
    echo ""
    echo "============================================"
    echo "  One Life v$LATEST_VERSION — Build Complete!"
    echo ""
    echo "  Run:  open $APP_BUNDLE"
    echo "  Or:   $BUNDLE_MACOS/$APP_NAME"
    echo ""
    echo "  Personal data lives in ~/.onelife/"
    echo "============================================"
}

main() {
    echo "=== One Life — macOS Apple Silicon Build ==="
    echo ""

    for arg in "$@"; do
        case "$arg" in
            --clean) CLEAN=1 ;;
            -h|--help)
                echo "Usage: $SCRIPT_NAME [--clean]"
                echo ""
                echo "  --clean   Remove build artifacts (keeps cloned repos) and rebuild"
                echo ""
                exit 0
                ;;
        esac
    done

    require_tools
    mkdir -p "$DEPOT"

    if [ "$CLEAN" -eq 1 ]; then
        clean_build
    fi

    clone_repos
    checkout_latest
    build_sdl
    patch_configure
    install_makefile
    install_sdlmain
    patch_freeSprite_null
    convert_png_to_tga
    configure_and_build
    download_icon
    create_icns
    create_app_bundle
    link_game_data
    print_result
}

main "$@"