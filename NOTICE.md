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
