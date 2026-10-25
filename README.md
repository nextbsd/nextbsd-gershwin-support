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
   rebuilt here), the E23/E24/E25 repos it is ordered after
   (nextbsd-displayserver-support for libxkbcommon, nextbsd-xlibs for the X
   libraries), and libraries built earlier in this repo.
4. **It installs under `/usr`**, with upstream's sonames, its `.pc` files in
   `/usr/libdata/pkgconfig` as base does, and no static or libtool archives.
   Never `/usr/local` (E24 Q7). A component that needs X goes under `/usr/X11`
   (`bin`, `lib`, `include`, `share/man`), its `.pc` files in
   `/usr/X11/lib/pkgconfig` as nextbsd-xlibs does.
5. **It ships no `/etc`.** Configuration, if any, comes from
   `nextbsd-overlays`.
6. **No D-Bus or Avahi** (E24 D2): any build option that pulls them in is off.

## Components

| Component | Upstream | Installs | Ticket |
|---|---|---|---|
| `wget` | GNU wget 1.25.0, minimal (D8): base OpenSSL and zlib; no NLS, libpsl, libidn2, PCRE/PCRE2, c-ares, metalink, libuuid or libproxy | `/usr/bin/wget`, `wget.1` | nextbsd/nextbsd-gershwin-support#1 |
| `lcms2` | Little CMS 2.19.1, library only (Gershwin's Color pane) | `/usr/lib/liblcms2.so.2`, `lcms2.h`, `lcms2_plugin.h`, `lcms2.pc` | nextbsd/nextbsd-gershwin-support#1 |
| `zstd` | Zstandard 1.5.7, library only (base has only its private `libprivatezstd`) | `/usr/lib/libzstd.so.1`, `zstd.h`, `zstd_errors.h`, `zdict.h`, `libzstd.pc` | nextbsd/nextbsd-gershwin-support#3 |
| `lz4` | LZ4 1.10.0, library only | `/usr/lib/liblz4.so.1`, `lz4.h`, `lz4hc.h`, `lz4frame.h`, `liblz4.pc` | nextbsd/nextbsd-gershwin-support#3 |
| `libfuse` | libfuse 3.18.3, library only, with patch 0001 for user mounts (below) | `/usr/lib/libfuse3.so.4`, `/usr/include/fuse3/`, `fuse3.pc` | nextbsd/nextbsd-gershwin-support#3 |
| `squashfs-tools-ng` | squashfs-tools-ng 1.3.2: libsquashfs (AppImage icons and `.desktop` files without mounting) and the tools; gzip, xz, lz4, zstd and bzip2, no LZO | `/usr/lib/libsquashfs.so.1`, `/usr/include/sqfs/`, `libsquashfs1.pc`; `gensquashfs`, `rdsquashfs`, `sqfs2tar`, `sqfsdiff`, `tar2sqfs` and their man pages | nextbsd/nextbsd-gershwin-support#3 |
| `squashfuse` | squashfuse 0.6.5 on libfuse3, the same decompressors | `/usr/bin/squashfuse`, `/usr/bin/squashfuse_ll` and their man pages | nextbsd/nextbsd-gershwin-support#3 |
| `xdotool` | xdotool 4.20260303.1 (Gershwin's Whisper types text into windows with it), on libX11, libXtst and libXinerama from nextbsd-xlibs and libxkbcommon from nextbsd-displayserver-support. An X client, so under `/usr/X11` | `/usr/X11/bin/xdotool`, `/usr/X11/lib/libxdo.so.4`, `/usr/X11/include/xdo.h`, `/usr/X11/lib/pkgconfig/libxdo.pc`, `xdotool.1` | nextbsd/nextbsd-gershwin-support#2 |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only the harness in this repo.

## Mounting a squashfs image as a user

Exactly what an AppImage's type-2 runtime does on Linux (E24 D12), with no
DiskArbitration and no `/Volumes`: the mount point is private, and the user
never sees it. For an image such as `Firefox.AppImage` or `Firefox.squashfs`,
as the user:

1. `mkdtemp("$TMPDIR/.mount_FirefoXXXXXX")`: `.mount_`, the first six
   characters of the file name, then the random part; `$TMPDIR` defaults to
   `/tmp`. The directory belongs to the user, mode `0700`.
2. Mount the squashfs payload there read-only through libfuse:
   `squashfuse -o ro[,offset=N] <image> <dir>` (`offset=` is where an
   AppImage's payload starts after its ELF runtime). libfuse opens
   `/dev/fuse` and runs `/sbin/mount_fusefs`, which mounts as the user.
3. Set `APPDIR=<dir>` and run the application from it.
4. When it exits, unmount as the same user, `umount <dir>` (`unmount(2)`;
   no setuid `fusermount` exists or is needed), or end the `squashfuse`
   process, which then unmounts with `unmount(2)` itself. Then
   `rmdir <dir>`.

What makes that work for a normal user on NextBSD:

- **Kernel:** FUSE is compiled in (`options FUSEFS`, nextbsd/nextbsd-kernel#60)
  and `vfs.usermount=1` is the default (nextbsd-kernel patch 0008), so a user
  may mount on, and unmount, a directory they own. A user mount is always
  `nosuid`. `allow_other` stays root-only, and isn't needed.
- **`/dev/fuse`:** the kernel creates it `0666 root:operator`, and neither the
  base nor nextbsd-overlays has a devfs rule that changes it, so no
  configuration is needed.
- **libfuse (patch `patches/libfuse/0001`):** runs `/sbin/mount_fusefs` by
  absolute path (upstream looks it up in `PATH`, which for a user usually
  lacks `/sbin`); before mounting, checks it can run it, that
  `vfs.usermount` is 1 and that the user owns the mount point, and on a
  failure to open `/dev/fuse` says whether access or kernel support is
  missing; and treats an `unmount(2)` of a file system the user already
  unmounted as done rather than an error.

The AppImage runtime and Gershwin's Workspace (opening a plain `.squashfs`)
each carry out these steps themselves; this repo provides the library and the
programs they use.

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

`build-gershwin-support.sh` runs inside the `nextbsd-toolchain`
container (clang/lld 19.1.7 and the LLVM binutils, meson, ninja, cmake,
pkgconf, autotools) with compat's `continuous` base, then
nextbsd-displayserver-support's (`/usr`) and nextbsd-xlibs' (`/usr/X11`)
`continuous` artifacts, staged as the cross sysroot in that order. Their
files are only built against: the artifact never carries them. Until
nextbsd-xlibs#9 drops it, xlibs still carries a `/usr/X11` copy of
libxkbcommon (same version); the build checks that pkgconf resolves
`xkbcommon.pc` in `/usr/libdata/pkgconfig` and logs where each of xdotool's
`.pc` files came from. It needs:

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged NextBSD base with nextbsd-displayserver-support in `/usr` and nextbsd-xlibs in `/usr/X11` (scratch: components are installed into it) |
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
   plain upstream Makefile told the target OS and compiler (zstd, lz4 and
   xdotool, which have no configure; `uname` on the runner says Linux).
   xdotool's Makefile is also given its X compiler and linker flags from
   pkgconf, since it would ask `pkg-config` and fall back to `/usr/local`.
4. **Stage**: check and tidy the install, then copy it into `$SYSROOT`, so
   later components find its headers, libraries and `.pc` files through the
   normal sysroot search, and into `$DESTDIR`, the published artifact.

**Checks the build enforces:** nothing installs outside `/usr/bin`, `/usr/sbin`,
`/usr/lib`, `/usr/libexec`, `/usr/include`, `/usr/libdata/pkgconfig` and
`/usr/share/man`, or for an X client `/usr/X11/bin`, `/usr/X11/lib`,
`/usr/X11/include` and `/usr/X11/share/man` (so no `/usr/local`, `/etc`, info
or locale files); no staged file replaces a file already in the sysroot (the
base, nextbsd-displayserver-support's `/usr` files, or nextbsd-xlibs'
`/usr/X11`); `.pc` files are moved to the prefix's
pkgconfig directory, must say `prefix=` that prefix (or, with no `prefix`
variable, `libdir=<prefix>/lib`) and may not name `/usr/local` or a build
path; libraries carry their upstream soname and link what they should, and
the minimal builds link none of the optional libraries they leave out (cross
`readelf -d`); xdotool's every `DT_NEEDED` is a library in the sysroot's
`/lib`, `/usr/lib` or `/usr/X11/lib`, and it carries no RPATH; pkgconf (never
freedesktop's pkg-config, E24 D1) searches only the sysroot
(`/usr/libdata/pkgconfig` and `/usr/X11/lib/pkgconfig`). Static and libtool archives are dropped,
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
