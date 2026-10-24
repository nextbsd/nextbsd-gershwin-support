# nextbsd-gershwin-support

What only the [Gershwin](https://github.com/gershwin-desktop) desktop uses on
NextBSD, built from pinned upstream sources and shipped as the
**`NextBSD-gershwin-support`** package (E24 D6,
[plan](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction),
epic nextbsd/nextbsd#574). It is not part of the default base: a plain NextBSD
install doesn't carry it, and Gershwin's target `nextbsd.txt` installs it.

## The rule for what goes here

A component belongs in this repo when all of these hold:

1. **Only Gershwin uses it.** What GNUstep itself needs goes to
   `nextbsd-gnustep-support`; X libraries to `nextbsd-xlibs`; Apple sources to
   `nextbsd-userland`; third-party programs every install wants to
   `nextbsd-contrib`. Because the package is optional, licences the default
   base avoids (GPL-3.0: wget, the squashfs tools) are fine here.
2. **It is built from a pinned upstream release tarball**, listed in
   `sources.lock` with its URL and SHA-256. NextBSD changes, if any, are a
   patch series under `patches/<name>/`, never edits to an unpacked tree. No
   FreeBSD packages, ports or ports tools.
3. **It links only against what is built before it**: the NextBSD base
   (OpenSSL 3.5, zlib, xz, curl and ICU are already there and are never
   rebuilt here), the E23/E24 repos it is ordered after, and libraries built
   earlier in this repo.
4. **It installs under `/usr`**, with upstream's sonames, its `.pc` files in
   `/usr/libdata/pkgconfig` as base does, and no static or libtool archives.
   Never `/usr/local` (E24 Q7). A component that needs X goes under `/usr/X11`.
5. **It ships no `/etc`.** Configuration, if any, comes from
   `nextbsd-overlays`.
6. **No D-Bus or Avahi** (E24 D2): any build option that pulls them in is off.

## Components

| Component | Upstream | Installs | Ticket |
|---|---|---|---|
| `wget` | GNU wget 1.25.0, minimal (D8): base OpenSSL and zlib; no NLS, libpsl, libidn2, PCRE/PCRE2, c-ares, metalink, libuuid or libproxy | `/usr/bin/wget`, `wget.1` | nextbsd/nextbsd-gershwin-support#1 |
| `lcms2` | Little CMS 2.19.1, library only (Gershwin's Color pane) | `/usr/lib/liblcms2.so.2`, `lcms2.h`, `lcms2_plugin.h`, `lcms2.pc` | nextbsd/nextbsd-gershwin-support#1 |

Planned: `xdotool` (#2) and the squashfs tools with libfuse3, zstd and lz4
(#3). Licences are per component; see `NOTICE.md`. The top-level `LICENSE`
(BSD-2) covers only the harness in this repo.

## Layout

```
build-gershwin-support.sh    cross-build driver: every component, or one by name
sources.lock                 <name> <version> <sha256> <url> per component
patches/<name>/*.patch       NextBSD changes, applied in name order with -p1
cross/amd64.ini, arm64.ini   meson cross files (system = 'freebsd', E23 D12)
.github/workflows/build.yml  CI: build both arches; publish `continuous` from main
NOTICE.md                    per-component provenance and licence
```

`.build/` (out-of-tree builds and install roots) and `.sources/` (downloaded
tarballs) are scratch and ignored.

## Build model

`build-gershwin-support.sh` follows nextbsd-contrib's `build-contrib.sh`. It
runs inside the `nextbsd-kernel-toolchain` container (clang/lld 19.1.7 and the
LLVM binutils, meson, ninja, cmake, pkgconf, autotools) with compat's
`continuous` base staged as the cross sysroot. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM tools (set by the image) |
| `DESTDIR` | where to stage; default `/stage` |
| `SOURCES` | tarball cache; default `.sources/` |

For each component the driver fetches the tarball named in `sources.lock`,
refuses it unless the SHA-256 matches, unpacks it under `.build/`, applies
`patches/<name>/`, and runs upstream's own build system in cross mode:

- **autotools:** `configure --host=<triple>` with the cross clang and
  `--sysroot`, out of tree. Checks that would run a test program get their
  FreeBSD answers as cache variables, commented where they are set.
- **meson:** `meson_setup` writes `.build/paths-<arch>.ini` (the toolchain
  directory, the sysroot and its pkgconfig directories) and layers
  `cross/<arch>.ini` on it.
- **plain Makefiles** (zstd, lz4): the target OS and compiler on the command
  line, since `uname` on the runner says Linux.

pkgconf (never freedesktop's pkg-config, E24 D1) sees only the sysroot's `.pc`
files, with the sysroot prefixed to their paths. Libraries built here are
staged into `$DESTDIR` in `COMPONENTS` order; a later component that links one
is given its flags directly and calls `dep_check` first. `stage_root` copies an
install root into `$DESTDIR` as base ships things: `.pc` files moved to
`/usr/libdata/pkgconfig`, archives dropped, objects stripped with the target
strip, programs `0555` and the rest `0444`. Each component ends with checks on
what it staged (files, soname, `DT_NEEDED`).

```
./build-gershwin-support.sh          # every component
./build-gershwin-support.sh wget     # one component
```

## CI, artifact, package

The workflow builds both arches on every pull request that touches the build.
On a push to `main`, or a manual run on `main`, it publishes
`nextbsd-gershwin-support-<arch>.tar.gz` to the `continuous` release, rooted at
`/`. It never publishes from a pull request, and it dispatches nothing: this
repo is built by hand, in order, after the repos it depends on, and the
package repository is built by hand too (nextbsd/nextbsd-pkg#16).
`nextbsd-pkg` repackages the tarball as `NextBSD-gershwin-support`
(nextbsd/nextbsd-pkg#27).

## Adding a component

1. A line in `sources.lock`: name, version, SHA-256 and the upstream release
   URL.
2. `patches/<name>/NNNN-description.patch` for any NextBSD change, each with a
   header saying why.
3. `build_<name>()` in `build-gershwin-support.sh`, registered in
   `COMPONENTS` after anything it links from this repo, ending with checks on
   what it staged.
4. A row in `NOTICE.md` and in the table above.
5. Configuration, if any, goes to `nextbsd-overlays`, not here.
