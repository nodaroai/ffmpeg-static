# License

The ffmpeg binaries in the releases of this repository are built with GPL components (libx264, libx265) and
`--enable-version3`, so they are distributed under the **GNU General Public License, version 3 or later**
(`COPYING.GPLv3`; the same text ships in each tarball as `LICENSE.txt`). The libraries linked into them
(x264, x265, LAME, Opus, FreeType, HarfBuzz, dav1d and the Debian libraries listed in `packages.txt`) are
under their own licences, which their source trees carry.

The corresponding source of every release is published as release assets (`*-source-*.tar.xz`): ffmpeg at
the pinned commit, the patch, every library built from source, the Debian source packages of the
statically linked Debian libraries, and the build script. This is the written offer of the source for the
GPL: it is held in the release itself and needs no request.

The build scripts, tests and documentation in this repository are licensed under the GPL-3.0-or-later as
well. The patch under `patches/` is a change to FFmpeg and is licensed as FFmpeg is (LGPL-2.1-or-later for
the file it changes, which the GPL build covers).

This repository is not affiliated with the FFmpeg project.
