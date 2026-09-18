#!/usr/bin/env bash
# Prepares a self-contained native-Linux build toolchain bundled into the AppImage by
# build-appimage.sh, so a user needs no `clang`/`cmake`/`ninja` of their own to build the
# translated game (mirrors why Windows bundles llvm-mingw + CMake + Ninja via
# Prepare-PortableTools.ps1 - this is that script's Linux counterpart, for the same reason).
#
# clang/lld/llvm-ar: pruned from the official llvm.org GitHub release tarball (NOT llvm-mingw -
# that project targets Windows/mingw, never native Linux) down to just what's needed to compile
# and link: clang, lld, llvm-ar, the clang resource dir (builtin headers + compiler-rt), and
# libc++/libc++abi/libunwind (so the toolchain never has to fall back to the host's system
# libstdc++ headers). The raw release is ~1.9 GiB per arch (every LLVM backend, mlir, flang, lldb,
# docs, tests); pruned it is ~500 MiB uncompressed / ~100 MiB compressed, verified against a real
# build of this project.
#
# cmake: pruned from the official Kitware GitHub release tarball down to bin/cmake (not
# ccmake/cmake-gui/cpack/ctest, which local-build.sh never invokes) plus the Modules/Templates
# CMake needs at runtime (found relative to bin/cmake via CMAKE_ROOT auto-detection - Help/doc/man/
# the desktop-integration files under share/ are documentation/GUI-only and dropped). Verified with
# a real configure+build using the pruned cmake+ninja+clang together.
#
# ninja: the official ninja-build GitHub release zip, used as-is - it is already a single small
# (~130 KiB compressed) static-ish binary with nothing to prune.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd "$script_dir/.." && pwd)

llvm_version=22.1.8
cmake_version=4.3.3
ninja_version=1.13.2
destination="$script_dir/artifacts/portable-tools"
arch=""

usage() {
    cat <<'EOF'
Usage: prepare-portable-tools.sh --arch {x86_64|aarch64} [--destination DIR]

  --arch ARCH          Target architecture (required)
  --destination DIR     Where the toolchain is written, as DIR/toolchain-ARCH
                        (default: Launcher/artifacts/portable-tools)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) arch=$2; shift 2 ;;
        --destination) destination=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "prepare-portable-tools.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

case "$arch" in
    x86_64) llvm_release_arch=X64; target_triple=x86_64-unknown-linux-gnu
            llvm_release_sha256=fccecb1906e7ddf5ec040aec5b646b650e2daaafa4423b41341c4717db5bdec0
            cmake_release_arch=x86_64
            cmake_sha256=927b2368a946c37269c3a66225ab00544e756459cdd0b5d0da438694fb9ff802
            ninja_asset=ninja-linux.zip
            ninja_sha256=5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6 ;;
    aarch64) llvm_release_arch=ARM64; target_triple=aarch64-unknown-linux-gnu
            llvm_release_sha256=d431eff9f064c86ee7c4c94af570a8f74fcccd1f74c6f0da3af32ce34a1e1b05
            cmake_release_arch=aarch64
            cmake_sha256=9ea38356dbd3e32e51029a3e09a0f2f8e117ef4fbcaad7a21ffb36409bbd5cb4
            ninja_asset=ninja-linux-aarch64.zip
            ninja_sha256=fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc ;;
    *) echo "prepare-portable-tools.sh: --arch must be x86_64 or aarch64" >&2; usage; exit 1 ;;
esac

destination=$(mkdir -p "$destination" && cd "$destination" && pwd)
toolchain_dir="$destination/toolchain-$arch"
downloads="$script_dir/artifacts/downloads"
mkdir -p "$downloads"

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

download_verified() {
    # $1 = destination path, $2 = URL, $3 = expected sha256
    local dest=$1 url=$2 expected=$3
    if [[ -f "$dest" ]] && [[ "$(sha256_of "$dest")" == "$expected" ]]; then return; fi
    echo "prepare-portable-tools.sh: downloading $(basename "$dest")..."
    local tmp="$dest.partial"
    rm -f "$tmp"
    curl -fL --progress-bar -o "$tmp" "$url"
    local actual
    actual=$(sha256_of "$tmp")
    if [[ "$actual" != "$expected" ]]; then
        echo "prepare-portable-tools.sh: $(basename "$dest") hash mismatch: expected $expected, got $actual" >&2
        rm -f "$tmp"
        exit 1
    fi
    mv "$tmp" "$dest"
}

if [[ -x "$toolchain_dir/bin/clang" && -x "$toolchain_dir/bin/ninja" && -x "$toolchain_dir/bin/cmake" ]]; then
    echo "prepare-portable-tools.sh: reusing existing toolchain at $toolchain_dir"
    exit 0
fi

work="$destination/.building-toolchain-$arch"
rm -rf "$work"
mkdir -p "$work/bin" "$work/lib/$target_triple" "$work/include/$target_triple/c++/v1"

# --- clang/lld/llvm-ar, pruned from the official LLVM release ---
# built from PR https://github.com/llvm/llvm-project/pull/222821 on official LLVM Github Actions Runner
# only switch to an official stable LLVM release again once:
# - this PR has merged https://github.com/llvm/llvm-project/pull/221365 and been backported to LLVM stable branch
# - this bug has been fixed with a workaround in the Wiicompiled translator https://github.com/patchzyy/Wiicompiled/issues/208 or in LLVM and been backported to LLVM stable branch
llvm_archive_name="LLVM-PR222821-5ae1c7c43a11b4cdc5ce4dd483c28357bab7dae2-Linux-$llvm_release_arch.tar.xz"
llvm_archive="$downloads/$llvm_archive_name"
download_verified "$llvm_archive" \
    "https://github.com/theofficialgman/llvm-project/releases/download/llvmorg-22.1.8-patched/$llvm_archive_name" \
    "$llvm_release_sha256"

extract_root="$script_dir/artifacts/.extract-clang-$arch"
rm -rf "$extract_root"
mkdir -p "$extract_root"
echo "prepare-portable-tools.sh: extracting $llvm_archive_name (this is the full ~1.9 GiB release; only a fraction is kept)..."
tar -xf "$llvm_archive" -C "$extract_root"
src="$extract_root/${llvm_archive_name%.tar.xz}"
[[ -d "$src" ]] || { echo "prepare-portable-tools.sh: unexpected archive layout, expected $src" >&2; exit 1; }

echo "prepare-portable-tools.sh: pruning to the minimal compile+link toolchain..."

# clang: the real driver executable plus the clang/clang++ symlinks CMake/local-build.sh invoke.
# Stripped: debug symbols are dead weight for a bundled compiler nobody will debug.
cp -a "$src/bin/clang-22" "$work/bin/"
strip "$work/bin/clang-22"
ln -s clang-22 "$work/bin/clang"
ln -s clang "$work/bin/clang++"

# lld: linked via -fuse-ld=lld, which clang resolves by looking for ld.lld next to itself first -
# see local-build.sh's --fuse-ld option.
cp -a "$src/bin/lld" "$work/bin/"
strip "$work/bin/lld"
ln -s lld "$work/bin/ld.lld"

# llvm-ar/llvm-ranlib: CMake's archiver for the many static libraries this project builds
# (aurora, Crypto++, SDL3, Dawn's dependency closure, the translated game shards).
cp -a "$src/bin/llvm-ar" "$work/bin/"
strip "$work/bin/llvm-ar"
ln -s llvm-ar "$work/bin/llvm-ranlib"

# Clang's resource directory: builtin headers (stddef.h, immintrin.h, ...) and compiler-rt
# (builtins, sanitizer runtimes). `clang -print-resource-dir` must find this at lib/clang/<ver>/.
cp -a "$src/lib/clang" "$work/lib/"

# libc++/libc++abi/libunwind: so this toolchain never has to fall back to whatever libstdc++ the
# host distro happens to have installed. Not the default yet (local-build.sh still resolves the
# system libstdc++ unless -stdlib=libc++ is passed), but bundled so that option exists.
cp -a "$src/include/c++" "$work/include/"
cp -a "$src/include/$target_triple/c++/v1/__config_site" "$work/include/$target_triple/c++/v1/"
cp -a "$src/lib/$target_triple"/libc++.a "$src/lib/$target_triple"/libc++abi.a "$src/lib/$target_triple"/libunwind.a "$work/lib/$target_triple/"
cp -a "$src/lib/$target_triple"/libc++.so* "$src/lib/$target_triple"/libc++abi.so* "$src/lib/$target_triple"/libunwind.so* "$work/lib/$target_triple/"

rm -rf "$extract_root"

# --- GCC runtime + C library startup files and headers (the musl/Void fix) ---
# clang locates libgcc/crt*.o through its GCC-installation scan, which looks
# relative to the driver (build-appimage.sh stages these at lib/gcc/<triple>/
# <ver>/ beside bin/, so zero extra flags are needed). The LLVM tarball does
# not ship them and dependency walks never see them (linker inputs, never
# DT_NEEDED), so without this the toolchain silently consumes the HOST's
# files: correct on glibc distros by accident ("cannot open crtbeginS.o" plus
# musl-flavored crt1.o/libstdc++ anywhere else). Harvested from the build
# host's own gcc+glibc - the same versions everything else in the image is
# built against - so links are hermetic. Verified file-by-file on a real
# musl/Void machine (crt discovery, C + C++ try-compile, linked, ran).
# The C library + libstdc++ HEADERS ride along under include/ (consumed via
# an explicit -isystem derived from --cc in local-build.sh: the host
# /usr/include otherwise wins, and musl headers fail with __GLIBC_PREREQ
# errors). Everything mirrors gcc's own layout, so no -B/--sysroot is needed.
echo "prepare-portable-tools.sh: harvesting GCC runtime + C library files..."
command -v gcc >/dev/null || { echo "prepare-portable-tools.sh: error: host gcc is required for the runtime harvest" >&2; exit 1; }
command -v pacman >/dev/null || { echo "prepare-portable-tools.sh: error: pacman is required for the header harvest (Arch build host)" >&2; exit 1; }
gcc_machine=$(gcc -dumpmachine)
gcc_ver=$(gcc -dumpversion)
gcc_libdir=$(dirname "$(gcc -print-file-name=crtbeginS.o)")
[[ -f "$gcc_libdir/crtbeginS.o" ]] || { echo "prepare-portable-tools.sh: error: host gcc has no crtbeginS.o ($gcc_libdir)" >&2; exit 1; }
gcc_install_dir="$work/lib/gcc/$gcc_machine/$gcc_ver"
mkdir -p "$gcc_install_dir"
for _f in crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o libgcc.a libgcc_eh.a libgcov.a; do
    [[ -f "$gcc_libdir/$_f" ]] || { echo "prepare-portable-tools.sh: error: host gcc file missing: $gcc_libdir/$_f" >&2; exit 1; }
    cp -a "$gcc_libdir/$_f" "$gcc_install_dir/"
done
# libgcc_s.so is a tiny portable GROUP() script already (relative names only -
# verified, no absolute host paths), so it copies verbatim; its target
# libgcc_s.so.1 rides along dereferenced so -lgcc_s never reaches the host.
# (This exact miss broke the self-test below the moment the harvest made the
# driver prefer this install over the host's: only ONE gcc install is ever
# selected, so every file the link needs must be here.)
_gcc_s_script=$(gcc -print-file-name=libgcc_s.so)
[[ -f "$_gcc_s_script" ]] || { echo "prepare-portable-tools.sh: error: host has no libgcc_s.so" >&2; exit 1; }
# Dereferenced on purpose: on some targets this is a symlink (Arch x86_64: a
# portable GROUP script, copied verbatim just the same), and what -lgcc_s
# needs is a file named exactly libgcc_s.so with usable content.
cp -L "$_gcc_s_script" "$gcc_install_dir/libgcc_s.so"
_gcc_s1=$(gcc -print-file-name=libgcc_s.so.1)
[[ -f "$_gcc_s1" ]] || { echo "prepare-portable-tools.sh: error: host has no libgcc_s.so.1" >&2; exit 1; }
cp -L "$_gcc_s1" "$gcc_install_dir/libgcc_s.so.1"
# gcc's own include dir (ISA intrinsics etc. not in clang's resource dir):
# validated here but merged into include/ AFTER the glibc harvest below, never
# inside lib/gcc/<triple>/<ver>/ - a present <gccdir>/include hijacks clang's
# C++ header discovery (it stops looking for the c++/<ver> tree elsewhere and
# dies with 'vector not found'; reproduced + verified). Merge order matters:
# gcc-include goes last so its limits.h/stdint.h wrappers win over glibc's,
# exactly matching a native install's search order.
[[ -d "$gcc_libdir/include" ]] || { echo "prepare-portable-tools.sh: error: host gcc has no include dir" >&2; exit 1; }
[[ -n "$(ls -A "$gcc_libdir/include")" ]] || { echo "prepare-portable-tools.sh: error: host gcc include dir is empty" >&2; exit 1; }
_gcc_includedir="$gcc_libdir/include"
# C library startup objects + nonshared archive, from the build host's glibc.
glibc_libdir=$(dirname "$(cc -print-file-name=crt1.o)")
for _f in crt1.o crti.o crtn.o Scrt1.o rcrt1.o Mcrt1.o gcrt1.o libc_nonshared.a; do
    [[ -f "$glibc_libdir/$_f" ]] || { echo "prepare-portable-tools.sh: error: host glibc file missing: $glibc_libdir/$_f" >&2; exit 1; }
    cp -a "$glibc_libdir/$_f" "$gcc_install_dir/"
done
# libc.so.6 + the dynamic loader: byte-identical to what quick-sharun deploys
# into the image's lib/ - these copies only give the LINKER a first-hit
# search dir (DwarFS dedups identical content, so they cost ~nothing).
_ld_name=$(basename "$(ls /usr/lib/ld-linux* /lib/ld-linux* /lib64/ld-linux* 2>/dev/null | head -1)")
[[ -n "$_ld_name" ]] || { echo "prepare-portable-tools.sh: error: no ld-linux on the build host" >&2; exit 1; }
for _f in libc.so.6 "$_ld_name"; do
    _src=$(cc -print-file-name="$_f")
    [[ -f "$_src" ]] || { echo "prepare-portable-tools.sh: error: host file missing for $_f" >&2; exit 1; }
    cp -L "$_src" "$gcc_install_dir/"
done
# libstdc++.so.6 (derefenced copy + soname/dev symlinks, same layout as any
# gcc install - the loose .so keeps -lstdc++ off the host's files).
_stdcxx_link=$(g++ -print-file-name=libstdc++.so)
[[ -e "$_stdcxx_link" ]] || { echo "prepare-portable-tools.sh: error: host has no libstdc++.so" >&2; exit 1; }
_stdcxx_real=$(readlink -f "$_stdcxx_link")
_stdcxx_soname=$(basename "$_stdcxx_real" | sed 's/\(\.so\.[0-9][0-9]*\).*/\1/')
cp -a "$_stdcxx_real" "$gcc_install_dir/"
# Guarded: if the distro ever ships the library literally under its soname,
# the link below would replace the real file with a self-loop.
if [[ "$(basename "$_stdcxx_real")" != "$_stdcxx_soname" ]]; then
    ln -sfn "$(basename "$_stdcxx_real")" "$gcc_install_dir/$_stdcxx_soname"
fi
ln -sfn "$_stdcxx_soname" "$gcc_install_dir/libstdc++.so"
# Portable libc.so link script: the distro's /usr/lib/libc.so GROUP()s
# ABSOLUTE host paths (/usr/lib/libc.so.6 ...) which would leak the build
# host (or worse, a musl host's files) into every link. These bare names
# resolve through the same search dirs that found this script.
case "$arch" in
    x86_64) _elf_fmt=elf64-x86-64;;
    aarch64) _elf_fmt=elf64-littleaarch64;;
esac
printf '/* Portable libc link script (no absolute host paths; resolved via library search dirs) */\nOUTPUT_FORMAT(%s)\nGROUP ( libc.so.6 libc_nonshared.a AS_NEEDED ( %s ) )\n' \
    "$_elf_fmt" "$_ld_name" > "$gcc_install_dir/libc.so"
# Headers: exact file lists from the Arch glibc + kernel-header packages
# (never a blind /usr/include copy - that would drag in LLVM/host-only
# headers). Merges under include/ beside the libc++ tree above (c++/v1/
# libc++ vs c++/<ver>/ libstdc++ share the parent without colliding).
pacman -Ql glibc linux-api-headers 2>/dev/null | awk '{print $2}' | grep '^/usr/include/' > "$work/.header-list" || {
    echo "prepare-portable-tools.sh: error: cannot list glibc/linux-api-headers files" >&2; exit 1; }
[[ -s "$work/.header-list" ]] || { echo "prepare-portable-tools.sh: error: empty glibc header list" >&2; exit 1; }
tar -cf - -C / --no-recursion --files-from="$work/.header-list" 2>/dev/null | tar -xf - -C "$work/include" --strip-components=2
rm -f "$work/.header-list"
[[ -f "$work/include/features.h" && -f "$work/include/stdio.h" && -f "$work/include/sys/cdefs.h" ]] || {
    echo "prepare-portable-tools.sh: error: glibc header harvest looks wrong (no features.h/stdio.h)" >&2; exit 1; }
# libstdc++ headers (version dir matches gcc -dumpversion on Arch).
[[ -d "/usr/include/c++/$gcc_ver" ]] || { echo "prepare-portable-tools.sh: error: no libstdc++ headers for gcc $gcc_ver" >&2; exit 1; }
cp -a "/usr/include/c++/$gcc_ver" "$work/include/c++/"
[[ -f "$work/include/c++/$gcc_ver/vector" ]] || { echo "prepare-portable-tools.sh: error: libstdc++ header copy failed" >&2; exit 1; }
# gcc's own include dir merges last (see comment above): its wrappers win,
# matching native search order. Verified non-empty above.
cp -a "$_gcc_includedir/." "$work/include/"
[[ -f "$work/include/iso646.h" ]] || { echo "prepare-portable-tools.sh: error: gcc include merge failed" >&2; exit 1; }
echo "prepare-portable-tools.sh: GCC runtime harvest done ($(du -sh "$gcc_install_dir" | cut -f1) + $(du -sh "$work/include" | cut -f1) headers)."

# --- cmake, pruned from the official Kitware release ---

cmake_share_version=${cmake_version%.*}
cmake_archive_name="cmake-$cmake_version-linux-$cmake_release_arch.tar.gz"
cmake_archive="$downloads/$cmake_archive_name"
download_verified "$cmake_archive" \
    "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$cmake_archive_name" \
    "$cmake_sha256"

cmake_extract_root="$script_dir/artifacts/.extract-cmake-$arch"
rm -rf "$cmake_extract_root"
mkdir -p "$cmake_extract_root"
echo "prepare-portable-tools.sh: extracting $cmake_archive_name..."
tar -xzf "$cmake_archive" -C "$cmake_extract_root"

cmake_src="$cmake_extract_root/${cmake_archive_name%.tar.gz}"
[[ -d "$cmake_src" ]] || { echo "prepare-portable-tools.sh: unexpected archive layout, expected $cmake_src" >&2; exit 1; }

mkdir -p "$work/share/cmake-$cmake_share_version"
cp -a "$cmake_src/bin/cmake" "$work/bin/"
cp -a "$cmake_src/share/cmake-$cmake_share_version/Modules" "$cmake_src/share/cmake-$cmake_share_version/Templates" \
    "$work/share/cmake-$cmake_share_version/"
rm -rf "$cmake_extract_root"

# --- ninja, used as-is ---

ninja_archive="$downloads/ninja-$ninja_version-$arch.zip"
download_verified "$ninja_archive" \
    "https://github.com/ninja-build/ninja/releases/download/v$ninja_version/$ninja_asset" \
    "$ninja_sha256"
echo "prepare-portable-tools.sh: staging ninja $ninja_version..."
unzip -oq "$ninja_archive" -d "$work/bin"
chmod +x "$work/bin/ninja"

cat > "$work/LICENSE.txt" <<EOF
Portable build tools bundled by WiiCompiled

clang/lld/llvm-ar $llvm_version (pruned from the official LLVM release for Linux/$llvm_release_arch)
  https://github.com/llvm/llvm-project/releases/tag/llvmorg-$llvm_version
  Apache License v2.0 with LLVM Exceptions:
  https://github.com/llvm/llvm-project/blob/llvmorg-$llvm_version/LICENSE.TXT

CMake $cmake_version
  https://github.com/Kitware/CMake
  BSD 3-Clause License

Ninja $ninja_version
  https://github.com/ninja-build/ninja
  Apache License 2.0
EOF

echo "prepare-portable-tools.sh: testing the toolchain..."
echo "prepare-portable-tools.sh: build-host gcc: $(gcc -dumpversion) $(gcc -dumpmachine)"
echo "prepare-portable-tools.sh: clang resolves crtbeginS.o to: $("$work/bin/clang" -print-file-name=crtbeginS.o)"
echo "prepare-portable-tools.sh: clang resolves libc.so.6 to: $("$work/bin/clang" -print-file-name=libc.so.6)"
diag_on_failure() {
    # $1 = what failed. Dumps driver discovery state so a header/link miss is
    # debuggable from the log alone (no second CI cycle for forensics).
    echo "prepare-portable-tools.sh: DIAGNOSTICS after failure: $1" >&2
    "$work/bin/clang++" -std=c++20 -E -v -x c++ /dev/null -o /dev/null 2>&1 | tail -25 >&2 || true
    ls "$work/lib/gcc" "$work/include/c++" >&2 || true
    exit 1
}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/t.cpp" <<'EOF'
#include <vector>
#include <cstdio>
int main() {
    std::vector<int> v{1, 2, 3};
    int sum = 0;
    for (int x : v) sum += x;
    return sum == 6 ? 0 : 1;
}
EOF
# NOTE: -isystem mirrors production exactly (local-build.sh derives the same
# flag from --cc for every compile including cmake try-compiles). It is not a
# crutch for broken auto-discovery - the print-file-name assertions below
# guard that separately and loudly.
"$work/bin/clang++" -std=c++20 -isystem "$work/include" -fuse-ld=lld "$test_dir/t.cpp" -o "$test_dir/t" \
    || diag_on_failure "plain C++ compile+link"
"$test_dir/t" || diag_on_failure "plain test binary run"

# Also exercised together through CMake+Ninja, exactly how local-build.sh drives them - a plain
# clang++ invocation above would not catch a broken CMAKE_ROOT (Modules/Templates) or a Ninja that
# can't find the compiler.
cat > "$test_dir/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(test CXX)
add_executable(test t.cpp)
EOF
"$work/bin/cmake" -S "$test_dir" -B "$test_dir/build" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$work/bin/ninja" -DCMAKE_CXX_COMPILER="$work/bin/clang++" \
    -DCMAKE_C_FLAGS="-isystem $work/include" -DCMAKE_CXX_FLAGS="-isystem $work/include" >/dev/null \
    || diag_on_failure "cmake configure"
"$work/bin/cmake" --build "$test_dir/build" >/dev/null || diag_on_failure "cmake build"
"$test_dir/build/test" || diag_on_failure "cmake test binary run"
# Hermeticity assertions: the driver must resolve startup files + libc to the
# harvest above, never to the host's /usr/lib (on a glibc build host the link
# test just passed would ALSO pass with zero harvesting, via host fallback -
# these fail loudly instead). Pure driver logic, no execution.
for _probe in crtbeginS.o libgcc.a libc.so.6; do
    _resolved=$("$work/bin/clang" -print-file-name="$_probe")
    case "$_resolved" in
        "$work"/*) ;;
        *) diag_on_failure "clang resolves $_probe to the host ($_resolved), harvest broken";;
    esac
done
# Same C++ test with fully hermetic headers (-nostdinc drops every host
# /usr/include, including musl-style ones, AND the driver's own auto-discovered
# c++ dirs - so the versioned libstdc++ dirs must be spelled out explicitly,
# mirroring the driver's own search list verbatim; a bare -isystem on include/
# does NOT get the c++/<ver> suffix treatment and fails with 'vector' not
# found). Only the harvest + the compiler's own resource dir remain. Proves
# the harvested include/ tree is self-sufficient; link inputs stay
# auto-discovered as in production. Flag set verified byte-for-byte locally.
_resdir=$("$work/bin/clang" -print-resource-dir)
"$work/bin/clang++" -std=c++20 -nostdinc \
    -isystem "$work/include/c++/$gcc_ver" -isystem "$work/include/c++/$gcc_ver/$gcc_machine" \
    -isystem "$work/include/c++/$gcc_ver/backward" -isystem "$work/include" -isystem "$_resdir/include" \
    -fuse-ld=lld "$test_dir/t.cpp" -o "$test_dir/t-hermetic" \
    || diag_on_failure "hermetic C++ compile+link"
"$test_dir/t-hermetic" || diag_on_failure "hermetic test binary run"

rm -rf "$test_dir"
trap - EXIT

rm -rf "$toolchain_dir"
mv "$work" "$toolchain_dir"
echo "prepare-portable-tools.sh: toolchain ready at $toolchain_dir ($(du -sh "$toolchain_dir" | cut -f1))"
