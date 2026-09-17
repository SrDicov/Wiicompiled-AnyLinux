#!/usr/bin/env bash
# Packages an already-built WiiCompiled game binary (WiiCompiled/RetroRewind
# as linked by Launcher/local-build.sh on the user's own machine) as a
# self-contained AnyLinux AppImage, using the SAME method - and the same
# pinned quick-sharun - as Launcher/build-appimage.sh.
#
# Why: the setup AppImage distributes the toolchain, but local-build.sh links
# the game against the HOST's glibc/libstdc++/libX11/Vulkan-loader, so the
# installed game only runs on the machine that built it. Wrapping the linked
# output bundles that whole closure (glibc + ld-linux included), making the
# installed game run on old glibc distros, musl systems and NixOS, exactly
# like the setup image itself.
#
# Design constraints (all deliberate):
# - OFFLINE: every pack-time input comes from the setup image
#   ($SETUP_APPDIR/packaging/, pre-seeded by build-appimage.sh): pinned
#   quick-sharun.sh, sharun tarball, appimagetool, cross-libc tarball. They
#   are referenced via file:// URLs, so game packaging needs NO network.
#   Integrity: SKIP_INTEGRITY_CHECKS=1 is justified (not lazy) - these exact
#   bytes were hash-verified when the setup image itself was built, and they
#   travel inside our own image. Chain of trust, documented here.
# - DETERMINISTIC closure, no strace roulette: the link inputs are known, so
#   STRACE_MODE=0. dlopened-but-not-linked libs are deployed explicitly
#   (libdbus for MPRIS, SDL audio backends via DEPLOY_PIPEWIRE/PULSE, mesa via
#   DEPLOY_VULKAN). The game hard-requires recent Vulkan, so drivers are
#   BUNDLED (USE_HOST_DRIVERS_EXPERIMENTAL is Qt/GTK-only and forbidden here).
# - NO runtime code changes needed: dsp_coef.bin, wii_bootstrap/ and
#   initial_pipeline_cache.db all resolve adjacent to the exe (read-only), so
#   they ship as relative symlinks in bin/ -> ../share/game/. Everything
#   writable (saves, Config.toml, logs, pipeline/user cache) already goes to
#   XDG on Linux - provided portable.txt is NEVER shipped (it is not).
# - Host tool surface at pack time is closed by the setup image too: bash,
#   coreutils, patchelf, tar and strings come from $SETUP_APPDIR/bin via PATH;
#   ldd is provided as a tiny shim over the setup image's OWN deployed
#   linker (ldd is just `ld-linux --list`). Only /bin/sh + core file ops are
#   assumed from the host.
set -euo pipefail

game_exe=""
profile="base"
main_bin=""
data_dir=""
setup_appdir=""
output=""
arch="$(uname -m)"

usage() {
    cat <<'EOF'
Usage: package-game-appimage.sh --game-exe FILE --data-dir DIR --setup-appdir DIR --output FILE [options]

  --game-exe FILE     Linked game binary (WiiCompiled or RetroRewind)
  --data-dir DIR      Directory holding its sibling support files
                      (dsp_coef.bin, wii_bootstrap/ required; initial_pipeline_cache.db optional)
  --setup-appdir DIR  Running setup image's $APPDIR (provides packaging/ payloads + wrapped tools)
  --output FILE       Where to write the game AppImage
  --profile NAME      base (WiiCompiled) or retro-rewind (RetroRewind); sets default names
  --main-bin NAME     Binary/desktop base name (default: WiiCompiled or RetroRewind from --profile)
  --arch ARCH         x86_64 or aarch64 (default: uname -m)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --game-exe) game_exe=$2; shift 2 ;;
        --profile) profile=$2; shift 2 ;;
        --main-bin) main_bin=$2; shift 2 ;;
        --data-dir) data_dir=$2; shift 2 ;;
        --setup-appdir) setup_appdir=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --arch) arch=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "package-game-appimage.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$game_exe" ]] || { echo "package-game-appimage.sh: --game-exe is required" >&2; exit 1; }
[[ -n "$data_dir" ]] || { echo "package-game-appimage.sh: --data-dir is required" >&2; exit 1; }
[[ -n "$setup_appdir" ]] || { echo "package-game-appimage.sh: --setup-appdir is required" >&2; exit 1; }
[[ -n "$output" ]] || { echo "package-game-appimage.sh: --output is required" >&2; exit 1; }
case "$profile" in
    base) default_bin=WiiCompiled; desktop_name="WiiCompiled";;
    retro-rewind) default_bin=RetroRewind; desktop_name="RetroRewind";;
    *) echo "package-game-appimage.sh: --profile must be base or retro-rewind" >&2; exit 1 ;;
esac
main_bin=${main_bin:-$default_bin}
case "$arch" in
    x86_64|aarch64) ;;
    *) echo "package-game-appimage.sh: --arch must be x86_64 or aarch64" >&2; exit 1 ;;
esac
[[ -f "$game_exe" ]] || { echo "package-game-appimage.sh: game binary missing: $game_exe" >&2; exit 1; }
[[ -d "$data_dir" ]] || { echo "package-game-appimage.sh: data dir missing: $data_dir" >&2; exit 1; }

packaging="$setup_appdir/packaging"
quick_sharun="$packaging/quick-sharun.sh"
for f in "$quick_sharun" \
         "$packaging"/sharun+helper-libs-"$arch".tar \
         "$packaging"/appimagetool \
         "$packaging"/cross-libc-dlopen-"$arch".tar; do
    [[ -f "$f" ]] || {
        echo "package-game-appimage.sh: packaging payload missing: $f" >&2
        echo "The setup image was built without pre-seeded offline payloads;" >&2
        echo "rebuild it with a current Launcher/build-appimage.sh." >&2
        exit 1
    }
done
chmod +x "$quick_sharun" "$packaging/appimagetool"

# Game support files: required ones are fatal when absent (the game hard
# FATALs without them too - dsp ROM and WC24 bootstrap); the pipeline cache
# is a warm-start optimization aurora regenerates, so warn-only.
for f in dsp_coef.bin wii_bootstrap/shared2/wc24; do
    [[ -e "$data_dir/$f" ]] || { echo "package-game-appimage.sh: required game data missing: $data_dir/$f" >&2; exit 1; }
done
if [[ ! -f "$data_dir/initial_pipeline_cache.db" ]]; then
    echo "package-game-appimage.sh: WARNING: initial_pipeline_cache.db absent, game will cold-start pipelines" >&2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/wii-game-pack-XXXXXX")
trap 'rm -rf "$work"' EXIT
appdir="$work/AppDir"
mkdir -p "$appdir"

# Stage the exe under its FINAL runtime name (quick-sharun derives install
# names, strace matching and MAIN_BIN from basenames).
stage_bin="$work/stage-bin"
mkdir -p "$stage_bin"
cp "$game_exe" "$stage_bin/$main_bin"
chmod +x "$stage_bin/$main_bin"

# ldd shim over the setup image's own deployed linker: ldd IS `ld-linux
# --list`, and the bundled linker lists any closure correctly without
# executing anything. Placed FIRST on PATH so a missing/broken host ldd
# (musl systems often lack one) can never shadow it.
ld_linux=$(echo "$setup_appdir"/lib/ld-linux-* "$setup_appdir"/lib64/ld-linux-* 2>/dev/null | awk '{print $1}')
[[ -x "$ld_linux" ]] || { echo "package-game-appimage.sh: no deployed linker in $setup_appdir/lib" >&2; exit 1; }
mkdir -p "$work/shimbin"
cat > "$work/shimbin/ldd" <<EOF
#!/bin/sh
exec "$ld_linux" --list "\$@"
EOF
chmod +x "$work/shimbin/ldd"
export PATH="$work/shimbin:$setup_appdir/bin:$PATH"

deploy_args=("$stage_bin/$main_bin")
# libdbus is dlopened (never linked) with a graceful no-bus fallback, so no
#dep-walk would ever find it - but bundling it is what makes MPRIS music
# ducking work out of the box. Probe-only: absent host dbus just means the
# feature stays unavailable, exactly like an unpackaged build.
shopt -s nullglob
dbus_libs=(/usr/lib/libdbus-1.so* /usr/lib64/libdbus-1.so* /lib/libdbus-1.so* /lib64/libdbus-1.so*)
shopt -u nullglob
if [[ ${#dbus_libs[@]} -gt 0 ]]; then
    deploy_args+=("${dbus_libs[@]}")
else
    echo "package-game-appimage.sh: WARNING: no host libdbus found, MPRIS ducking will be unavailable" >&2
fi

echo "Deploying $main_bin with the setup image's pinned quick-sharun (offline)..."
export APPDIR="$appdir"
export ICON="$work/game.png"
export DESKTOP="$work/game.desktop"
export OUTNAME="$(basename "$output")"
export MAIN_BIN="$main_bin"
export STARTUPWMCLASS="$main_bin"
# vulkan-check diagnoses host driver issues at game launch; x86-64-v3-check
# warns early on CPUs that could never run these x86-64-v3 game binaries.
# Deliberately NOT included: self-updater (Wheel Wizard/setup own updates),
# USE_HOST_DRIVERS_EXPERIMENTAL (bundled mesa is required for games).
export ADD_HOOKS="vulkan-check.hook:x86-64-v3-check.hook"
export DEPLOY_VULKAN=1
export DEPLOY_PIPEWIRE=1
export DEPLOY_PULSE=1
# No strace: the link closure is fully known (linked, not dlopened, libs) and
# the game needs a display+GPU to run, which headless users lack. dlopened
# libs are covered explicitly above and via the DEPLOY_* switches.
export STRACE_MODE=0
# Keep symbols: crash-report symbolization and native stack traces matter for
# a beta game; upstream never stripped these binaries either.
export NO_STRIP=1
export DEPLOY_DATADIR=0
export DEPLOY_LOCALE=0
# Offline payloads, pre-seeded by build-appimage.sh (same bytes it verified).
export SHARUN_LINK="file://$packaging/sharun+helper-libs-$arch.tar"
export CROSS_LIBC_DLOPEN_LINK="file://$packaging/cross-libc-dlopen-$arch.tar"
export APPIMAGETOOL="$packaging/appimagetool"
export SKIP_INTEGRITY_CHECKS=1
# Paint-by-numbers icon: the game ships no icon asset; reuse the setup one
# from the running image when present, else a solid placeholder.
if [[ -f "$setup_appdir/wiicompiled-setup.png" ]]; then
    cp "$setup_appdir/wiicompiled-setup.png" "$ICON"
else
    python3 - "$ICON" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
row = b"\x00" + bytes([0x3A, 0x5F, 0x8F, 0xFF]) * 256
raw = row * 256
with open(path, "wb") as h:
    h.write(b"\x89PNG\r\n\x1a\n")
    h.write(chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 6, 0, 0, 0)))
    h.write(chunk(b"IDAT", zlib.compress(raw, 9)))
    h.write(chunk(b"IEND", b""))
PY
fi
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$desktop_name
Comment=Play $desktop_name natively on Linux (WiiCompiled)
Exec=$main_bin
Icon=$main_bin
Categories=Game;
Terminal=false
StartupNotify=true
StartupWMClass=$main_bin
EOF
mkdir -p "$(dirname "$output")"
OUTPATH="$(cd "$(dirname "$output")" && pwd)"
export OUTPATH
bash "$quick_sharun" "${deploy_args[@]}"

echo "Installing game data (relative symlinks beside the exe)..."
# quick-sharun never carries data trees, and the runtime resolves these three
# adjacent to the exe read-only (verified: dsp ROM, WC24 bootstrap seed,
# aurora pipeline recipe DB). Physical copies under share/game/, symlinks in
# bin/ satisfy is_regular_file/is_directory checks without code changes.
mkdir -p "$appdir/share/game"
cp -a "$data_dir/dsp_coef.bin" "$appdir/share/game/dsp_coef.bin"
cp -a "$data_dir/wii_bootstrap" "$appdir/share/game/wii_bootstrap"
if [[ -f "$data_dir/initial_pipeline_cache.db" ]]; then
    cp -a "$data_dir/initial_pipeline_cache.db" "$appdir/share/game/initial_pipeline_cache.db"
fi
ln -sfn ../share/game/dsp_coef.bin "$appdir/bin/dsp_coef.bin"
ln -sfn ../share/game/wii_bootstrap "$appdir/bin/wii_bootstrap"
if [[ -f "$appdir/share/game/initial_pipeline_cache.db" ]]; then
    ln -sfn ../share/game/initial_pipeline_cache.db "$appdir/bin/initial_pipeline_cache.db"
fi

echo "Regenerating sharun lib.path..."
"$appdir/sharun" -g

# Closure gate (best-effort readelf): every DT_NEEDED must resolve inside the
# image. readelf itself may be absent on user machines - then this gate warns
# instead of failing; --simple-test below is the mandatory gate (it only
# needs the image itself).
echo "Verifying game ELF closure..."
if command -v readelf >/dev/null 2>&1; then
    declare -A game_sonames=()
    while IFS= read -r lib; do
        game_sonames["${lib##*/}"]=1
        if [[ -L "$lib" ]]; then
            game_sonames["$(basename "$(readlink "$lib")")"]=1
        fi
    done < <(find "$appdir/lib" "$appdir/lib32" -name '*.so*' 2>/dev/null)
    closure_failed=0
    while IFS= read -r elf; do
        while IFS= read -r needed; do
            [[ -n "$needed" ]] || continue
            if [[ -z "${game_sonames[$needed]:-}" ]]; then
                case "$needed" in
                    ld-linux*.so*|ld-musl*.so*) continue;;
                esac
                echo "  UNRESOLVED DT_NEEDED: $elf needs $needed" >&2
                closure_failed=1
            fi
        done < <(readelf -d "$elf" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p')
    done < <(find "$appdir/bin" "$appdir/shared/bin" "$appdir/lib" -type f \
        -exec sh -c 'head -c 4 "$1" 2>/dev/null | grep -q "^.ELF"' _ {} \; -print 2>/dev/null)
    if [[ "$closure_failed" -ne 0 ]]; then
        echo "package-game-appimage.sh: error: game tree has unresolvable ELFs" >&2
        exit 1
    fi
else
    echo "WARNING: readelf not found, skipping static closure gate" >&2
fi

echo "Packaging the game AppImage (DwarFS + uruntime, offline)..."
bash "$quick_sharun" --make-appimage

echo "Running loader-error gate..."
bash "$quick_sharun" --simple-test "$OUTPATH/$OUTNAME"
echo "Game AppImage built: $OUTPATH/$OUTNAME"
