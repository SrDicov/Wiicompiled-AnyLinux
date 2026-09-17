#!/usr/bin/env bash
# Packages Launcher/WiiCompiled.Setup.Linux as a self-contained AnyLinux
# AppImage: a single file Wheel Wizard (or anyone else) can fetch and execute
# with no git clone, no `dotnet` install, and no `dolphin-tool` package
# required at all - on any Linux system: old glibc distros, musl-based ones
# (Alpine), and NixOS without any FHS wrapper, with no FUSE requirement.
#
# Method (see https://github.com/pkgforge-dev/Anylinux-AppImages - this script
# follows it 100%): EVERYTHING is bundled, including glibc and ld-linux, via
# quick-sharun. `sharun` IS the AppRun (hardlinked as bin/*, fixing
# /proc/self/exe); the bundled linker is invoked with --library-path, never
# LD_LIBRARY_PATH. $APPDIR itself is the install prefix - there is no usr/
# inside the image. The final image is DwarFS + uruntime (FUSE -> userns ->
# extract-to-TMPDIR fallback), so libfuse2 is NOT required to run it.
#
# What is bundled and why (same contract as before, new backend):
# - wiicompiled-setup + translator-cli, published as self-contained dotnet
#   binaries, plus `nodtool` (prebuilt MIT/Apache-2.0 CLI from encounter/nod,
#   see NodToolProvider.cs). The launcher is told about them so
#   local-build.sh/DiscTool.cs skip their from-source/download fallbacks.
# - A pruned native clang/lld/cmake/ninja toolchain (see
#   prepare-portable-tools.sh): the launcher passes --cc/--cxx/--fuse-ld/
#   --cmake/--ninja so local-build.sh never needs a system compiler, CMake or
#   Ninja. It still uses the host's X11/Vulkan/zlib link surface when linking
#   the final game binary on the user's machine (documented remaining host
#   surface, same as before this migration).
# - A precompiled aurora + third-party package (see Prepare-NativePrebuilt.sh):
#   the launcher passes --native-prebuilt-dir so local-build.sh never compiles
#   aurora-main from source at all (~43% of local build CPU time).
# - The host shell tools local-build.sh shells out to (bash, coreutils, awk,
#   grep, sed, findutils): bundled too, so the build works on minimal musl
#   systems (e.g. Alpine/busybox) with no extra packages installed.
# - libssl/libcrypto: downloaded payloads (Retro-WFC, nodtool fallback) use
#   HTTPS at end-user install time; they are dlopened lazily by .NET, so they
#   are deployed explicitly rather than relying on strace to catch them.
#
# Layout notes (quick-sharun wraps ELF binaries but does not relocate data
# trees, so this script does both): every bundled ELF goes through
# quick-sharun exactly once and is NEVER copied by hand; the toolchain's data
# files (clang resource dir, cmake Modules, libc++ archives), native-prebuilt/
# and the workspace snapshot are copied verbatim afterwards, and
# toolchain/bin/* are hardlinks to sharun dispatching by basename to the
# deployed real binaries in shared/bin/. Resource lookup keeps working
# because clang/cmake resolve resources relative to the invoked
# $CACHE/toolchain path (see the hook below).
#
# An AppImage mounts read-only, but local-build.sh writes generated/,
# native-build/, Assets/, etc. into the workspace it is given. So the
# 00-wiicompiled-workspace.hook (Launcher/appimage/, sourced by AppRun.sh on
# every launch before the main binary) copies the bundled workspace snapshot
# out to a writable cache directory on first run, and only ever re-syncs the
# bundled directories (runtime/, aurora-main/, projects/, local-build.sh) on
# a later run whose bundled version changed - generated/native-build/Assets/
# PulsarPacks live only in that writable cache and are never touched by the
# sync, so local-build.sh's own incremental caching survives across runs and
# across AppImage updates. translator/ is not part of this snapshot:
# bin/translator-cli never needs a writable copy. Neither native-prebuilt/
# nor the toolchain are copied into the cache either (large, read-only), but
# the hook re-points the $CACHE/toolchain and $CACHE/native-prebuilt symlinks
# at the current mount on every single launch: the mount path changes every
# run, and CMake bakes whatever compiler/tool path it is given directly into
# each build.ninja rule's command line, so referencing the mount straight
# would force a full rebuild on every single launch. The symlink keeps the
# path string stable while tracking the current mount underneath.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd "$script_dir/.." && pwd)
appimage_dir="$script_dir/appimage"

# Pinned quick-sharun: the script that implements the AnyLinux method. Pinned
# by commit AND sha256 (it pins its own sharun/appimagetool downloads
# internally the same way), so a silently-changed upstream file fails here
# instead of producing a subtly different image.
QUICK_SHARUN_COMMIT="5beb5c0ab6a53833b829adb8f7cd55e9b0c63632"
QUICK_SHARUN_SHA256="8471838e86f4dce73cc49bc7549105b3e4fc130c173cbece897b093b77383e7d"
QUICK_SHARUN_URL="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/${QUICK_SHARUN_COMMIT}/useful-tools/quick-sharun.sh"

# `uname -m` reports the *kernel's* architecture, which can differ from userspace - an aarch64
# kernel can run a 32-bit armhf userland (as shipped by 32-bit Raspberry Pi OS), same as an x86_64
# kernel can run an i686 one. What matters here is which userspace binaries (dotnet, the
# toolchain, the deployed glibc) will actually run, so this reads the ELF header of this script's
# own running bash interpreter - real userspace - rather than trusting the kernel's self-report.
# /proc/$$/exe (not /proc/self/exe: that would resolve inside the readlink subprocess below, to
# readlink itself, not to bash) is this shell's own PID. EI_CLASS (byte 4: 1=32-bit, 2=64-bit)
# and e_machine (bytes 18-19: 3=EM_386, 40=EM_ARM, 62=EM_X86_64, 183=EM_AARCH64) are read as plain
# little-endian bytes, which every real-world x86/ARM Linux userland uses; ELF's big-endian
# encoding is a non-issue here since no Linux distro ships a big-endian x86 or ARM userland.
elf_exe=$(readlink -f "/proc/$$/exe")
elf_class=$(od -An -t u1 -j 4 -N 1 "$elf_exe" | tr -d ' ')
elf_machine_lo=$(od -An -t u1 -j 18 -N 1 "$elf_exe" | tr -d ' ')
elf_machine_hi=$(od -An -t u1 -j 19 -N 1 "$elf_exe" | tr -d ' ')
elf_machine=$(( elf_machine_hi * 256 + elf_machine_lo ))

# Mirrors the host-architecture detection NodToolProvider.cs already does (RuntimeInformation.
# OSArchitecture) so this script's own dotnet RID and image-arch selection agree with the
# nodtool binary that same code path resolves below. local-build.sh needs no such mapping itself:
# it just drives the native CMake configure, which already accepts x86_64 or aarch64 natively
# (see runtime/CMakeLists.txt's CMAKE_SYSTEM_PROCESSOR check).
case "$elf_class:$elf_machine" in
    2:62)
        dotnet_rid=linux-x64
        image_arch=x86_64
        ;;
    2:183)
        dotnet_rid=linux-arm64
        image_arch=aarch64
        ;;
    *)
        echo "build-appimage.sh: unsupported userspace architecture (ELF class $elf_class, machine $elf_machine) - WiiCompiled requires a 64-bit x86_64 or aarch64 userland" >&2
        exit 1
        ;;
esac

output_dir="$workspace/Launcher/dist"
quick_sharun_override=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) output_dir=$2; shift 2 ;;
        --quick-sharun) quick_sharun_override=$2; shift 2 ;;
        -h|--help)
            echo "Usage: build-appimage.sh [--output-dir DIR] [--quick-sharun PATH]"
            echo ""
            echo "Builds an AnyLinux AppImage of the WiiCompiled setup tool. MUST run on"
            echo "Arch Linux (or set ALLOW_NON_ARCH_BUILD=1 to override at your own risk:"
            echo "a non-Arch glibc/layout produces an image that is NOT portable)."
            echo "Needs on PATH: dotnet (.NET 8 SDK), git, curl/wget, python3, patchelf,"
            echo "bash, and xvfb-run (xorg-server-xvfb) for the post-build test gates."
            exit 0
            ;;
        *) echo "build-appimage.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# The AnyLinux method is only valid when built on Arch: its glibc is newer
# than any target distro's (bundled glibc must be >= host glibc everywhere the
# image runs) and quick-sharun's LIB_DIR detection assumes the Arch layout
# (Fedora's /usr/lib 32-bit mix breaks it; Ubuntu's old glibc poisons it).
if [[ "${ALLOW_NON_ARCH_BUILD:-0}" != "1" ]] && ! grep -qi '^ID=\(arch.*\|artix\|endeavouros\)$' /etc/os-release 2>/dev/null; then
    echo "build-appimage.sh: error: AppImage builds MUST run on Arch Linux (see comment above)." >&2
    echo "Also accepted: Artix and EndeavourOS (same official repos/glibc). Deliberately NOT" >&2
    echo "accepted: Manjaro (stale glibc) and CachyOS (x86-64-v3/v4-optimized repos would bake" >&2
    echo "a CPU floor into every bundled library)." >&2
    echo "Set ALLOW_NON_ARCH_BUILD=1 to override (resulting image will likely NOT be portable)." >&2
    echo "--- /etc/os-release ID lines (for debugging this guard):" >&2
    grep -i '^ID' /etc/os-release >&2 || echo "(no /etc/os-release ID found)" >&2
    exit 1
fi

for dep in dotnet git python3 patchelf bash readelf; do
    command -v "$dep" >/dev/null 2>&1 || { echo "build-appimage.sh: error: required tool '$dep' not found on PATH" >&2; exit 1; }
done
# Advanced escape hatch: quick-sharun honors $APPIMAGETOOL as the packer
# binary (default: its own pinned download). Exported only if already set.
if [[ -n "${APPIMAGETOOL:-}" ]]; then
    export APPIMAGETOOL
fi
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "build-appimage.sh: error: need curl or wget on PATH" >&2; exit 1
fi

artifacts="$workspace/Launcher/artifacts/appimage-build"
appdir="$artifacts/AppDir"
rm -rf "$appdir"
mkdir -p "$appdir" "$artifacts"

echo "Fetching pinned quick-sharun ($QUICK_SHARUN_COMMIT)..."
quick_sharun="$artifacts/quick-sharun.sh"
if [[ -n "$quick_sharun_override" ]]; then
    cp "$quick_sharun_override" "$quick_sharun"
else
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$QUICK_SHARUN_URL" -o "$quick_sharun"
    else
        wget -qO "$quick_sharun" "$QUICK_SHARUN_URL"
    fi
fi
actual_sha=$(sha256sum "$quick_sharun" | awk '{print $1}')
if [[ "$actual_sha" != "$QUICK_SHARUN_SHA256" && -z "$quick_sharun_override" ]]; then
    echo "build-appimage.sh: error: quick-sharun sha256 mismatch: expected $QUICK_SHARUN_SHA256, got $actual_sha" >&2
    echo "Upstream file changed without a pin bump - update QUICK_SHARUN_COMMIT/SHA256 deliberately, never blindly." >&2
    exit 1
fi
chmod +x "$quick_sharun"

echo "Publishing the installer (self-contained $dotnet_rid)..."
publish_tmp="$artifacts/publish"
rm -rf "$publish_tmp"
dotnet publish "$workspace/Launcher/WiiCompiled.Setup.Linux" -c Release -r "$dotnet_rid" \
    --self-contained -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
    -o "$publish_tmp"

# Published as a self-contained binary too, so an AppImage user never needs a `dotnet` SDK on
# PATH at all - the hook tells local-build.sh about it via --translator-bin and it skips its own
# dotnet-build-from-source step entirely (see local-build.sh's translator resolution branch).
echo "Publishing the translator (self-contained $dotnet_rid)..."
translator_publish_tmp="$artifacts/publish-translator"
rm -rf "$translator_publish_tmp"
dotnet publish "$workspace/translator/src/Translator.Cli" -c Release -r "$dotnet_rid" \
    --self-contained -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
    -o "$translator_publish_tmp"

# Resolved via the shared WiiCompiled.Setup.Common.Cli helper (also used by Build-Installer.ps1 on
# Windows) rather than a second curl/version-pin copy here: it downloads and caches the same way
# NodToolProvider.cs always does (Launcher/artifacts/nodtool), so there is exactly one place that
# knows the nodtool version/URL/platform-asset mapping.
echo "Resolving nodtool..."
nodtool_path=$(dotnet run --project "$workspace/Launcher/WiiCompiled.Setup.Common.Cli" -c Release -- \
    --workspace "$workspace" | tail -n1)

echo "Preparing the portable clang/lld/cmake/ninja toolchain ($image_arch)..."
bash "$script_dir/prepare-portable-tools.sh" --arch "$image_arch"
toolchain_dir="$workspace/Launcher/artifacts/portable-tools/toolchain-$image_arch"

# Precompiled aurora + third-party package (see Prepare-NativePrebuilt.sh) so a user's own
# local-build.sh never has to compile aurora itself (~43% of local build CPU time). Re-harvesting
# recompiles the whole aurora/Crypto++ closure with the toolchain above, so this is skipped unless
# --print-fingerprint-only (a fast, build-free check) says the existing package no longer matches
# the current compiler/flags/aurora/third_party sources.
native_prebuilt_dir="$workspace/Launcher/artifacts/native-prebuilt-$image_arch"
echo "Checking whether the precompiled aurora + third-party package ($image_arch) is current..."
current_fingerprint=$(bash "$script_dir/Prepare-NativePrebuilt.sh" --arch "$image_arch" --print-fingerprint-only)
package_current=0
if [[ -f "$native_prebuilt_dir/provenance.json" ]]; then
    package_current=$(CURRENT_FINGERPRINT="$current_fingerprint" python3 - "$native_prebuilt_dir/provenance.json" <<'PY'
import json
import os
import sys

provenance = json.load(open(sys.argv[1], encoding="utf-8"))
current = dict(line.split("=", 1) for line in os.environ["CURRENT_FINGERPRINT"].splitlines() if line)
fields = {
    "compiler_sha256": "CompilerSha256",
    "flag_fingerprint": "FlagFingerprint",
    "aurora_fingerprint": "AuroraSourceFingerprint",
    "third_party_fingerprint": "ThirdPartySourceFingerprint",
}
print(1 if all(provenance.get(v) == current.get(k) for k, v in fields.items()) else 0)
PY
    )
fi
if [[ "$package_current" == "1" ]]; then
    echo "Native prebuilt package is current; reusing $native_prebuilt_dir"
else
    echo "Native prebuilt package is missing or stale; harvesting a fresh one (compiles aurora once, can take a while)..."
    bash "$script_dir/Prepare-NativePrebuilt.sh" --arch "$image_arch"
fi

# The harvested link closure must not contain absolute build-host paths: those
# would leak the packaging machine into every user's game link. Portable
# entries look like -lfoo, -lz or @PKG@ tokens.
echo "Auditing the native prebuilt package for leaked host paths..."
if grep -rEo '/(usr|opt|home|root|tmp)/[^" ]*' "$native_prebuilt_dir/native_prebuilt.cmake" 2>/dev/null | grep -v '^/usr$' | head -n 20 | grep -q .; then
    echo "build-appimage.sh: error: absolute host paths leaked into native_prebuilt.cmake:" >&2
    grep -rEo '/(usr|opt|home|root|tmp)/[^" ]*' "$native_prebuilt_dir/native_prebuilt.cmake" | head -n 20 >&2
    exit 1
fi

echo "Staging the bundled workspace snapshot..."
snapshot="$artifacts/snapshot"
rm -rf "$snapshot"
mkdir -p "$snapshot/workspace/Launcher"
for dir in runtime aurora-main projects; do
    cp -r "$workspace/$dir" "$snapshot/workspace/$dir"
done
# Mirrors Build-Installer.ps1's own staging exclusions exactly: aurora-main/extern/CMakeLists.txt
# is the real FetchContent driver and must ship, but any already-fetched dependency *subdirectory*
# a developer's local checkout accumulated under extern/ is stale/large build output, not a
# release input - only directories inside extern/ are stripped, never the file itself. runtime/build
# is a plain developer build directory.
find "$snapshot/workspace/aurora-main/extern" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
rm -rf "$snapshot/workspace/runtime/build"
# Size diet (Fase 3): never shipped to users - upstream tests, examples, docs,
# VCS metadata, and developer build leftovers.
rm -rf "$snapshot/workspace/aurora-main/tests" "$snapshot/workspace/aurora-main/examples" \
    "$snapshot/workspace/aurora-main/docs" "$snapshot/workspace/aurora-main/.git" \
    "$snapshot/workspace/runtime/tests" \
    "$snapshot/workspace"/runtime/cmake-build-* "$snapshot/workspace"/build* \
    "$snapshot/workspace"/.git
cp "$workspace/Launcher/local-build.sh" "$snapshot/workspace/Launcher/local-build.sh"

# The hook re-syncs runtime/aurora-main/projects/local-build.sh into the writable cache only when
# this changes, so it must change whenever any of those bundled paths actually did - a bare commit
# hash gets this wrong for an uncommitted change (verified directly: rebuilding after editing
# local-build.sh with no commit produced the same hash as the stale cache, so the launcher kept
# serving the old script and failed on a flag that didn't exist yet). `git status --porcelain`
# catches both modified tracked files and new untracked ones; appending a fresh timestamp when
# it's non-empty guarantees this never matches a previous build's stamp, forcing a resync every
# time the tree is dirty. A clean tree (a real tagged release) keeps the stable commit-hash
# behavior, so identical reruns of the same release AppImage don't resync needlessly.
if git -C "$workspace" rev-parse HEAD >/dev/null 2>&1; then
    version=$(git -C "$workspace" rev-parse HEAD)
    if [[ -n "$(git -C "$workspace" status --porcelain 2>/dev/null)" ]]; then
        version="$version-dirty-$(date -u +%s)"
    fi
    echo "$version" > "$snapshot/workspace/.bundle-version"
else
    date -u +%s > "$snapshot/workspace/.bundle-version"
fi

echo "Writing desktop entry and icon..."
# No WiiCompiled logo/icon asset exists anywhere in this repo yet. quick-sharun refuses to package
# without one, so this is a minimal solid-color placeholder - a one-line swap for real branding
# later (just replace the generated file with a real wiicompiled-setup.png before packaging).
icon_path="$artifacts/wiicompiled-setup.png"
python3 - "$icon_path" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))


width = height = 256
row = b"\x00" + bytes([0x3A, 0x5F, 0x8F, 0xFF]) * width  # filter byte + opaque blue-grey pixels
raw = row * height
ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
idat = zlib.compress(raw, 9)

with open(path, "wb") as handle:
    handle.write(b"\x89PNG\r\n\x1a\n")
    handle.write(chunk(b"IHDR", ihdr))
    handle.write(chunk(b"IDAT", idat))
    handle.write(chunk(b"IEND", b""))
PY

# --- AnyLinux deployment -------------------------------------------------
# Every bundled ELF goes through quick-sharun exactly once and is NEVER copied
# by hand (its dep-walk + glibc/ld-linux bundling is what makes the image run
# on old glibc, musl and NixOS). Data trees (toolchain resources, cmake
# modules, archives, snapshot, prebuilt) are copied verbatim afterwards.
echo "Collecting deployment inputs..."
# Stage the three mains under their FINAL runtime names first: quick-sharun
# derives install names, strace matching and MAIN_BIN from basenames, so the
# dotnet publish output names (WiiCompiled.Setup.Linux, Translator.Cli) must
# not leak into the image.
stage_bin="$artifacts/stage-bin"
rm -rf "$stage_bin"
mkdir -p "$stage_bin"
cp "$publish_tmp/WiiCompiled.Setup.Linux" "$stage_bin/wiicompiled-setup"
cp "$translator_publish_tmp/Translator.Cli" "$stage_bin/translator-cli"
cp "$nodtool_path" "$stage_bin/nodtool"
chmod +x "$stage_bin"/wiicompiled-setup "$stage_bin"/translator-cli "$stage_bin"/nodtool
deploy_args=()
deploy_args+=("$stage_bin/wiicompiled-setup")
deploy_args+=("$stage_bin/translator-cli")
deploy_args+=("$stage_bin/nodtool")

# libssl/libcrypto: .NET dlopens them lazily for HTTPS (Retro-WFC payload,
# nodtool fallback) at end-user install time, so LD_DEBUG strace of --help
# would never catch them - deploy explicitly. They come from the same Arch
# glibc world as everything else bundled, so they stay consistent.
shopt -s nullglob
ssl_libs=(/usr/lib/libssl.so* /usr/lib/libcrypto.so*)
shopt -u nullglob
if [[ ${#ssl_libs[@]} -eq 0 ]]; then
    echo "build-appimage.sh: error: no libssl/libcrypto found under /usr/lib (pacman -S openssl)" >&2
    exit 1
fi
deploy_args+=("${ssl_libs[@]}")

# Host shell tools local-build.sh shells out to (verified by auditing it):
# without these, minimal musl systems (Alpine/busybox, no bash) cannot build.
# Probed, not hardcoded: only present tools are passed (quick-sharun aborts on
# missing paths, so a hard list would break across hosts).
for tool in bash nproc awk gawk grep sed find sha256sum mkdir rm cp mv cat date cut head tail dirname readlink mktemp chmod sleep uname tr; do
    if tool_path=$(command -v "$tool" 2>/dev/null); then
        # resolve chains like awk -> gawk once; quick-sharun handles the rest
        deploy_args+=("$tool_path")
    fi
done

# Toolchain binaries by their stable contract names from
# prepare-portable-tools.sh (bin/ holds symlinks like clang -> clang-22;
# passed unresolved on purpose - quick-sharun registers every name in the
# chain, so dispatch by any of them works later).
for tool in clang clang++ lld ld.lld llvm-ar llvm-ranlib cmake ninja; do
    if [[ ! -e "$toolchain_dir/bin/$tool" ]]; then
        echo "build-appimage.sh: error: toolchain binary missing: $toolchain_dir/bin/$tool" >&2
        exit 1
    fi
    deploy_args+=("$toolchain_dir/bin/$tool")
done

# Preflight (Fase 0 inventory, automated): every planned ELF must resolve its
# full closure on THIS host - a missing library here means a missing system
# package (e.g. libxml2 for clang), and quick-sharun would abort later with a
# worse error. Fails fast with the exact file to fix.
echo "Preflight: verifying ELF closure of all deployment inputs..."
preflight_failed=0
seen_arg=""
for arg in "${deploy_args[@]}"; do
    [[ -e "$arg" ]] || { echo "  MISSING INPUT: $arg" >&2; preflight_failed=1; continue; }
    case "$seen_arg" in
        *"|$arg|"*) continue;;
    esac
    seen_arg="$seen_arg|$arg|"
    if [[ "$(head -c 4 "$arg" 2>/dev/null)" != $'\x7fELF' ]]; then
        continue
    fi
    case "$arg" in
        *.so*) continue;; # shared objects resolve their own deps at load; walked via their parents
    esac
    missing=$(ldd "$arg" 2>/dev/null | grep 'not found' || true)
    if [[ -n "$missing" ]]; then
        echo "  $arg is missing libraries:" >&2
        echo "$missing" >&2
        preflight_failed=1
    fi
done
if [[ "$preflight_failed" -ne 0 ]]; then
    echo "build-appimage.sh: error: preflight failed - install the owning system packages first" >&2
    exit 1
fi

echo "Deploying with quick-sharun (this bundles glibc + ld-linux + deps)..."
export APPDIR="$appdir"
export ICON="$icon_path"
export DESKTOP="$appimage_dir/wiicompiled-setup.desktop"
export OUTPATH="$output_dir"
export OUTNAME="WiiCompiled-Setup-$image_arch.AppImage"
export MAIN_BIN="wiicompiled-setup"
export STARTUPWMCLASS="WiiCompiled-Setup"
# x86-64-v3-check warns early on CPUs that could never run the game (x86_64
# game binaries target x86-64-v3 with a baseline-ISA abort guard). Deliberately
# NOT included: self-updater (Wheel Wizard owns updates), fix-namespaces
# (no Chromium/bwrap here), USE_HOST_DRIVERS_EXPERIMENTAL (Qt/GTK-only,
# forbidden for Vulkan-hard games like this one).
export ADD_HOOKS="x86-64-v3-check.hook"
# Strace only the mains (with --help so they exit fast): tracing every
# toolchain binary would burn ~5s each for zero gain - their closure is fully
# linked (ldd-visible), while the mains dlopen (coreclr extraction, OpenSSL).
export STRACE_BINARY="wiicompiled-setup translator-cli nodtool bash"
export STRACE_FLAGS="--help"
export STRACE_TIME=5
# .NET single-file apphosts + the toolchain must keep their bytes intact.
export NO_STRIP=1
# No i18n anywhere in this image (.NET runs invariant globalization, the rest
# is clang/cmake/ninja + shell tools): skip the locale copy entirely instead
# of copying + debloating it. glibc gconv data (lib/gconv, a different path)
# is unaffected and still deploys.
export DEPLOY_LOCALE=0
mkdir -p "$OUTPATH"
bash "$quick_sharun" "${deploy_args[@]}"

echo "Installing verbatim data trees..."
# Toolchain data files quick-sharun never carries (it only deploys ELFs):
# clang's resource dir (builtin headers, compiler-rt), cmake's Modules +
# Templates (found relative to the binary - see hook comment), libc++/abi/
# unwind archives + shared objects, and the license file.
mkdir -p "$appdir/toolchain"
for sub in lib include share; do
    if [[ -d "$toolchain_dir/$sub" ]]; then
        cp -a "$toolchain_dir/$sub" "$appdir/toolchain/$sub"
    fi
done
cp -a "$toolchain_dir"/LICENSE* "$appdir/toolchain/" 2>/dev/null || true
# toolchain/bin/* become hardlinks to sharun dispatching by basename to the
# real deployed binaries in shared/bin/ (registered under every chain name in
# the previous step). Invoked through the stable $CACHE/toolchain symlink, so
# clang/cmake keep resolving their ../lib and ../share resource dirs.
mkdir -p "$appdir/toolchain/bin"
for tool in clang clang++ lld ld.lld llvm-ar llvm-ranlib cmake ninja; do
    ln -f "$appdir/sharun" "$appdir/toolchain/bin/$tool"
done

mkdir -p "$appdir/native-prebuilt"
cp -a "$native_prebuilt_dir/." "$appdir/native-prebuilt/"

mkdir -p "$appdir/workspace/Launcher"
for dir in runtime aurora-main projects; do
    cp -r "$snapshot/workspace/$dir" "$appdir/workspace/$dir"
done
cp "$snapshot/workspace/Launcher/local-build.sh" "$appdir/workspace/Launcher/local-build.sh"
cp "$snapshot/workspace/.bundle-version" "$appdir/workspace/.bundle-version"

echo "Installing the workspace-cache hook..."
cp "$appimage_dir/00-wiicompiled-workspace.hook" "$appdir/bin/00-wiicompiled-workspace.hook"

echo "Regenerating sharun lib.path..."
"$appdir/sharun" -g

# Post-deploy closure gates: the exact properties that make this image
# AnyLinux, checked against the DEPLOYED tree (never the host, so a
# host-shadowing false-pass is impossible).
echo "Verifying deployed ELF closure..."
# Gate 1: every DT_NEEDED SONAME of every deployed ELF exists somewhere under
# the deployed lib dirs (readelf never executes anything, so this is safe on
# any file).
declare -A deployed_sonames=()
while IFS= read -r lib; do
    deployed_sonames["${lib##*/}"]=1
    # versioned .so files are usually reached through unversioned symlinks -
    # index the link targets too (libssl.so -> libssl.so.3).
    if [[ -L "$lib" ]]; then
        deployed_sonames["$(basename "$(readlink "$lib")")"]=1
    fi
done < <(find "$appdir/lib" "$appdir/lib32" -name '*.so*' 2>/dev/null)
closure_failed=0
while IFS= read -r elf; do
    while IFS= read -r needed; do
        [[ -n "$needed" ]] || continue
        if [[ -z "${deployed_sonames[$needed]:-}" ]]; then
            # The interpreter itself (ld-linux) lives beside sharun, not in
            # lib/ - anything else missing is a real break.
            case "$needed" in
                ld-linux*.so*|ld-musl*.so*) continue;;
            esac
            echo "  UNRESOLVED DT_NEEDED: $elf needs $needed" >&2
            closure_failed=1
        fi
    done < <(readelf -d "$elf" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p')
done < <(find "$appdir/bin" "$appdir/shared/bin" "$appdir/lib" "$appdir/toolchain/bin" -type f \
    -exec sh -c 'head -c 4 "$1" 2>/dev/null | grep -q "^.ELF"' _ {} \; -print 2>/dev/null)
if [[ "$closure_failed" -ne 0 ]]; then
    echo "build-appimage.sh: error: deployed tree has unresolvable ELFs" >&2
    exit 1
fi
# Gate 2: every wrapped entry point actually starts under the deployed tree.
# Same loader-error signatures quick-sharun's own --simple-test uses.
gate_run() {
    local out
    out=$("$1" "$2" 2>&1) || true
    case "$out" in
        *'error while loading shared libraries'*|*'symbol lookup error'*|*'cannot open shared object file'*)
            echo "  LOADER FAILURE: $1 $2" >&2
            echo "$out" >&2
            return 1
            ;;
    esac
    return 0
}
gate_failed=0
gate_run "$appdir/bin/wiicompiled-setup" "--version" || gate_failed=1
gate_run "$appdir/bin/translator-cli" "--help" || gate_failed=1
gate_run "$appdir/bin/nodtool" "--help" || gate_failed=1
gate_run "$appdir/bin/bash" "--version" || gate_failed=1
if [[ "$gate_failed" -ne 0 ]]; then
    echo "build-appimage.sh: error: deployed entry points fail to start" >&2
    exit 1
fi

# Toolchain smoke test through stable-symlink paths (mirrors exactly what the
# hook hands local-build.sh: tools addressed via a symlink, never the mount).
echo "Smoke-testing the bundled toolchain..."
smoke="$artifacts/smoke"
rm -rf "$smoke"
mkdir -p "$smoke/cache"
ln -sfn "$appdir/toolchain" "$smoke/cache/toolchain"
"$smoke/cache/toolchain/bin/clang" --version | head -n 1
cat > "$smoke/t.cpp" <<'EOF'
#include <vector>
#include <cstdio>
int main() {
    std::vector<int> v{1, 2, 3};
    int sum = 0;
    for (int x : v) sum += x;
    std::printf("sum=%d\n", sum);
    return sum == 6 ? 0 : 1;
}
EOF
"$smoke/cache/toolchain/bin/clang++" -std=c++20 -fuse-ld=lld "$smoke/t.cpp" -o "$smoke/t"
"$smoke/t"
cat > "$smoke/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(smoke CXX)
add_executable(smoke t.cpp)
EOF
"$smoke/cache/toolchain/bin/cmake" -S "$smoke" -B "$smoke/build" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$smoke/cache/toolchain/bin/ninja" \
    -DCMAKE_CXX_COMPILER="$smoke/cache/toolchain/bin/clang++" >/dev/null
"$smoke/cache/toolchain/bin/cmake" --build "$smoke/build" >/dev/null
"$smoke/build/smoke"

echo "Packaging the AppImage (DwarFS + uruntime)..."
bash "$quick_sharun" --make-appimage

built="$output_dir/WiiCompiled-Setup-$image_arch.AppImage"
echo "Running post-build test gate..."
# --simple-test (not --test): --test's model is a long-running GUI that must
# survive 12s, but wiicompiled-setup is a CLI that exits immediately by
# design - --simple-test runs it and fails on loader errors
# (symbol lookup error / error while loading shared libraries), which is
# exactly the AnyLinux property under test here.
bash "$quick_sharun" --simple-test "$built"
echo "Built: $built"
