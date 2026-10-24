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
   patch series under `patches/<name>/` (listed in `series`, each with an
   `Origin:`), never edits to an unpacked tree. No
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

This repo follows the
[source repo conventions](https://github.com/nextbsd/nextbsd-userland/wiki/Source-Repo-Conventions);
nextbsd-xlibs' `build-xlibs.sh` is the reference.

```
build-gershwin-support.sh       cross-build driver: every component, or the named ones
sources.lock                    <name> <version> <sha256> <url> per component
patches/<name>/series           the component's patches in order; each *.patch has an Origin: line
cross/meson/{amd64,arm64}.ini   meson cross files (system = 'freebsd', c_ld = 'lld')
cross/autotools/{amd64,arm64,common}.site   CONFIG_SITE files for --host builds
.github/workflows/build.yml     CI: build both arches; publish `continuous` from main
NOTICE.md                       per-component provenance and licence
```

`.build/` (downloads in `.build/dl`, sources in `.build/src`, out-of-tree
builds, install roots and the generated cross file) is scratch and ignored.

## Build model

`build-gershwin-support.sh` runs inside the `nextbsd-kernel-toolchain`
container (clang/lld 19.1.7 and the LLVM binutils, meson, ninja, cmake,
pkgconf, autotools) with compat's `continuous` base staged as the cross
sysroot. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base (scratch: components are installed into it) |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM tools (set by the image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |

For each component, in `COMPONENTS` order, one `build_<name>()`:

1. **Fetch** the tarball named in `sources.lock` (cached in `.build/dl`),
   refuse it unless the SHA-256 matches, unpack it under `.build/src/`.
2. **Patch** with `patches/<name>/series`. The build refuses a patch that is
   not listed, a listed patch that is missing, and a patch without an
   `Origin:` header (DEP-3 style: upstream commit, a FreeBSD port file used as
   a reference, or `NextBSD`).
3. **Build** with upstream's own build system, with NextBSD's options:
   meson with a cross file generated per run (sysroot and LLVM paths) followed
   by `cross/meson/<arch>.ini`; autotools with `--host=<triple>`,
   `--with-sysroot` and `CONFIG_SITE=cross/autotools/<arch>.site`; or a
   plain upstream Makefile told the target OS and compiler (zstd, lz4).
4. **Stage**: check and tidy the install, then copy it into `$SYSROOT`, so
   later components find its headers, libraries and `.pc` files through the
   normal sysroot search, and into `$DESTDIR`, the published artifact.

**Checks the build enforces:** nothing installs outside `/usr/bin`, `/usr/sbin`,
`/usr/lib`, `/usr/libexec`, `/usr/include`, `/usr/libdata/pkgconfig` and
`/usr/share/man` (so no `/usr/local`, `/etc`, info or locale files); no
staged file replaces a base file in the sysroot; `.pc` files are moved to
`/usr/libdata/pkgconfig`, must say `prefix=/usr` and may not name `/usr/local`
or a build path; libraries carry their upstream soname and link what they
should, and the minimal builds link none of the optional libraries they leave
out (cross `readelf -d`); pkgconf (never freedesktop's pkg-config, E24 D1)
searches only the sysroot (`/usr/libdata/pkgconfig`, and `/usr/X11/lib/pkgconfig`
once nextbsd-xlibs is in it). Static and libtool archives are dropped,
objects are stripped with the target strip, programs are `0555` and the rest
`0444`.

```
./build-gershwin-support.sh          # every component
./build-gershwin-support.sh wget     # one component (its dependencies already in $SYSROOT)
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
2. NextBSD changes, if any: `patches/<name>/NNNN-description.patch`, each with
   an `Origin:` header and a line saying why, listed in `patches/<name>/series`.
3. `build_<name>()` in `build-gershwin-support.sh`: `fresh_dirs`, `fetch`,
   the upstream build, `stage`, then checks on what it staged. Register it in
   `COMPONENTS` after anything it links from this repo (`dep_check`).
4. Answers to configure checks that would run a target program go in
   `cross/autotools/*.site`, each with its reason.
5. A row in `NOTICE.md` and in the table above.
6. Configuration, if any, goes to `nextbsd-overlays`, not here.
