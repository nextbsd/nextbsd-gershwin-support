#!/usr/bin/env bash
# =============================================================================
# build-gershwin-support.sh — cross-build driver for nextbsd-gershwin-support
# =============================================================================
#
# Builds what only Gershwin uses (E24 D6, D8, D12) for ONE architecture, from
# pinned upstream release tarballs, into the /usr prefix with upstream sonames.
# Follows the source repo conventions (nextbsd-userland wiki,
# Source-Repo-Conventions; reference: nextbsd-xlibs' build-xlibs.sh).
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   upstream meson (cross/meson/<arch>.ini), autotools
#               (cross/autotools/<arch>.site, --host=<triple>) or upstream's
#               plain Makefile, out of tree where upstream allows, installed
#               with DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools, and nothing links against nextbsd-userland: the
# NextBSD base (compat) sysroot is the only input besides sources.lock. Base
# already has OpenSSL, zlib, xz, curl and ICU; they are never rebuilt here.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, cmake, pkgconf, autotools), with compat's
#   `continuous` base extracted into $SYSROOT. $SYSROOT is scratch: this script
#   installs every component into its /usr as it goes (and refuses to replace
#   a base file).
#
# USAGE
#   ./build-gershwin-support.sh          every component, in COMPONENTS order
#   ./build-gershwin-support.sh wget     named components only (their
#                                        dependencies must already be in
#                                        $SYSROOT)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
GS_CROSS="$ROOT/cross"

# Install prefix (E24 Q7): /usr, never /usr/local. .pc files go where base
# keeps them under /usr, /usr/libdata/pkgconfig, whatever the upstream default.
PREFIX=/usr
PC_DIR=/usr/libdata/pkgconfig
# The only places under /usr a component may install into.
ALLOWED_DIRS="usr/bin usr/sbin usr/lib usr/libexec usr/include usr/libdata/pkgconfig usr/share/man"

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

SYSROOT="$(cd "$SYSROOT" && pwd)"
export SYSROOT DESTDIR CROSS_BINDIR GS_CROSS

# pkgconf (ISC, never freedesktop's pkg-config) for this script's own checks
# and for plain-Makefile builds: the sysroot's .pc directories only, -I/-L
# prefixed with the sysroot. meson and autotools set the same from the cross
# files.
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$SYSROOT$PC_DIR:$SYSROOT/usr/X11/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH

# Files this repo has staged into $SYSROOT, so a re-run may replace its own
# files but never a base file.
OWNED="$BUILD/owned-$T.list"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

READELF="$CROSS_BINDIR/llvm-readelf"
STRIP="$CROSS_BINDIR/llvm-strip"
# The cross compiler for upstream plain Makefiles (zstd, lz4), the same as
# CC in cross/autotools/common.site: -fuse-ld=lld in the compiler command.
CROSS_CC="$CROSS_BINDIR/clang --target=$CROSS_TRIPLE --sysroot=$SYSROOT -fuse-ld=lld"

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# The opposite: fail if a staged object links any of the given libraries (the
# optional dependencies a minimal build leaves out).
not_needed_check() {
    local obj="$1" lib
    shift
    for lib in "$@"; do
        if "$READELF" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$lib"; then
            fail "$obj links $lib, which this build leaves out"
        fi
    done
    note "DT_NEEDED ok: $(basename "$obj") links none of: $*"
}

# Assert a staged shared library carries the upstream soname.
soname_check() {
    local lib="$1" want="$2"
    "$READELF" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$lib does not have SONAME $want"
    note "SONAME ok: $want"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION. Every unpacked
# file then gets one mtime, so automake's rebuild rules never fire because a
# patch made a Makefile.am or configure.ac look newer than its outputs (a patch
# that changes an autotools input must change the generated file too).
fetch() {
    local name="$1" url sha file got
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
    find "$SRC_DIR" -exec touch -h -r "$file" {} +
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, nextbsd-ports, a FreeBSD port file used
# as a reference, or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || { note "no patches"; return 0; }
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet --no-backup-if-mismatch < "$dir/$p" \
            || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# meson_build [meson -D options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's cross file. The first cross file is generated here
# and carries the paths of this run; the second is the checked-in one.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$GS_CROSS/meson/$T.ini" \
        --prefix="$PREFIX" --libdir=lib --includedir=include \
        --mandir=share/man --sysconfdir=/etc \
        --buildtype=release -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# autotools_configure [configure options...]: upstream configure in --host mode
# with the arch's CONFIG_SITE, out of tree in $COMP_BUILD.
autotools_configure() {
    (
        cd "$COMP_BUILD"
        CONFIG_SITE="$GS_CROSS/autotools/$T.site" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --with-sysroot="$SYSROOT" \
            --prefix="$PREFIX" --libdir="$PREFIX/lib" \
            --sysconfdir=/etc --mandir="$PREFIX/share/man" \
            --disable-dependency-tracking --disable-silent-rules \
            "$@"
    )
}

# autotools_build [configure options...]: configure; make; make install into
# $COMP_ROOT. For components whose full install is what NextBSD ships.
autotools_build() {
    autotools_configure --enable-shared --disable-static "$@"
    make -C "$COMP_BUILD" $JOBS
    make -C "$COMP_BUILD" install DESTDIR="$COMP_ROOT"
}

# stage <name>: tidy and check $COMP_ROOT, then copy it into $SYSROOT (for the
# components after this one) and $DESTDIR (the artifact).
#   - everything must be under ALLOWED_DIRS (so /usr/local, /etc, info and
#     locale files are refused);
#   - libtool .la files, static archives and docs are dropped;
#   - .pc files from lib/pkgconfig or share/pkgconfig move to $PC_DIR, and no
#     .pc file may name /usr/local or a build-host path;
#   - shared objects and programs are stripped with the target strip;
#     programs are 0555, everything else 0444;
#   - no staged file may replace a base file in $SYSROOT.
stage() {
    local name="$1" r="$COMP_ROOT" stray f d rel allowed
    [ -d "$r$PREFIX" ] || fail "$name installed nothing under $PREFIX"
    find "$r" \( -name '*.la' -o -name '*.a' \) -delete
    rm -rf "$r$PREFIX/share/doc"
    for d in "$r$PREFIX/lib/pkgconfig" "$r$PREFIX/share/pkgconfig"; do
        [ -d "$d" ] || continue
        mkdir -p "$r$PC_DIR"
        mv "$d"/*.pc "$r$PC_DIR/"
        rmdir "$d"
    done
    stray=""
    while IFS= read -r rel; do
        allowed=no
        for d in $ALLOWED_DIRS; do
            case "$rel" in "$d"/*) allowed=yes; break ;; esac
        done
        [ "$allowed" = yes ] || stray="$stray /$rel"
    done < <(cd "$r" && find . ! -type d | sed 's#^\./##')
    [ -z "$stray" ] || fail "$name installed outside $ALLOWED_DIRS:$stray"
    for f in "$r$PC_DIR"/*.pc; do
        [ -e "$f" ] || continue
        grep -q "^prefix=$PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $PREFIX"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" -e "$BUILD" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    find "$r" -type f -name '*.so*' -exec "$STRIP" --strip-unneeded {} +
    find "$r" -type d -exec chmod 0755 {} +
    find "$r" -type f -exec chmod 0444 {} +
    for d in bin sbin libexec; do
        [ -d "$r$PREFIX/$d" ] || continue
        find "$r$PREFIX/$d" -type f -exec "$STRIP" {} +
        find "$r$PREFIX/$d" -type f -exec chmod 0555 {} +
    done
    find "$r" -type d -empty -delete
    touch "$OWNED"
    while IFS= read -r rel; do
        if [ -e "$SYSROOT/$rel" ] || [ -L "$SYSROOT/$rel" ]; then
            grep -qxF "$rel" "$OWNED" || fail "$name would replace base file /$rel"
        fi
        echo "$rel" >> "$OWNED"
    done < <(cd "$r" && find . ! -type d | sed 's#^\./##')
    (cd "$r" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$r" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$r" && find . ! -type d | wc -l) files"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components will see it (and, if given, at that version).
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# dep_check <component> <lib>...: fail early when a library a later component
# links has not been staged into $SYSROOT by an earlier one (COMPONENTS order).
dep_check() {
    local comp="$1" lib
    shift
    for lib in "$@"; do
        grep -qxF "usr/lib/$lib" "$OWNED" 2>/dev/null \
            || fail "$comp needs /usr/lib/$lib from this repo; build its component first (COMPONENTS order)"
    done
}

# =============================================================================
# Components, in build order.
# =============================================================================

# wget (nextbsd/nextbsd-gershwin-support#1, E24 D8) — GNU wget, minimal: TLS
# from base OpenSSL, compression from base zlib, and nothing else. No NLS, no
# libpsl (cookie public-suffix checks), no libidn2 (IDN/IRI), no PCRE/PCRE2
# (--accept-regex keeps POSIX regex), no c-ares, metalink, libuuid or libproxy.
# autotools. Only src/ and the man page are built and installed: upstream's
# full `make install` would also put /etc/wgetrc (wget runs without one) and
# the info manual (base has no info) in place. GPL-3.0-or-later, which is why
# it lives in this optional package and not in the default base.
build_wget() {
    comp "wget [autotools cross]"
    fresh_dirs wget
    fetch wget
    autotools_configure \
        --with-ssl=openssl --with-zlib \
        --without-libpsl --disable-iri --disable-pcre2 --disable-pcre \
        --disable-nls --disable-rpath --disable-xattr \
        --without-metalink --without-cares --without-libuuid \
        --disable-libproxy
    make -C "$COMP_BUILD/lib" $JOBS
    make -C "$COMP_BUILD/src" $JOBS
    make -C "$COMP_BUILD/src" install DESTDIR="$COMP_ROOT"
    make -C "$COMP_BUILD/doc" install.man DESTDIR="$COMP_ROOT"
    stage wget
    local d="$DESTDIR$PREFIX"
    test -x "$d/bin/wget" || fail "/usr/bin/wget not staged"
    test -s "$d/share/man/man1/wget.1" || fail "wget.1 not staged"
    needed_check "$d/bin/wget" libssl
    needed_check "$d/bin/wget" libcrypto
    needed_check "$d/bin/wget" libz
    not_needed_check "$d/bin/wget" libpsl libidn2 libpcre libunistring libintl libiconv \
        libcares libmetalink libuuid libgnutls libproxy
}

# lcms2 (nextbsd/nextbsd-gershwin-support#1) — Little CMS, the library
# Gershwin's Color pane links: liblcms2.so.2 (upstream soname), lcms2.h,
# lcms2_plugin.h and lcms2.pc. meson. The library only: no utilities (jpgicc
# and tificc would need libjpeg and libtiff; nothing in Gershwin runs the
# others) and not the fast-float or threaded plugins, which are GPL-3.0 where
# the library is MIT. lcms2.pc says 2.19: upstream's project version omits the
# .1 (configure says 2.19 too).
build_lcms2() {
    comp "lcms2 [meson cross]"
    fresh_dirs lcms2
    fetch lcms2
    meson_build \
        -Dutils=false -Dtests=disabled -Djpeg=disabled -Dtiff=disabled \
        -Dfastfloat=false -Dthreaded=false -Dversionedlibs=true
    stage lcms2
    local d="$DESTDIR$PREFIX"
    test -f "$d/include/lcms2.h" || fail "lcms2.h not staged"
    test -f "$d/include/lcms2_plugin.h" || fail "lcms2_plugin.h not staged"
    test -L "$d/lib/liblcms2.so" || fail "liblcms2.so link not staged"
    test -e "$d/lib/liblcms2.so.2" || fail "liblcms2.so.2 not staged"
    soname_check "$d/lib/liblcms2.so.2" liblcms2.so.2
    needed_check "$d/lib/liblcms2.so.2" libm
    pc_check lcms2 2.19
}

# ---- squashfs: AppImage integration (nextbsd/nextbsd-gershwin-support#3) ----
# squashfs-tools-ng and squashfuse (E24 D12) with the three libraries they need
# that the base has no public copy of: zstd and lz4 (base builds zstd only as
# its private libprivatezstd, and lz4 not at all in userland) and libfuse3
# (base has the kernel side, `options FUSEFS`, and /sbin/mount_fusefs only).
# zlib, liblzma and libbz2 come from the base. The libraries install with
# upstream's sonames and .pc files, so the overwrite check in stage() keeps
# them clear of base's private copies.

# zstd — Zstandard, the library only, with upstream's lib/Makefile (zstd has
# no configure): libzstd.so.1, zstd.h, zstd_errors.h, zdict.h, libzstd.pc.
# Multithreaded, as upstream builds the shared library (links libthr). Not
# the programs: base has /usr/bin/zstd on its private copy. The Makefile picks
# the platform from `uname`, which is the Linux runner here, so UNAME=FreeBSD
# selects the ELF soname flags and /usr/libdata/pkgconfig. Upstream's
# Makefile builds in its own tree (the unpacked .build/src copy). No static
# library. BSD-3-Clause (upstream offers BSD or GPL-2.0).
build_zstd() {
    comp "zstd [upstream lib/Makefile cross]"
    fresh_dirs zstd
    fetch zstd
    local f mk=(-C "$SRC_DIR/lib" UNAME=FreeBSD CC="$CROSS_CC"
              AR="$CROSS_BINDIR/llvm-ar" PREFIX="$PREFIX" DESTDIR="$COMP_ROOT")
    make $JOBS "${mk[@]}" libzstd-release libzstd.pc
    make "${mk[@]}" install-shared install-includes install-pc
    stage zstd
    local d="$DESTDIR$PREFIX"
    for f in zstd.h zstd_errors.h zdict.h; do
        test -f "$d/include/$f" || fail "$f not staged"
    done
    test -L "$d/lib/libzstd.so" || fail "libzstd.so link not staged"
    test -e "$d/lib/libzstd.so.1" || fail "libzstd.so.1 not staged"
    soname_check "$d/lib/libzstd.so.1" libzstd.so.1
    needed_check "$d/lib/libzstd.so.1" libthr
    pc_check libzstd "$VERSION"
}

# lz4 — LZ4, the library only, with upstream's lib/Makefile: liblz4.so.1,
# lz4.h, lz4hc.h, lz4frame.h, liblz4.pc. TARGET_OS=FreeBSD for the same reason
# as zstd's UNAME; BUILD_STATIC=no, so no liblz4.a (and so none of the
# headers upstream installs only beside it). The lz4 program is GPL-2.0 and
# is not built. Library BSD-2-Clause.
build_lz4() {
    comp "lz4 [upstream lib/Makefile cross]"
    fresh_dirs lz4
    fetch lz4
    local f mk=(-C "$SRC_DIR/lib" TARGET_OS=FreeBSD BUILD_STATIC=no CC="$CROSS_CC"
              AR="$CROSS_BINDIR/llvm-ar" PREFIX="$PREFIX" DESTDIR="$COMP_ROOT")
    make $JOBS "${mk[@]}" lib-release
    make "${mk[@]}" install
    stage lz4
    local d="$DESTDIR$PREFIX"
    for f in lz4.h lz4hc.h lz4frame.h; do
        test -f "$d/include/$f" || fail "$f not staged"
    done
    test -L "$d/lib/liblz4.so" || fail "liblz4.so link not staged"
    test -e "$d/lib/liblz4.so.1" || fail "liblz4.so.1 not staged"
    soname_check "$d/lib/liblz4.so.1" liblz4.so.1
    pc_check liblz4 "$VERSION"
}

# libfuse — libfuse3, the library only, meson: libfuse3.so.4, the fuse3/
# headers, fuse3.pc. On a BSD upstream never builds fusermount3 or mount.fuse3
# (-Dutils=false says so); libfuse mounts by running base's mount_fusefs and
# unmounts with unmount(2). No examples, tests or io_uring. LGPL-2.1.
#
# patches/libfuse/0001 (Origin: NextBSD) makes that work for a normal user,
# the way an AppImage mounts its payload on Linux: mount_fusefs is run as
# /sbin/mount_fusefs by absolute path (a user's PATH usually lacks /sbin);
# /dev/fuse access, vfs.usermount and mount point ownership are checked first
# with a clear error; and an unmount(2) of a file system the user already
# unmounted is not an error. The checks below make sure the patched code is
# what was built.
build_libfuse() {
    comp "libfuse [meson cross]"
    fresh_dirs libfuse
    fetch libfuse
    meson_build \
        -Dutils=false -Dexamples=false -Dtests=false \
        -Denable-io-uring=false -Denable-usdt=false
    stage libfuse
    local d="$DESTDIR$PREFIX" lib
    for f in fuse.h fuse_common.h fuse_lowlevel.h fuse_opt.h; do
        test -f "$d/include/fuse3/$f" || fail "fuse3/$f not staged"
    done
    test -L "$d/lib/libfuse3.so" || fail "libfuse3.so link not staged"
    lib="$d/lib/libfuse3.so.4"
    test -e "$lib" || fail "libfuse3.so.4 not staged"
    soname_check "$lib" libfuse3.so.4
    needed_check "$lib" libthr
    grep -aq '/sbin/mount_fusefs' "$lib" || fail "libfuse3 does not run /sbin/mount_fusefs by absolute path (patch 0001)"
    grep -aq 'vfs.usermount' "$lib" || fail "libfuse3 lacks the vfs.usermount check (patch 0001)"
    "$READELF" --dyn-syms "$lib" | grep -qw unmount || fail "libfuse3 does not unmount with unmount(2)"
    note "libfuse3 runs /sbin/mount_fusefs, checks vfs.usermount, unmounts with unmount(2)"
    pc_check fuse3 "$VERSION"
}

# squashfs-tools-ng — libsquashfs (LGPL-3.0-or-later), which Gershwin's
# Workspace and make_services use to read AppImage icons and .desktop files
# without mounting, and the five tools (GPL-3.0-or-later: fine in this
# optional package, E24 D12): gensquashfs, rdsquashfs, sqfs2tar, sqfsdiff,
# tar2sqfs. autotools. Every squashfs compressor except LZO (GPL-2.0, and
# AppImages do not use it): gzip and xz from the base, lz4 and zstd from this
# repo (all found through pkgconf in the sysroot), bzip2 from the base for
# tarballs. No SELinux, no Doxygen. No configure check runs a target program.
build_squashfs_tools_ng() {
    comp "squashfs-tools-ng [autotools cross]"
    dep_check squashfs-tools-ng libzstd.so liblz4.so
    fresh_dirs squashfs-tools-ng
    fetch squashfs-tools-ng
    autotools_build \
        --with-gzip --with-xz --with-lz4 --with-zstd --with-bzip2 \
        --without-lzo --without-selinux --with-tools \
        --disable-doxygen-doc
    stage squashfs-tools-ng
    local d="$DESTDIR$PREFIX" t
    for t in gensquashfs rdsquashfs sqfs2tar sqfsdiff tar2sqfs; do
        test -x "$d/bin/$t" || fail "/usr/bin/$t not staged"
        test -s "$d/share/man/man1/$t.1" || fail "$t.1 not staged"
        needed_check "$d/bin/$t" libsquashfs.so.1
    done
    test -f "$d/include/sqfs/predef.h" || fail "sqfs/predef.h not staged"
    test -L "$d/lib/libsquashfs.so" || fail "libsquashfs.so link not staged"
    test -e "$d/lib/libsquashfs.so.1" || fail "libsquashfs.so.1 not staged"
    soname_check "$d/lib/libsquashfs.so.1" libsquashfs.so.1
    for t in libz.so libzstd liblz4 liblzma; do
        needed_check "$d/lib/libsquashfs.so.1" "$t"
    done
    not_needed_check "$d/lib/libsquashfs.so.1" liblzo2 libselinux
    pc_check libsquashfs1 "$VERSION"
}

# squashfuse — the FUSE drivers squashfuse (high-level API) and squashfuse_ll
# (low-level, multithreaded), with their man pages, linked against libfuse3
# from this repo (configure finds fuse3 through pkgconf and selects the FUSE
# 3.2 API). autotools. Both programs link squashfuse's own code statically
# (upstream's convenience libraries), so only they and their man pages are
# installed: not libsquashfuse, its headers or .pc files, which nothing uses.
# Decompressors as for squashfs-tools-ng, LZO left out; no demo programs.
# BSD-2-Clause.
#
# This is what mounts a squashfs image the way an AppImage does on Linux, as
# a normal user (README, "Mounting a squashfs image as a user").
build_squashfuse() {
    comp "squashfuse [autotools cross]"
    dep_check squashfuse libzstd.so liblz4.so libfuse3.so
    fresh_dirs squashfuse
    fetch squashfuse
    autotools_configure --enable-shared --disable-static \
        --disable-demo --without-lzo
    make -C "$COMP_BUILD" $JOBS
    make -C "$COMP_BUILD" install-binPROGRAMS install-man DESTDIR="$COMP_ROOT"
    stage squashfuse
    local d="$DESTDIR$PREFIX" p l
    for p in squashfuse squashfuse_ll; do
        test -x "$d/bin/$p" || fail "/usr/bin/$p not staged"
        test -s "$d/share/man/man1/$p.1" || fail "$p.1 not staged"
        for l in libfuse3.so.4 libz.so libzstd liblz4 liblzma; do
            needed_check "$d/bin/$p" "$l"
        done
        not_needed_check "$d/bin/$p" liblzo2 libsquashfuse libfuse.so.2
    done
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and append <name> here in build order.
COMPONENTS="wget lcms2 zstd lz4 libfuse squashfs-tools-ng squashfuse"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
fi

for t in clang llvm-readelf llvm-strip; do
    [ -x "$CROSS_BINDIR/$t" ] || fail "$CROSS_BINDIR/$t not found (the toolchain image provides it)"
done

echo "nextbsd-gershwin-support: building [$COMPONENTS] for $T/$TA into $DESTDIR$PREFIX"
echo "pkgconf searches only: $PKG_CONFIG_LIBDIR"
mkdir -p "$DESTDIR" "$BUILD"
# A full run starts from a fresh base sysroot, so it starts a fresh list of
# what this repo owns there; a run of named components keeps the list.
[ $# -gt 0 ] || : > "$OWNED"
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
