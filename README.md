# ffmpeg-static

A static, GPL build of [FFmpeg](https://ffmpeg.org) for Linux (x86_64 and arm64): upstream commit
`ce3c09c101` (`n8.1.2-21-gce3c09c101`, release/8.1, 2026-06-29) **plus one scheduler fix**, built from
source in this repository's release workflow.

It is the same ffmpeg source commit, with the same x264 / x265 / LAME / Opus / FreeType / HarfBuzz / dav1d
revisions and configure options, as the prebuilt static build `autobuild-2026-06-30-13-34` of
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds). The goal is that its encoders and `drawtext`
produce the same output as that build; what has been measured toward that so far, and what has not yet been
shown for the released binaries, is under [Verification](#verification). It differs in two ways, both written down:

1. **The patch** (`patches/0001-…patch`): `choose_input()` in `fftools/ffmpeg_filter.c` no longer elects a
   filtergraph input the graph has already closed. Upstream elects it, the filter thread then waits for a
   frame from a decoder that will never send one, and ffmpeg stops making progress and never exits. This
   happens on filtergraphs with many inputs where one input's last reference ends before the others. The patch
   differs from upstream only by skipping closed inputs (when every input is closed, upstream's pick is made
   exactly as before).
2. **What is not in it** (`DROPPED.md`): hardware paths and a few libraries Debian bookworm ships no static
   archive for, which were left out rather than linked dynamically. The list is enforced in CI.

## Download and verify

Each [release](../../releases) has, per architecture, the tarball, its `.sha256`, and a `*-source-*.tar.xz`
(the corresponding source), plus a combined `SHA256SUMS`. No account or token is needed:

```sh
V=n8.1.2-21-gce3c09c101-20260630-nodaro1
curl -fsSL -O "https://github.com/nodaroai/ffmpeg-static/releases/download/$V/ffmpeg-n8.1.2-21-gce3c09c101-linux64-gpl-8.1-nodaro1.tar.xz"
curl -fsSL -O "https://github.com/nodaroai/ffmpeg-static/releases/download/$V/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
tar -xf ffmpeg-*-linux64-*.tar.xz
./ffmpeg-*/bin/ffmpeg -version | head -1     # ffmpeg version n8.1.2-21-gce3c09c101-20260630-nodaro1 ...
```

The tarball layout is `<top>/bin/ffmpeg`, `<top>/bin/ffprobe`, `LICENSE.txt`, `SOURCE.txt` (every pinned
revision), `packages.txt` (every Debian package and version used), `buildconf.txt`, `source/`,
`LINK-TRACE.txt` (every static library linked into `ffmpeg` or `ffprobe`, read from the linker map of both)
and `LICENSES/` (the licence text of each of those libraries: the `COPYING` / `LICENSE` files of the ones built
from a pinned commit, the `debian/copyright` of the Debian source package of the others, and the compiler
runtime's), so a copy of the binary carries its licences with it.
Only glibc and the loader are dynamically linked; the binaries are PIE with RELRO, `BIND_NOW` and a
stack protector.

## Rebuild it

The build is meant to be reproducible: the base image is pinned by digest, Debian packages come from a dated
`snapshot.debian.org` archive, every other library by commit, and the archives are packed deterministically.

```sh
IMAGE=debian:bookworm@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858
mkdir -p out
docker run --rm -e BASE_IMAGE="$IMAGE" -v "$PWD":/src:ro -v "$PWD/out":/out "$IMAGE" bash /src/build.sh
sha256sum out/*.tar.xz
```

What has been compared: the release workflow (`.github/workflows/release.yml`) builds every architecture twice
on GitHub-hosted runners (`ubuntu-24.04`, `ubuntu-24.04-arm`) and refuses to publish unless the two builds are
byte-identical. That is the only comparison made. A local rebuild on another host (a different CPU count, since
the build runs `make -j"$(nproc)"`, or a different Docker setup) has not yet been compared with a release, so do
not expect its sha256 to equal the release's `SHA256SUMS` until that has been checked. Pass `BASE_IMAGE` exactly
as above: `SOURCE.txt` records it, and it reads `unrecorded` (a different file, a different tarball) when omitted.
The source archives (`*-source-*.tar.xz`) are covered by the same two-build comparison.

Before anything is published, the workflow also runs `check-source-offer.sh` on each architecture's tarball and
source archive and fails (publishing nothing) unless the link trace is not empty, the source archive holds a
source tarball for every library the trace lists (the pinned-commit tarballs, and for each Debian library its
`.dsc` and every file the `.dsc` lists), and the binary tarball holds the licence text of every one of them.

## Cutting a release

Change the pins in `build.sh` (and `EXTRA_VERSION` / the `-nodaro<N>` suffix), update the tests and
`DROPPED.md` if the component set moved, then push a tag equal to `<describe>-<extra version>`, for example
`n8.1.2-21-gce3c09c101-20260630-nodaro1` (a leading `v` is accepted). The workflow checks the tag against
`build.sh`, builds, checks reproducibility and creates the release.

## Verification

The unpatched ffmpeg stalls on the many-input graph described above at a rate that depends on timing and CPU
quota. The numbers below are the measurement behind the patch.

Setup: a 6-input graph that tiles six seeked files into one picture, launched
round-robin with the unpatched build and the patched build on the same synthetic sources, on a self-hosted
runner with a 2-vCPU quota, two jobs at a time, on one CPU model. A launch counts as stalled when it makes no
progress for 25 seconds.

| build | launches | stalled | failed |
|---|---|---|---|
| unpatched (stock static build of the same commit) | 397 | 43 of 397 (10.8%) | 0 |
| patched | 394 | 0 of 394 | 0 |

Output parity: both builds use the same x264 (core 165, same options string). In 2 of the 3 jobs every finished
launch of both builds had one and the same file md5 (and decoded-picture md5); in 15 of 15 follow-up jobs (6
renders per build each, same sources) the file md5 and every frame CRC matched. One job did not match: its
unpatched and patched outputs were each stable across about 130 launches but differed from each other; it was
not reproduced in the 15 follow-up jobs on the same kind of hosts and the cause is not known. The unpatched build
exited 255 once in each of 3 follow-up jobs (output complete and identical); the patched build never exited
non-zero.

Limits, stated plainly:

- These numbers were taken with an earlier form of the fix. That form skipped closed inputs and, when every
  open input was closed, took the lowest-numbered one. The patch in this repository keeps upstream's own pick
  (the input with the most failed buffersrc requests) among the inputs that are not closed. The stall
  and parity measurement has not yet been repeated with this form of the patch.
- The binaries measured were an earlier build; the current ones differ from them (hardening flags, a pinned
  Debian snapshot). The measurement has not yet been repeated on them.
- arm64 was built and smoke-tested, not run on the stall venue (x86_64 only).

## Licence

GPL-3.0-or-later; see `LICENSE.md` (including the written offer of source) and `COPYING.GPLv3`. This
repository is not affiliated with the FFmpeg project.
