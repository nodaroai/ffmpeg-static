#!/usr/bin/env bash
# Build a static ffmpeg: upstream ffmpeg at commit ce3c09c101 (n8.1.2-21) plus the
# patches in ./patches, on Debian bookworm, for the architecture it runs on.
#
#   docker run --rm -e BASE_IMAGE="$IMAGE" -v "$PWD":/src:ro -v "$PWD/out":/out "$IMAGE" \
#     bash /src/build.sh
#
# where IMAGE is the debian:bookworm@sha256:<digest> pinned in
# .github/workflows/release.yml.
#
# Output in /out:
#   ffmpeg-<describe>-<linux64|linuxarm64>-gpl-8.1-nodaro<N>.tar.xz (+ .sha256)
#       <top>/bin/ffmpeg, <top>/bin/ffprobe, LICENSE.txt, SOURCE.txt, packages.txt,
#       buildconf.txt, source/ (the patches and this script)
#   ffmpeg-<describe>-nodaro<N>-source-<linux64|linuxarm64>.tar.xz (+ .sha256)
#       the corresponding source: ffmpeg at the commit, every library built from
#       source, and the Debian source packages of every library linked in statically
#
# WHY IT EXISTS: ffmpeg's filter scheduler can elect a filtergraph input the
# graph has already closed and then wait on it forever (patches/0001). The fix
# is not in any release, so this builds ffmpeg with it.
#
# What is the same as the prebuilt static build of this commit it follows
# (BtbN/FFmpeg-Builds, release autobuild-2026-06-30-13-34):
#   - ffmpeg source: that exact commit (+ the patch);
#   - libx264, libx265, libmp3lame, libopus, libfreetype, and also libharfbuzz
#     and libdav1d (Debian has no static archive of either): built from the
#     exact commits / revision those builds pinned (their scripts.d at
#     7a83528ea3431e9eca982a712bc3a7cd0789d5d0, the last commit before the
#     2026-06-30 snapshot), with the same configure options and the same
#     hardening flags (FORTIFY_SOURCE=2, stack protector, stack clash
#     protection, RELRO + BIND_NOW), so the encoders and drawtext produce the
#     same output;
#   - the version line is that build's plus a -nodaro<N> suffix.
# What is different: every other library comes from Debian bookworm, linked
# statically. A library Debian cannot supply statically is dropped, but only
# the ones in EXPECTED_DROPPED: any other drop (or a listed one that now links)
# fails the build, and the components that go with them are pinned in
# stock-only.<arch>.txt (written up in DROPPED.md).
#
# Reproducibility: the inputs are pinned. The base image is named by digest, the
# Debian packages come from a dated snapshot.debian.org archive (APT_SNAPSHOT),
# meson is pinned, lame's svn export is checked by content hash, the C sources
# are pinned by commit, SOURCE_DATE_EPOCH is fixed, and the tarball is packed
# deterministically (sorted, fixed mtime/owner, single-threaded xz). SOURCE.txt
# and packages.txt in the tarball record all of it.
#
# Gates, all fatal: the described version equals the pin, the required and the
# approved optional components exist, nothing but libc/libm/ld.so is
# dynamically linked, the binaries are PIE + RELRO + BIND_NOW + stack-protected,
# and a real encode of every required encoder runs.
set -euo pipefail

# --- pins ---------------------------------------------------------------
FFMPEG_COMMIT="ce3c09c101c83add623774d414a9f9498caf5c25"
FFMPEG_DESCRIBE="n8.1.2-21-gce3c09c101"
# The extra version: the date of the snapshot of the prebuilt this follows.
EXTRA_VERSION="20260630-nodaro1"
X264_COMMIT="0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee"
X265_COMMIT="7b3d1f515318f73056abd9e99944e9f79db090bd"
LAME_SVN_REV="6531"
OPUS_COMMIT="f8f99516092f4311a9b0784f190ff982df8eb2e6"
FREETYPE_COMMIT="7e0e56f84fd53cf38378d33c8fc8f92d12ab9ac6"
# Debian ships no static harfbuzz, so it is built too, at the prebuilt's commit.
HARFBUZZ_COMMIT="22ea52f42fa4fc168be91ef4e56aee3affda6e28"
# ... and dav1d (the AV1 decoder ffmpeg prefers; Debian has no static archive).
DAV1D_COMMIT="1718ff9aded99f0a89f5c7940d6afb8948301e33"

# Debian bookworm as of this date; the base image (by digest, in the workflow)
# is from before it. Moving it moves every Debian library, so it is a pin.
APT_SNAPSHOT="20261011T120000Z"
MESON_VERSION="1.12.1"
# sha256 over the sorted per-file sha256 list of `svn checkout` r6531 (without
# .svn): svn.code.sf.net has no content addressing of its own.
LAME_TREE_SHA256="d63092883b0ecd8d556efa645a636774763cc1477d5bc6ddf4db66d4d3d91dba"
# The prebuilt's snapshot time (2026-06-30 13:34 UTC): timestamps embedded by
# the build and in the tarball.
export SOURCE_DATE_EPOCH=1782826440
BASE_IMAGE="${BASE_IMAGE:-unrecorded}"

SRC="${SRC:-/src}"
OUT="${OUT:-/out}"
WORK="${WORK:-/work}"
PREFIX="$WORK/prefix"
JOBS="$(nproc)"

case "$(dpkg --print-architecture)" in
  amd64) TAR_ARCH="linux64";    X86=1 ;;
  arm64) TAR_ARCH="linuxarm64"; X86=0 ;;
  *) echo "unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

# Components the build must contain; a miss here fails the build, it is never
# silently dropped. Everything else is OPTIONAL_FLAGS and may fall away.
REQUIRED_ENCODERS="libx264 libx265 libmp3lame libopus aac"
REQUIRED_FILTERS="drawtext xfade afir loudnorm"
# Optional libraries Debian bookworm has no static archive for (enabling them
# would make the binary depend on the host's shared libraries). This is the
# approved set: a library missing from the build that is not listed here, or a
# listed one that now builds, fails the build. Keep DROPPED.md in step.
EXPECTED_DROPPED="--enable-libgme --enable-libsoxr --enable-libsvtav1 --enable-libvidstab"
REQUIRED_CONFIG="--enable-gpl --enable-version3 --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus --enable-libfreetype --enable-fontconfig --enable-libharfbuzz --enable-libfribidi"

SRCPKG="$WORK/srcpkg"   # the corresponding source, packed at the end
mkdir -p "$WORK" "$OUT" "$PREFIX" "$SRCPKG/debian"
cd "$WORK"

retry() { local n=0; until "$@"; do n=$((n + 1)); [ "$n" -ge 5 ] && return 1; echo "retry $n: $*" >&2; sleep $((n * 10)); done; }

echo "::group::apt (snapshot.debian.org $APT_SNAPSHOT)"
export DEBIAN_FRONTEND=noninteractive
# The package versions are those of one dated archive, not "whatever is newest
# when this runs". (http: the base image has no CA bundle yet; apt verifies the
# archive's signature.)
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<APT
Types: deb deb-src
URIs: http://snapshot.debian.org/archive/debian/${APT_SNAPSHOT}/
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://snapshot.debian.org/archive/debian-security/${APT_SNAPSHOT}/
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
APT
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\nAcquire::http::Timeout "60";\n' > /etc/apt/apt.conf.d/99snapshot
retry apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential git subversion ca-certificates curl wget xz-utils nasm yasm pkg-config cmake \
  autoconf automake libtool autopoint gettext python3 file patch fontconfig fonts-dejavu-core \
  zlib1g-dev libbz2-dev liblzma-dev libgmp-dev libssl-dev libxml2-dev libsoxr-dev \
  libfontconfig-dev libfribidi-dev libass-dev python3-pip ninja-build \
  libvorbis-dev libogg-dev libtheora-dev libvpx-dev libaom-dev libsvtav1enc-dev \
  libwebp-dev libopenjp2-7-dev libzimg-dev libvidstab-dev librubberband-dev \
  libsnappy-dev libxvidcore-dev libtwolame-dev libopencore-amrnb-dev libopencore-amrwb-dev libgme-dev
pip3 install -q --break-system-packages "meson==${MESON_VERSION}"
dpkg-query -W -f='${binary:Package} ${Version}\n' | LC_ALL=C sort > "$WORK/packages.txt"
echo "::endgroup::"

# Fetch one commit without the history: by SHA when the server allows it, else
# a blobless clone (Bitbucket does not serve arbitrary SHAs shallowly).
fetch_commit() { # <url> <sha> <dir>
  rm -rf "$3"; mkdir -p "$3"; ( cd "$3"
    git init -q
    git remote add origin "$1"
    if retry git fetch -q --depth 1 origin "$2" 2>/dev/null; then git checkout -q FETCH_HEAD
    else
      rm -rf .git && git init -q && git remote add origin "$1"
      retry git fetch -q --filter=blob:none origin && git checkout -q "$2"
    fi
    [ "$(git rev-parse HEAD)" = "$2" ] )
  # Keep the pristine tree (git archive: no .git, deterministic) before any build edit.
  git -C "$3" archive --format=tar --prefix="$3-$2/" "$2" > "$SRCPKG/$3-$2.tar"
}

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
# The prebuilt's base image sets these for every library it builds (BtbN's
# FFmpeg-Builds images/base-linux64 at the same commit): -O2 -pipe -fPIC -DPIC plus FORTIFY,
# stack protector and stack clash protection, and RELRO + BIND_NOW at link.
# dav1d, freetype and harfbuzz parse untrusted media and fonts.
HARDEN_CFLAGS="-O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection"
HARDEN_LDFLAGS="-Wl,-z,relro,-z,now"
export CFLAGS="$HARDEN_CFLAGS" CXXFLAGS="$HARDEN_CFLAGS" LDFLAGS="$HARDEN_LDFLAGS"

echo "::group::x264"
fetch_commit https://code.videolan.org/videolan/x264.git "$X264_COMMIT" x264
( cd x264
  ./configure --prefix="$PREFIX" --disable-cli --enable-static --enable-pic --disable-lavf --disable-swscale
  make -j"$JOBS" && make install )
echo "::endgroup::"

echo "::group::x265 (8 + 10 + 12 bit, as the prebuilt)"
fetch_commit https://bitbucket.org/multicoreware/x265_git.git "$X265_COMMIT" x265
( cd x265
  sed -i '1i#include <cstdint>' source/dynamicHDR10/json11/json11.cpp
  common=(-DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_ASM_NASM_FLAGS=-w-macro-params-legacy -DENABLE_ALPHA=ON)
  mkdir 8bit 10bit 12bit
  cmake "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON -DMAIN12=ON -S source -B 12bit
  cmake "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON -S source -B 10bit
  cmake "${common[@]}" -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON -S source -B 8bit
  make -C 12bit -j"$JOBS"; make -C 10bit -j"$JOBS"; make -C 8bit -j"$JOBS"
  cd 8bit
  mv ../12bit/libx265.a libx265_main12.a; mv ../10bit/libx265.a libx265_main10.a; mv libx265.a libx265_main.a
  ar -M <<'AR'
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
AR
  make install
  # x265's install rule does not write the pkg-config file on this platform
  # (the prebuilt's cross toolchain did get one); ffmpeg finds x265 through it.
  mkdir -p "$PREFIX/lib/pkgconfig"
  if [ -f x265.pc ]; then cp x265.pc "$PREFIX/lib/pkgconfig/x265.pc"
  else
    x265_build="$(sed -n 's/^#define X265_BUILD \([0-9]*\).*/\1/p' "$PREFIX/include/x265.h" "$PREFIX/include/x265_config.h" | head -1)"
    cat > "$PREFIX/lib/pkgconfig/x265.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: ${x265_build:-0}
Libs: -L\${libdir} -lx265
Cflags: -I\${includedir}
PC
  fi
  echo "Libs.private: -lstdc++ -lm -ldl -lpthread" >> "$PREFIX/lib/pkgconfig/x265.pc" )
echo "::endgroup::"

echo "::group::lame r$LAME_SVN_REV"
retry sh -c "rm -rf lame && svn checkout -q 'https://svn.code.sf.net/p/lame/svn/trunk/lame@${LAME_SVN_REV}' lame"
# An svn revision is not a content hash: check the tree against the pinned one.
lame_sha="$( cd lame && find . -path ./.svn -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1 )"
[ "$lame_sha" = "$LAME_TREE_SHA256" ] || { echo "lame r$LAME_SVN_REV tree is $lame_sha, expected $LAME_TREE_SHA256" >&2; exit 1; }
tar -C . --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner --exclude=.svn \
  --transform="s,^lame,lame-r${LAME_SVN_REV}," -cf "$SRCPKG/lame-r${LAME_SVN_REV}.tar" lame
( cd lame
  autoreconf -i
  nasm_flag=(); [ "$X86" = 1 ] && nasm_flag=(--enable-nasm)
  CFLAGS="$CFLAGS -DNDEBUG -Wno-error=incompatible-pointer-types" \
    ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic "${nasm_flag[@]}" \
      --disable-gtktest --disable-cpml --disable-frontend --disable-decoder
  make -j"$JOBS" && make install )
echo "::endgroup::"

echo "::group::opus"
fetch_commit https://github.com/xiph/opus.git "$OPUS_COMMIT" opus
( cd opus
  ./autogen.sh
  autoreconf -isf
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic --disable-extra-programs
  make -j"$JOBS" && make install )
echo "::endgroup::"

echo "::group::freetype + harfbuzz (the prebuilt's order: freetype, harfbuzz on it, freetype with harfbuzz)"
fetch_commit https://gitlab.freedesktop.org/freetype/freetype.git "$FREETYPE_COMMIT" freetype
( cd freetype
  ./autogen.sh
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic --without-harfbuzz
  make -j"$JOBS" && make install )
fetch_commit https://github.com/harfbuzz/harfbuzz.git "$HARFBUZZ_COMMIT" harfbuzz
( cd harfbuzz
  mkdir build && cd build
  meson setup --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static -Db_pie=true \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
    -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Ddoc_tests=false -Dutilities=disabled ..
  ninja -j"$JOBS" && ninja install
  echo "Libs.private: -lpthread -lstdc++" >> "$PREFIX/lib/pkgconfig/harfbuzz.pc" )
( cd freetype
  make distclean
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --with-pic --with-harfbuzz=yes
  make -j"$JOBS" && make install
  echo "Libs.private: -lharfbuzz" >> "$PREFIX/lib/pkgconfig/freetype2.pc" )
echo "::endgroup::"

echo "::group::dav1d"
fetch_commit https://code.videolan.org/videolan/dav1d.git "$DAV1D_COMMIT" dav1d
( cd dav1d
  mkdir build && cd build
  meson setup --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static -Denable_tools=false -Denable_tests=false ..
  ninja -j"$JOBS" && ninja install )
echo "::endgroup::"

echo "::group::ffmpeg $FFMPEG_DESCRIBE + patches"
rm -rf ffmpeg
retry git clone -q --filter=blob:none --no-checkout https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg
git checkout -q "$FFMPEG_COMMIT"
git archive --format=tar --prefix="ffmpeg-${FFMPEG_COMMIT}/" "$FFMPEG_COMMIT" > "$SRCPKG/ffmpeg-${FFMPEG_COMMIT}.tar"
# The version line is `git describe`; a shallow clone without tags would print
# a bare hash and break the pin check (the e2e test greps for the describe).
[ "$(git describe --tags --always)" = "$FFMPEG_DESCRIBE" ] || { echo "describe is $(git describe --tags --always), expected $FFMPEG_DESCRIBE" >&2; exit 1; }
git -c user.name=build -c user.email=build@invalid apply --check "$SRC"/patches/*.patch
for p in "$SRC"/patches/*.patch; do git apply "$p"; done
echo "::endgroup::"

# Debian ships both lib<x>.so and lib<x>.a, and ld prefers the .so. A directory
# holding ONLY the static archives (everything but glibc's own, which stays
# dynamic) searched first makes every Debian library link statically; a library
# with no archive falls through to its .so and the ldd gate below fails loudly.
STATIC_DIR="$WORK/static-libs"; mkdir -p "$STATIC_DIR"
MULTIARCH="$(gcc -dumpmachine)"
for a in /usr/lib/"$MULTIARCH"/*.a; do
  case "$(basename "$a")" in
    libc.a|libm.a|libmvec.a|libpthread.a|libdl.a|librt.a|libutil.a|libresolv.a|libanl.a|libBrokenLocale.a|libc_nonshared.a|libg.a|libcrypt.a|libthread_db.a|libnsl.a|libfreetype.a|libharfbuzz*.a) ;;
    *) ln -sf "$a" "$STATIC_DIR/" ;;
  esac
done

# Optional libraries (each is dropped, never faked, if Debian cannot link it).
# flag|archives it needs. A library Debian has no static archive for is not
# enabled (a shared one would make the binary depend on the host's libraries).
OPTIONAL_CANDIDATES=(
  "--enable-libxml2|libxml2.a" "--enable-libsoxr|libsoxr.a" "--enable-openssl|libssl.a,libcrypto.a"
  "--enable-libass|libass.a" "--enable-libvorbis|libvorbis.a,libvorbisenc.a" "--enable-libtheora|libtheoraenc.a,libtheoradec.a"
  "--enable-libaom|libaom.a" "--enable-libdav1d|libdav1d.a" "--enable-libvpx|libvpx.a" "--enable-libsvtav1|libSvtAv1Enc.a"
  "--enable-libwebp|libwebp.a,libwebpmux.a" "--enable-libopenjpeg|libopenjp2.a" "--enable-libzimg|libzimg.a"
  "--enable-libvidstab|libvidstab.a" "--enable-librubberband|librubberband.a" "--enable-libsnappy|libsnappy.a"
  "--enable-libxvid|libxvidcore.a" "--enable-libtwolame|libtwolame.a"
  "--enable-libopencore-amrnb|libopencore-amrnb.a" "--enable-libopencore-amrwb|libopencore-amrwb.a" "--enable-libgme|libgme.a"
)
OPTIONAL_FLAGS=(); NO_ARCHIVE=()
for c in "${OPTIONAL_CANDIDATES[@]}"; do
  flag="${c%%|*}"; ok=1
  IFS=, read -ra archives <<<"${c#*|}"
  for a in "${archives[@]}"; do [ -e "$STATIC_DIR/$a" ] || [ -e "$PREFIX/lib/$a" ] || ok=0; done
  if [ "$ok" = 1 ]; then OPTIONAL_FLAGS+=("$flag"); else NO_ARCHIVE+=("$flag"); echo "NO STATIC ARCHIVE: $flag"; fi
done
COMMON_FLAGS=(
  --prefix="$WORK/ffout" --pkg-config-flags=--static --enable-gpl --enable-version3 --disable-debug
  --disable-doc --disable-ffplay --enable-pic --enable-iconv --enable-zlib --enable-lzma --enable-gmp
  --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libopus --enable-libfreetype
  --enable-fontconfig --enable-libharfbuzz --enable-libfribidi
  --extra-cflags="-I$PREFIX/include $HARDEN_CFLAGS" --extra-ldflags="-L$PREFIX/lib -L$STATIC_DIR $HARDEN_LDFLAGS"
  --extra-libs="-Wl,--start-group -lfreetype -lharfbuzz -Wl,--end-group -lstdc++ -lm -lpthread"
  --extra-ldexeflags="-pie -static-libgcc -static-libstdc++"
  --extra-version="${EXTRA_VERSION}"
)

echo "::group::configure"
DROPPED=()
for attempt in $(seq 1 25); do
  if ./configure "${COMMON_FLAGS[@]}" "${OPTIONAL_FLAGS[@]}" >configure.log 2>&1; then break; fi
  tail -n 15 configure.log
  grep -n -B2 -A25 -E "check_pkg_config|pkg-config.*(fail|not)" ffbuild/config.log 2>/dev/null | tail -n 60 || true
  tail -n 40 ffbuild/config.log 2>/dev/null || true
  cat "$PREFIX/lib/pkgconfig/x265.pc" 2>/dev/null || true
  # "ERROR: libfoo >= 1.2 not found using pkg-config" / "ERROR: libfoo not found"
  token="$(grep -m1 -oE '^ERROR: [A-Za-z0-9_]+' configure.log | cut -d' ' -f2 || true)"
  token="${token//_/-}"
  flag="--enable-${token#lib}"; flag_lib="--enable-${token}"
  hit=""
  for f in "${OPTIONAL_FLAGS[@]}"; do [ "$f" = "$flag_lib" ] || [ "$f" = "$flag" ] || [ "$f" = "--enable-lib${token}" ] && hit="$f"; done
  [ -n "$hit" ] || { echo "configure failed on a required component (token '${token}')" >&2; exit 1; }
  echo "DROPPING $hit (Debian cannot link it statically)"; DROPPED+=("$hit")
  NEW=(); for f in "${OPTIONAL_FLAGS[@]}"; do [ "$f" = "$hit" ] || NEW+=("$f"); done; OPTIONAL_FLAGS=("${NEW[@]}")
done
[ -f ffbuild/config.mak ] || { echo "configure never succeeded" >&2; exit 1; }
printf '%s\n' "${NO_ARCHIVE[@]:-}" "${DROPPED[@]:-}" > "$OUT/dropped-at-configure.txt"
# The set of optional libraries that are not in the build must be exactly the
# approved one: a silent loss (a configure failure) or a surprise gain both stop here.
actual_dropped="$(sed '/^$/d' "$OUT/dropped-at-configure.txt" | LC_ALL=C sort | tr '\n' ' ')"
expected_dropped="$(printf '%s\n' $EXPECTED_DROPPED | LC_ALL=C sort | tr '\n' ' ')"
[ "$actual_dropped" = "$expected_dropped" ] || {
  echo "unexpected dropped libraries: build has [$actual_dropped], approved [$expected_dropped]" >&2
  echo "(a library that fell away is a regression; one that now builds needs EXPECTED_DROPPED and DROPPED.md updated)" >&2
  exit 1; }
echo "::endgroup::"

echo "::group::make"
make -j"$JOBS"
make install
echo "::endgroup::"

# Which Debian static archives ended up in the binaries: link ffmpeg once more
# with a linker map (the shipped binaries are untouched), take every archive the
# linker pulled a member from, map it to its Debian package, and download that
# package's source. (The compiler runtime in /usr/lib/gcc and glibc, which stays
# dynamic, are not part of the offer: they carry the GPL system-library exception.)
echo "::group::which Debian libraries are linked in; their source"
rm -f ffmpeg_g
make LDEXEFLAGS="$(sed -n 's/^LDEXEFLAGS=//p' ffbuild/config.mak) -Wl,-Map=$WORK/ffmpeg.map" ffmpeg_g >/dev/null
grep -oE '^/[^ ()]+\.a\(' "$WORK/ffmpeg.map" | tr -d '(' | LC_ALL=C sort -u > "$WORK/linked-archives.txt"
: > "$WORK/linked-debian.txt"
while read -r a; do
  real="$(readlink -f "$a")"
  case "$real" in "$PREFIX"/*|/usr/lib/gcc/*|"$WORK"/*) continue ;; esac
  pkg="$(dpkg -S "$real" | head -1 | cut -d: -f1)"
  [ -n "$pkg" ] || { echo "no Debian package owns $real" >&2; exit 1; }
  dpkg-query -W -f='${source:Package}=${source:Version}\n' "$pkg" >> "$WORK/linked-debian.txt"
done < "$WORK/linked-archives.txt"
LC_ALL=C sort -u -o "$WORK/linked-debian.txt" "$WORK/linked-debian.txt"
[ -s "$WORK/linked-debian.txt" ] || { echo "the link trace found no Debian archive: the trace is broken" >&2; exit 1; }
cat "$WORK/linked-debian.txt"
( cd "$SRCPKG/debian" && retry apt-get source --download-only -qq $(cat "$WORK/linked-debian.txt") )
echo "::endgroup::"

BIN="$WORK/ffout/bin"
strip --strip-unneeded "$BIN/ffmpeg" "$BIN/ffprobe"

echo "::group::gates"
VERSION_LINE="$("$BIN/ffmpeg" -version | head -1)"
echo "$VERSION_LINE"
case "$VERSION_LINE" in "ffmpeg version ${FFMPEG_DESCRIBE}-${EXTRA_VERSION} "*) ;; *) echo "unexpected version line" >&2; exit 1 ;; esac

CONF_LINE="$("$BIN/ffmpeg" -version | grep '^configuration:')"
for f in $REQUIRED_CONFIG; do grep -q -- " $f\( \|\$\)" <<<"$CONF_LINE" || { echo "required configure flag $f missing" >&2; exit 1; }; done
# (captured first: `grep -q` closing the pipe early would fail the pipeline under pipefail)
# every optional library that is not an approved drop is in the final configuration
for c in "${OPTIONAL_CANDIDATES[@]}"; do
  flag="${c%%|*}"
  case " $EXPECTED_DROPPED " in *" $flag "*) continue ;; esac
  grep -q -- " $flag\( \|\$\)" <<<"$CONF_LINE" || { echo "approved library $flag is not in the build configuration" >&2; exit 1; }
done
ENCODERS="$("$BIN/ffmpeg" -hide_banner -encoders 2>/dev/null)"; FILTERS="$("$BIN/ffmpeg" -hide_banner -filters 2>/dev/null)"
for e in $REQUIRED_ENCODERS; do grep -qE "^ [A-Z.]+ $e " <<<"$ENCODERS" || { echo "required encoder $e missing" >&2; exit 1; }; done
for f in $REQUIRED_FILTERS; do grep -qE "^ [A-Z.]+ +$f " <<<"$FILTERS" || { echo "required filter $f missing" >&2; exit 1; }; done

# Only glibc / the loader may be dynamic: the binary is installed by
# `install bin/ffmpeg` into images that carry nothing else.
for b in ffmpeg ffprobe; do
  bad="$(ldd "$BIN/$b" | awk '{print $1}' | sed 's|.*/||' | grep -vE '^(linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libmvec\.so\.1|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|libutil\.so\.1|libresolv\.so\.2|ld-linux-(x86-64|aarch64)\.so\.[0-9]+)$' || true)"
  [ -z "$bad" ] || { echo "$b links dynamically against: $bad" >&2; exit 1; }
done

# Hardening the prebuilt had: position-independent, RELRO, immediate binding,
# stack protector (imported from glibc, so it shows in the dynamic symbols).
for b in ffmpeg ffprobe; do
  dyn="$(readelf -d "$BIN/$b")"; hdr="$(readelf -lW "$BIN/$b")"; syms="$(nm -D "$BIN/$b")"
  grep -q 'BIND_NOW' <<<"$dyn" || { echo "$b lacks BIND_NOW (-z now)" >&2; exit 1; }
  grep -q 'GNU_RELRO' <<<"$hdr" || { echo "$b lacks GNU_RELRO" >&2; exit 1; }
  grep -q 'PIE' <<<"$dyn $(readelf -h "$BIN/$b")" || { echo "$b is not PIE" >&2; exit 1; }
  grep -q '__stack_chk_fail' <<<"$syms" || { echo "$b has no stack protector" >&2; exit 1; }
done

# A real encode of every required encoder, with the font fontconfig finds.
T="$WORK/smoke"; mkdir -p "$T"
"$BIN/ffmpeg" -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=320x240:rate=25:duration=1,drawtext=text='nodaro':fontsize=24:fontcolor=white:x=10:y=10" \
  -f lavfi -i "sine=frequency=440:duration=1" -c:v libx264 -c:a libmp3lame -f mp4 "$T/a.mp4"
"$BIN/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=320x240:rate=25:duration=1" -c:v libx265 -tag:v hvc1 -f mp4 "$T/b.mp4"
"$BIN/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=1" -c:a libopus -f ogg "$T/c.ogg"
for f in a.mp4 b.mp4 c.ogg; do "$BIN/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$T/$f" >/dev/null; done
echo "::endgroup::"

echo "::group::package"
TOP="ffmpeg-${FFMPEG_DESCRIBE}-${TAR_ARCH}-gpl-8.1-nodaro${EXTRA_VERSION##*nodaro}"
rm -rf "$WORK/pkg" && mkdir -p "$WORK/pkg/$TOP/bin" "$WORK/pkg/$TOP/source"
cp "$BIN/ffmpeg" "$BIN/ffprobe" "$WORK/pkg/$TOP/bin/"
cp COPYING.GPLv3 "$WORK/pkg/$TOP/LICENSE.txt"
cp "$SRC"/patches/*.patch "$SRC/build.sh" "$WORK/pkg/$TOP/source/"
cp "$WORK/packages.txt" "$WORK/pkg/$TOP/packages.txt"
"$BIN/ffmpeg" -hide_banner -buildconf > "$WORK/pkg/$TOP/buildconf.txt"
{
  echo "ffmpeg   $FFMPEG_COMMIT ($FFMPEG_DESCRIBE) + source/*.patch"
  echo "x264     $X264_COMMIT"
  echo "x265     $X265_COMMIT"
  echo "lame     svn r$LAME_SVN_REV"
  echo "opus     $OPUS_COMMIT"
  echo "freetype $FREETYPE_COMMIT"
  echo "harfbuzz $HARFBUZZ_COMMIT"
  echo "dav1d    $DAV1D_COMMIT"
  echo "lame     tree sha256 $LAME_TREE_SHA256"
  echo "meson    $MESON_VERSION (pip)"
  echo "base     $BASE_IMAGE"
  echo "apt      snapshot.debian.org/archive/debian/$APT_SNAPSHOT (+ debian-security) -- every package and version in packages.txt"
  echo "other libraries: those Debian bookworm packages, statically linked ($(dpkg --print-architecture))"
  echo "x265     source edit at build time: one added line (#include <cstdint>) in source/dynamicHDR10/json11/json11.cpp, see source/build.sh"
  echo "built by source/build.sh. The complete corresponding source is published beside this tarball in the release:"
  echo "  ffmpeg-${FFMPEG_DESCRIBE}-nodaro${EXTRA_VERSION##*nodaro}-source-${TAR_ARCH}.tar.xz"
  echo "(ffmpeg at the commit, the patches, every library above built from source, and the Debian source packages"
  echo "of the statically linked Debian libraries, at the versions in packages.txt)."
} > "$WORK/pkg/$TOP/SOURCE.txt"
# Deterministic packing: the same files give the same bytes on every run.
tar -C "$WORK/pkg" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner -cf - "$TOP" | xz -9 -T1 > "$OUT/$TOP.tar.xz"
( cd "$OUT" && sha256sum "$TOP.tar.xz" | tee "$TOP.tar.xz.sha256" )
# The corresponding source, held (not a recipe): ffmpeg at the commit, the patches
# and this script, every library built from source, and the Debian source packages
# of every library that is linked in statically.
SRC_TOP="ffmpeg-${FFMPEG_DESCRIBE}-nodaro${EXTRA_VERSION##*nodaro}-source-${TAR_ARCH}"
rm -rf "$WORK/srcout" && mkdir -p "$WORK/srcout/$SRC_TOP"
cp -r "$SRCPKG"/. "$WORK/srcout/$SRC_TOP/"
mkdir -p "$WORK/srcout/$SRC_TOP/build"
cp -r "$SRC"/patches "$WORK/srcout/$SRC_TOP/build/"
cp "$SRC/build.sh" "$WORK/pkg/$TOP/SOURCE.txt" "$WORK/packages.txt" "$WORK/linked-debian.txt" "$WORK/srcout/$SRC_TOP/build/"
tar -C "$WORK/srcout" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner -cf - "$SRC_TOP" | xz -9 -T1 > "$OUT/$SRC_TOP.tar.xz"
( cd "$OUT" && sha256sum "$SRC_TOP.tar.xz" | tee "$SRC_TOP.tar.xz.sha256" )
echo "$TOP" > "$OUT/top.txt"
"$BIN/ffmpeg" -hide_banner -buildconf > "$OUT/buildconf.txt"
echo "::endgroup::"
