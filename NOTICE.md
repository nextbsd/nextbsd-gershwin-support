# Upstream sources & licences

`nextbsd-gershwin-support` builds third-party software that only Gershwin uses,
each **under its own upstream licence**. Nothing is vendored: the build fetches
each upstream release tarball pinned in `sources.lock` (URL and SHA-256), and
the licence files inside those tarballs are authoritative. This table records
provenance and does not relicense anything. NextBSD changes, if any, are the
patch files under `patches/<name>/`, under the licence of the file they patch.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-gershwin-support.sh`, `sources.lock`, `cross/`, the `series` files, `.github/workflows/`,
this `NOTICE.md` and `README.md`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `wget` | GNU wget, `https://ftp.gnu.org/gnu/wget/` | 1.25.0 | GPL-3.0-or-later, with the OpenSSL linking exception (`COPYING`, `README`). Optional package only, never the default base (E24 D8) |
| `lcms2` | Little CMS, `https://github.com/mm2/Little-CMS` (release `lcms2.19.1`) | 2.19.1 | MIT (`LICENSE`). The GPL-3.0 fast-float and threaded plugins are not built |
| `zstd` | Zstandard, `https://github.com/facebook/zstd` (release `v1.5.7`), library only | 1.5.7 | BSD-3-Clause, used under it; upstream offers BSD-3-Clause or GPL-2.0-only at the user's choice (`LICENSE`, `COPYING`). The programs are not built |
| `lz4` | LZ4, `https://github.com/lz4/lz4` (release `v1.10.0`), library only | 1.10.0 | BSD-2-Clause (`lib/LICENSE`). The GPL-2.0 `lz4` program is not built |
| `libfuse` | libfuse, `https://github.com/libfuse/libfuse` (release `fuse-3.18.3`), library only | 3.18.3 | LGPL-2.1 for `lib/` and `include/` (`LICENSE`, `LGPL2.txt`), which is all that is built; the GPL-2.0 helpers, examples and tests are not built. NextBSD patch `patches/libfuse/0001` is under the LGPL-2.1 of the file it patches |
| `squashfs-tools-ng` | squashfs-tools-ng, `https://infraroot.at/pub/squashfs/` | 1.3.2 | `COPYING.md`: libsquashfs LGPL-3.0-or-later, with an embedded xxhash32 (BSD-2-Clause) and hash table (MIT); the tools GPL-3.0-or-later. Optional package only, never the default base (E24 D12). Licence texts in `licenses/` |
| `squashfuse` | squashfuse, `https://github.com/vasi/squashfuse` (release `0.6.5`) | 0.6.5 | BSD-2-Clause (`LICENSE`); `squashfs_fs.h` is Phillip Lougher's, used under the same terms with his permission |
