#!/usr/bin/env bash
# =============================================================================
# build-gershwin-support.sh — cross-build driver for nextbsd-gershwin-support
# =============================================================================
#
# Builds what only Gershwin uses (E24 D6, D8, D12) for ONE architecture into
# $DESTDIR, from pinned upstream release tarballs listed in sources.lock, with
# NextBSD's changes, if any, as patch series under patches/<name>/.
#
# Each component keeps upstream's own build system, run in cross mode:
#   - autotools: `configure --host=<triple>` with the toolchain clang and
#     --sysroot, out of tree under .build/; configure checks that would run a
#     test program get their FreeBSD answers as cache variables;
#   - meson: the per-arch cross file in cross/<arch>.ini, layered on a paths
#     file this script writes (meson_setup);
#   - plain Makefiles: told the target OS and compiler on the command line.
# Then only what NextBSD ships is staged, the way base ships it (stage_root).
#
# Modelled on nextbsd-contrib's build-contrib.sh. Nothing here uses make.py,
# the FreeBSD buildenv, FreeBSD packages or ports. Build tools come from the
# toolchain image (pkgconf, never freedesktop's pkg-config: E24 D1).
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container, with compat's `continuous`
#   base extracted into $SYSROOT. The image's pinned LLVM 19.1.7 tools live in
#   $CROSS_BINDIR; meson, ninja, cmake, pkgconf and autotools are in PATH.
#
# USAGE
#   ./build-gershwin-support.sh          every component, in COMPONENTS order
#   ./build-gershwin-support.sh wget     one component by name
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
: "${SOURCES:=$ROOT/.sources}"      # tarball cache; CI keeps it between runs

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     CROSS_TRIPLE="${TA}-unknown-freebsd" ;;
esac
CROSS_CC="$CROSS_BINDIR/clang --target=$CROSS_TRIPLE --ld-path=$CROSS_BINDIR/ld.lld"
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"

export SYSROOT DESTDIR CROSS_BINDIR

# ---- pkgconf -----------------------------------------------------------------
# Only the sysroot's .pc files, with the sysroot prefixed to their -I/-L
# paths, so nothing from the build host leaks in. Base keeps its .pc files in
# /usr/libdata/pkgconfig; the X11 directories are there for the repos that
# stage into /usr/X11 (nextbsd-xlibs), once a component here needs them.
# Libraries built earlier in this repo live under $DESTDIR, not the sysroot,
# so their flags are passed to the later component directly (see dep_check).
PC_DIRS=""
for d in usr/libdata/pkgconfig usr/X11/libdata/pkgconfig usr/X11/lib/pkgconfig; do
    [ -d "$SYSROOT/$d" ] && PC_DIRS="${PC_DIRS:+$PC_DIRS:}$SYSROOT/$d"
done
export PKG_CONFIG=pkgconf
export PKG_CONFIG_LIBDIR="$PC_DIRS"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
unset PKG_CONFIG_PATH

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# The toolchain image ships the pinned llvm-ar/llvm-ranlib/llvm-strip in
# $CROSS_BINDIR (and /usr/bin/<tool>-19).
llvm_tool() {
    local t
    for t in "$CROSS_BINDIR/$1" "$(command -v "$1-19" 2>/dev/null)" "$(command -v "$1" 2>/dev/null)"; do
        [ -n "$t" ] && [ -x "$t" ] && { echo "$t"; return 0; }
    done
    fail "$1 not found (looked in $CROSS_BINDIR and PATH)"
}

# Assert a staged binary links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    local readelf="$CROSS_BINDIR/readelf"
    [ -x "$readelf" ] || readelf="$CROSS_BINDIR/llvm-readelf"
    [ -x "$readelf" ] || readelf="$(command -v llvm-readelf-19 2>/dev/null || true)"
    if [ ! -x "$readelf" ]; then
        note "skip DT_NEEDED check ($want): no readelf found"
        return 0
    fi
    "$readelf" -d "$obj" 2>/dev/null | grep -q "NEEDED.*$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# The opposite: fail if a staged binary links a library it must not (the
# optional dependencies a minimal build leaves out).
not_needed_check() {
    local obj="$1" lib readelf="$CROSS_BINDIR/llvm-readelf"
    shift
    [ -x "$readelf" ] || { note "skip DT_NEEDED exclusions: no readelf"; return 0; }
    for lib in "$@"; do
        if "$readelf" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$lib"; then
            fail "$obj links $lib, which this build leaves out"
        fi
    done
    note "DT_NEEDED ok: $(basename "$obj") links none of: $*"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# ---- sources -----------------------------------------------------------------
# Look a component up in sources.lock: sets SRC_VERSION, SRC_SHA256, SRC_URL.
lock_entry() {
    local name="$1" line
    line=$(awk -v n="$name" '$1 == n && $0 !~ /^[[:space:]]*#/ { print; exit }' "$ROOT/sources.lock")
    [ -n "$line" ] || fail "$name is not in sources.lock"
    read -r _ SRC_VERSION SRC_SHA256 SRC_URL <<<"$line"
    [ -n "$SRC_URL" ] || fail "sources.lock: $name needs <version> <sha256> <url>"
}

# Download (or reuse from $SOURCES) a component's pinned tarball, refuse it
# unless its SHA-256 matches sources.lock, unpack it into a fresh
# $BUILD/<name>-src-$T and apply patches/<name>/*.patch in name order with
# -p1. Sets SRC_DIR. Every file then gets one mtime, so automake's rebuild
# rules never fire because a patch (or the tarball's own order) made a
# Makefile.am or configure.ac look newer than what was generated from it.
# A patch that changes an autotools input must change the generated file too.
fetch_src() {
    local name="$1" tarball p n=0
    lock_entry "$name"
    mkdir -p "$SOURCES"
    tarball="$SOURCES/$(basename "$SRC_URL")"
    if [ ! -f "$tarball" ] || ! echo "$SRC_SHA256  $tarball" | sha256sum -c --status -; then
        note "fetch $SRC_URL"
        curl -fsSL --retry 3 -o "$tarball.part" "$SRC_URL"
        mv "$tarball.part" "$tarball"
    fi
    echo "$SRC_SHA256  $tarball" | sha256sum -c --status - \
        || fail "$name: $(basename "$tarball") does not match the SHA-256 in sources.lock"
    note "$name $SRC_VERSION ($(basename "$tarball"), sha256 ok)"
    SRC_DIR="$BUILD/$name-src-$T"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$tarball" -C "$SRC_DIR" --strip-components=1
    if [ -d "$ROOT/patches/$name" ]; then
        for p in "$ROOT/patches/$name"/*.patch; do
            [ -e "$p" ] || continue
            patch -d "$SRC_DIR" -p1 --batch --forward --no-backup-if-mismatch -s < "$p" \
                || fail "$name: $(basename "$p") does not apply"
            n=$((n + 1))
        done
    fi
    note "patches applied: $n"
    find "$SRC_DIR" -exec touch -h -r "$tarball" {} +
}

# Fail early when a library a later component links has not been staged.
# Libraries built here are staged into $DESTDIR, and a later component
# compiles against $DESTDIR/usr/include and links $DESTDIR/usr/lib next to the
# sysroot, so COMPONENTS order matters.
dep_check() {
    local comp="$1"; shift
    local lib
    for lib in "$@"; do
        [ -e "$DESTDIR/usr/lib/$lib" ] \
            || fail "$comp needs $DESTDIR/usr/lib/$lib; build its component first (COMPONENTS order)"
    done
}

# Write the meson paths file for this arch (the constants cross/<arch>.ini
# uses) and run `meson setup` with both. Extra arguments go to meson setup.
meson_setup() {
    local builddir="$1" srcdir="$2" paths pcl="" d
    shift 2
    command -v meson >/dev/null || fail "meson not found (the toolchain image provides it)"
    paths="$BUILD/paths-$T.ini"
    IFS=: read -ra dirs <<<"$PC_DIRS"
    for d in "${dirs[@]}"; do pcl="${pcl:+$pcl, }'$d'"; done
    cat > "$paths" <<EOF
[constants]
bindir = '$CROSS_BINDIR'
sysroot = '$SYSROOT'
pc_libdir = [$pcl]
EOF
    meson setup "$builddir" "$srcdir" \
        --cross-file "$paths" --cross-file "$ROOT/cross/$T.ini" \
        --prefix=/usr --libdir=lib --includedir=include \
        --mandir=share/man --sysconfdir=/etc \
        --buildtype=release --wrap-mode=nodownload \
        "$@"
}

# Copy a component's install root into $DESTDIR the way base ships libraries
# and programs: no static or libtool archives, .pc files in
# /usr/libdata/pkgconfig, shared objects and programs stripped with the target
# strip, programs 0555 and everything else 0444.
stage_root() {
    local root="$1" strip
    strip=$(llvm_tool llvm-strip)
    find "$root" \( -name '*.la' -o -name '*.a' \) -delete
    # meson and libtool put .pc files under lib/; base keeps them in libdata.
    if [ -d "$root/usr/lib/pkgconfig" ]; then
        mkdir -p "$root/usr/libdata/pkgconfig"
        mv "$root/usr/lib/pkgconfig/"*.pc "$root/usr/libdata/pkgconfig/"
        rmdir "$root/usr/lib/pkgconfig"
    fi
    find "$root" -type f -name '*.so.*' -exec "$strip" --strip-unneeded {} +
    find "$root" -type d -exec chmod 0755 {} +
    find "$root" -type f -exec chmod 0444 {} +
    if [ -d "$root/usr/bin" ]; then
        find "$root/usr/bin" -type f -exec "$strip" {} +
        find "$root/usr/bin" -type f -exec chmod 0555 {} +
    fi
    (cd "$root" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    return 0
}

# =============================================================================
# wget (nextbsd/nextbsd-gershwin-support#1, E24 D8)
# =============================================================================
# GNU wget, minimal: TLS from base OpenSSL, compression from base zlib, and
# nothing else. No NLS, no libpsl (cookie public-suffix checks), no libidn2
# (IDN/IRI), no PCRE/PCRE2 (--accept-regex keeps POSIX regex), no c-ares,
# metalink, libuuid or libproxy. Ships /usr/bin/wget and wget.1; no
# /etc/wgetrc (wget runs without one) and no info manual (base has no info).
# GPL-3.0-or-later, which is why it lives in this package and not in the
# default base.
build_wget() {
    comp "wget [autoconf cross]"
    fresh_dirs wget
    fetch_src wget
    local ar ranlib strip
    ar=$(llvm_tool llvm-ar); ranlib=$(llvm_tool llvm-ranlib); strip=$(llvm_tool llvm-strip)
    (
        cd "$COMP_BUILD"
        # Nothing to pre-seed: the configure checks that would run a test
        # program fall back to gnulib's cross guesses.
        CC="$CROSS_CC --sysroot=$SYSROOT" \
        CFLAGS="-O2 -pipe" \
        CPPFLAGS="-I$SYSROOT/usr/include" \
        LDFLAGS="-L$SYSROOT/usr/lib" \
        AR="$ar" RANLIB="$ranlib" STRIP="$strip" \
        "$SRC_DIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix=/usr --sysconfdir=/etc --mandir=/usr/share/man \
            --with-ssl=openssl --with-zlib \
            --without-libpsl --disable-iri --disable-pcre2 --disable-pcre \
            --disable-nls --disable-rpath --disable-xattr \
            --without-metalink --without-cares --without-libuuid \
            --disable-libproxy \
            --disable-dependency-tracking
        make $JOBS -C lib
        make $JOBS -C src wget
        make -C doc wget.1
        mkdir -p "$COMP_ROOT/usr/bin" "$COMP_ROOT/usr/share/man/man1"
        install -m 0555 src/wget "$COMP_ROOT/usr/bin/wget"
        install -m 0444 doc/wget.1 "$COMP_ROOT/usr/share/man/man1/wget.1"
    )
    stage_root "$COMP_ROOT"
    test -x "$DESTDIR/usr/bin/wget" || fail "/usr/bin/wget was not staged"
    test -s "$DESTDIR/usr/share/man/man1/wget.1" || fail "wget.1 was not staged"
    needed_check "$DESTDIR/usr/bin/wget" "libssl"
    needed_check "$DESTDIR/usr/bin/wget" "libcrypto"
    needed_check "$DESTDIR/usr/bin/wget" "libz"
    not_needed_check "$DESTDIR/usr/bin/wget" libpsl libidn2 libpcre libunistring libintl libiconv libcares libmetalink libuuid libgnutls
    [ -e "$DESTDIR/etc" ] && fail "wget staged /etc; this package ships no configuration"
    return 0
}

# =============================================================================
# lcms2 (nextbsd/nextbsd-gershwin-support#1) — Little CMS
# =============================================================================
# The library Gershwin's Color pane links: liblcms2.so.2 (upstream soname),
# lcms2.h, lcms2_plugin.h and lcms2.pc, built with upstream's meson build and
# the repo's cross file. The library only: no utilities (jpgicc and tificc
# would need libjpeg and libtiff; nothing in Gershwin runs the others) and not
# the fast-float or threaded plugins, which are GPL-3.0 where the library is
# MIT.
build_lcms2() {
    comp "lcms2 [meson cross]"
    fresh_dirs lcms2
    fetch_src lcms2
    meson_setup "$COMP_BUILD/build" "$SRC_DIR" \
        -Dutils=false -Dtests=disabled -Djpeg=disabled -Dtiff=disabled \
        -Dfastfloat=false -Dthreaded=false -Dversionedlibs=true
    meson compile -C "$COMP_BUILD/build"
    meson install -C "$COMP_BUILD/build" --destdir "$COMP_ROOT"
    stage_root "$COMP_ROOT"
    test -f "$DESTDIR/usr/include/lcms2.h" || fail "lcms2.h was not staged"
    test -f "$DESTDIR/usr/include/lcms2_plugin.h" || fail "lcms2_plugin.h was not staged"
    test -f "$DESTDIR/usr/libdata/pkgconfig/lcms2.pc" || fail "lcms2.pc was not staged"
    test -e "$DESTDIR/usr/lib/liblcms2.so.2" || fail "liblcms2.so.2 was not staged"
    test -L "$DESTDIR/usr/lib/liblcms2.so" || fail "liblcms2.so link was not staged"
    local readelf soname
    readelf=$(llvm_tool llvm-readelf)
    soname=$("$readelf" -d "$DESTDIR/usr/lib/liblcms2.so.2" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
    [ "$soname" = liblcms2.so.2 ] || fail "liblcms2 soname is '$soname', upstream's is liblcms2.so.2"
    note "soname: $soname"
    needed_check "$DESTDIR/usr/lib/liblcms2.so.2" "libm"
    return 0
}

# =============================================================================
# driver
# =============================================================================
# Add a component: a pinned line in sources.lock, build_<name>() above
# (hyphens in the name become underscores in the function), and <name> here,
# after anything it links that this repo builds.
COMPONENTS="wget lcms2"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $COMPONENTS)" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-gershwin-support: building [$COMPONENTS] for $T/$TA into $DESTDIR"
echo "pkgconf search path: ${PKG_CONFIG_LIBDIR:-<none>}"
mkdir -p "$DESTDIR" "$BUILD"
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . \( -type f -o -type l \) | sort | sed 's#^\.##' )
