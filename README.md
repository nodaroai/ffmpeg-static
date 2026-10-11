# ffmpeg-static

A static, GPL build of [FFmpeg](https://ffmpeg.org) for Linux (x86_64 and arm64): upstream commit
`ce3c09c101` (`n8.1.2-21-gce3c09c101`, release/8.1, 2026-06-29) **plus one scheduler fix**, built from
source in this repository's release workflow.

It is the same ffmpeg source commit, with the same x264 / x265 / LAME / Opus / FreeType / HarfBuzz / dav1d
revisions and configure options, as the prebuilt static build `autobuild-2026-06-30-13-34` of
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), so its encoders and `drawtext` produce the
same output. It differs in two ways, both written down:

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
revision), `packages.txt` (every Debian package and version used), `buildconf.txt`, `source/`.
Only glibc and the loader are dynamically linked; the binaries are PIE with RELRO, `BIND_NOW` and a
stack protector.

## Rebuild it

The build is reproducible: the base image is pinned by digest, Debian packages come from a dated
`snapshot.debian.org` archive, every other library by commit, and the archives are packed deterministically.

```sh
IMAGE=debian:bookworm@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858
mkdir -p out
docker run --rm -e BASE_IMAGE="$IMAGE" -v "$PWD":/src:ro -v "$PWD/out":/out "$IMAGE" bash /src/build.sh
sha256sum out/*.tar.xz        # equals the release's SHA256SUMS for your architecture
```

The release workflow (`.github/workflows/release.yml`) builds every architecture twice on GitHub-hosted
runners and refuses to publish unless the two builds are byte-identical.

## Cutting a release

Change the pins in `build.sh` (and `EXTRA_VERSION` / the `-nodaro<N>` suffix), update the tests and
`DROPPED.md` if the component set moved, then push a tag equal to `<describe>-<extra version>`, for example
`n8.1.2-21-gce3c09c101-20260630-nodaro1` (a leading `v` is accepted). The workflow checks the tag against
`build.sh`, builds, checks reproducibility and creates the release.

## Verification

The measurements behind the patch are in the release notes of each release. The unpatched ffmpeg stalls on
the many-input graph described above at a rate that depends on timing and CPU quota; the patched build was
run against the unpatched one on the same inputs on a 2-vCPU host.

## Licence

GPL-3.0-or-later; see `LICENSE.md` (including the written offer of source) and `COPYING.GPLv3`. This
repository is not affiliated with the FFmpeg project.
