import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * The patched ffmpeg build. The build itself runs in .github/workflows/release.yml;
 * these tests pin the things a reviewer cannot see from a green build: that the
 * patch only skips closed inputs (and keeps upstream's pick and assertion
 * otherwise), that the build is anchored to one source commit, that the
 * libraries the output depends on stay pinned to exact commits, and that the
 * release holds the corresponding source.
 */
const read = rel => readFileSync(new URL(`../${rel}`, import.meta.url), "utf8")
const script = read("build.sh")
const workflow = read(".github/workflows/release.yml")
const patchDir = new URL("../patches/", import.meta.url)
const patchFiles = readdirSync(patchDir).filter(f => f.endsWith(".patch"))

test("exactly one patch, touching only fftools/ffmpeg_filter.c", () => {
  assert.equal(patchFiles.length, 1)
  const patch = readFileSync(new URL(patchFiles[0], patchDir), "utf8")
  const files = [...patch.matchAll(/^diff --git a\/(\S+) b\/\S+$/gm)].map(m => m[1])
  assert.deepEqual(files, ["fftools/ffmpeg_filter.c"])
})

test("the patch header says what, why and upstream", () => {
  const patch = readFileSync(new URL(patchFiles[0], patchDir), "utf8")
  const header = patch.slice(0, patch.indexOf("diff --git"))
  for (const label of ["What:", "Why:", "Upstream:"]) assert.match(header, new RegExp(`^${label}`, "m"), `missing ${label}`)
  assert.match(header, /choose_input/)
})

test("the patch only skips closed inputs: upstream's pick and assertion are untouched", () => {
  const patch = readFileSync(new URL(patchFiles[0], patchDir), "utf8")
  const added = patch.split("\n").filter(l => l.startsWith("+") && !l.startsWith("+++")).join("\n")
  const removed = patch.split("\n").filter(l => l.startsWith("-") && !l.startsWith("---")).join("\n")
  assert.doesNotMatch(added, /getenv|DL_FIX|DL_LOG|DLPROBE|av_log/, "not the env-gated probe")
  // skip an input the graph has already closed, in a second, "open only" election ...
  assert.match(added, /if \(ifp_from_ifilter\(ifilter\)->eof\)\s*\n\+\s*continue;/)
  assert.match(added, /nb_requests > nb_requests_max_open/)
  // ... and when every input is closed, upstream's own pick (the most failed requests) is returned
  assert.match(added, /return best_input_open >= 0 \? best_input_open : best_input;/)
  // upstream's election and its assertion are not edited: the only removed line is the old return
  assert.deepEqual(removed.split("\n").map(l => l.trim()), ["-    return best_input;"])
  assert.doesNotMatch(added, /av_assert0/, "the assertion is neither moved nor changed")
})

test("the build is anchored to one ffmpeg commit whose describe it checks", () => {
  const commit = script.match(/^FFMPEG_COMMIT="([0-9a-f]{40})"/m)
  assert.ok(commit, "build.sh pins the full ffmpeg commit")
  const describe = script.match(/^FFMPEG_DESCRIBE="n[0-9.]+-\d+-g([0-9a-f]+)"/m)
  assert.ok(describe, "build.sh names the describe")
  assert.ok(commit[1].startsWith(describe[1]), `${commit[1]} is not ${describe[1]}`)
  assert.match(script, /git describe --tags --always/)
})

test("x264, x265, lame, opus and freetype are pinned to exact commits / revisions", () => {
  for (const name of ["X264_COMMIT", "X265_COMMIT", "OPUS_COMMIT", "FREETYPE_COMMIT"]) {
    assert.match(script, new RegExp(`^${name}="[0-9a-f]{40}"`, "m"), name)
  }
  assert.match(script, /^LAME_SVN_REV="\d+"/m)
})

test("the version string carries the nodaro suffix and the output is gated on it", () => {
  assert.match(script, /--extra-version="\$\{EXTRA_VERSION\}"/)
  assert.match(script, /^EXTRA_VERSION="\d{8}-nodaro\d+"/m)
})

test("the build gates what can only fail on a plain host", () => {
  assert.match(script, /ldd/, "dynamic-link allowlist")
  assert.match(script, /REQUIRED_/, "required components")
  assert.match(workflow, /node:22-slim/, "smoke on a plain Debian image")
})

test("the workflow builds both architectures on native runners, on a tag", () => {
  assert.match(workflow, /workflow_dispatch:/)
  assert.match(workflow, /tags: \["\*"\]/)
  assert.match(workflow, /ubuntu-24\.04-arm/)
  assert.match(workflow, /ubuntu-24\.04\b/)
  assert.match(workflow, /debian:bookworm/)
})

// --- review round: reproducibility, an approved component set, hardening ---------

test("the patch describes itself as it is: it differs from upstream only by skipping closed inputs", () => {
  const patch = readFileSync(new URL(patchFiles[0], patchDir), "utf8")
  assert.match(patch, /differs from upstream only by skipping\s+closed inputs/)
  // the previous form took the lowest-numbered open input when all were closed; that is gone
  assert.doesNotMatch(patch, /lowest-numbered/)
  assert.doesNotMatch(patch, /Speaker|nodaro-ci|backend\//i, "nothing internal in a public patch header")
})

test("the build is reproducible from its record: base image by digest, apt from a dated snapshot, pip pinned", () => {
  assert.match(workflow, /debian:bookworm@sha256:[0-9a-f]{64}/, "the base image is pinned by digest")
  assert.doesNotMatch(workflow, /debian:bookworm(?!@)/, "no floating debian:bookworm tag")
  assert.match(script, /^APT_SNAPSHOT="\d{8}T\d{6}Z"/m, "apt reads a dated snapshot.debian.org archive")
  assert.match(script, /snapshot\.debian\.org\/archive\/debian\/\$\{?APT_SNAPSHOT/)
  assert.match(script, /snapshot\.debian\.org\/archive\/debian-security\/\$\{?APT_SNAPSHOT/)
  assert.match(script, /^MESON_VERSION="\d+\.\d+\.\d+"/m)
  assert.match(script, /pip3 install [^\n]*meson==\$\{MESON_VERSION\}/, "meson is pinned")
  assert.match(script, /^LAME_TREE_SHA256="[0-9a-f]{64}"/m, "the lame svn export is verified by content hash")
})

test("the tarball is byte-deterministic and the source offer records every package", () => {
  assert.match(script, /--sort=name/)
  assert.match(script, /--mtime=/)
  assert.match(script, /--owner=0 --group=0 --numeric-owner/)
  assert.match(script, /xz -9 -T1|xz -T1 -9/, "single-threaded xz output does not depend on the runner's core count")
  assert.match(script, /dpkg-query -W/, "installed Debian package versions are recorded")
  assert.match(script, /BASE_IMAGE/, "the base image digest is recorded in SOURCE.txt")
  assert.match(script, /APT_SNAPSHOT/, "the snapshot date is recorded in SOURCE.txt")
  assert.match(workflow, /-e BASE_IMAGE=/, "the digest reaches the build")
})

test("an optional library cannot vanish silently: the dropped set is an approved list and every other one is gated", () => {
  const dropped = script.match(/^EXPECTED_DROPPED="([^"]*)"/m)
  assert.ok(dropped, "build.sh declares EXPECTED_DROPPED")
  assert.deepEqual(dropped[1].split(/\s+/).sort(), ["--enable-libgme", "--enable-libsoxr", "--enable-libsvtav1", "--enable-libvidstab"])
  assert.match(script, /dropped-at-configure[^\n]*EXPECTED_DROPPED|EXPECTED_DROPPED[^\n]*dropped-at-configure|unexpected dropped/i)
  // every OPTIONAL_CANDIDATES flag outside EXPECTED_DROPPED is required in the final configuration
  assert.match(script, /for c in "\$\{OPTIONAL_CANDIDATES\[@\]\}"[\s\S]{0,400}CONF_LINE/)
  for (const lib of ["libdav1d", "libaom", "libvpx", "libass", "libzimg", "libwebp", "libopenjpeg"]) {
    assert.match(script, new RegExp(`"--enable-${lib}\\|`), `${lib} is an optional candidate (and therefore gated)`)
    assert.ok(!dropped[1].includes(lib), `${lib} must not be an approved drop`)
  }
})

test("the stock comparison fails the workflow when the dropped components change", () => {
  assert.match(workflow, /diff [^\n]*stock-only/, "stock-only.txt is diffed against a committed list")
  for (const arch of ["linux64", "linuxarm64"]) {
    const list = read(`stock-only.${arch}.txt`)
    assert.match(list, /^encoders h264_nvenc$/m)
    // protocols, bsfs and hwaccels are in the list, not silently empty
    assert.match(list, /^protocols (input|output):srt$/m, `${arch}: protocols`)
    assert.match(list, /^hwaccels /m, `${arch}: hwaccels`)
  }
})

test("the dependency builds carry the prebuilt's hardening flags", () => {
  assert.match(script, /^HARDEN_CFLAGS="-O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection"/m)
  assert.match(script, /^HARDEN_LDFLAGS="-Wl,-z,relro,-z,now"/m)
  assert.match(script, /^export CFLAGS="\$HARDEN_CFLAGS" CXXFLAGS="\$HARDEN_CFLAGS" LDFLAGS="\$HARDEN_LDFLAGS"/m)
  // ffmpeg itself gets the same flags through configure (explicitly, whatever configure does with the environment)
  assert.match(script, /--extra-cflags="[^"]*\$HARDEN_CFLAGS/)
  assert.match(script, /--extra-ldflags="[^"]*\$HARDEN_LDFLAGS/)
  // and the result is checked, not assumed
  assert.match(script, /readelf -[a-z]*d/)
  assert.match(script, /BIND_NOW/)
  assert.match(script, /GNU_RELRO/)
  assert.match(script, /__stack_chk_fail/)
})

test("compare-stock.sh sees protocols, bitstream filters and hwaccels (their listings have no dashed legend)", () => {
  const dir = mkdtempSync(join(tmpdir(), "cmp-"))
  const stub = (name, protocols, bsfs, hwaccels) => {
    const p = join(dir, name)
    writeFileSync(p, `#!/usr/bin/env bash
case "$*" in
  *-protocols*) printf '%b' ${JSON.stringify(protocols)} ;;
  *-bsfs*) printf '%b' ${JSON.stringify(bsfs)} ;;
  *-hwaccels*) printf '%b' ${JSON.stringify(hwaccels)} ;;
  *-buildconf*) printf 'configuration:\\n  --enable-gpl\\n' ;;
  *-version*) echo "ffmpeg version stub" ;;
  *-encoders*|*-decoders*|*-filters*|*-muxers*|*-demuxers*|*-devices*) printf 'Legend:\\n ---\\n V..... libx264 x\\n' ;;
esac
`)
    chmodSync(p, 0o755)
    return p
  }
  const stock = stub("stock",
    "Supported file protocols:\nInput:\n  file\n  srt\n  zmq\nOutput:\n  file\n  srt\n",
    "Bitstream filters:\naac_adtstoasc\nh264_mp4toannexb\nvvc_mp4toannexb\n",
    "Hardware acceleration methods:\ncuda\nvaapi\n")
  const fresh = stub("fresh",
    "Supported file protocols:\nInput:\n  file\nOutput:\n  file\n",
    "Bitstream filters:\naac_adtstoasc\nh264_mp4toannexb\n",
    "Hardware acceleration methods:\n")
  const out = join(dir, "out")
  execFileSync("bash", [fileURLToPath(new URL("../compare-stock.sh", import.meta.url)), stock, fresh, out], { stdio: "pipe" })
  const only = readFileSync(join(out, "stock-only.txt"), "utf8").split("\n").filter(Boolean)
  for (const want of ["protocols input:srt", "protocols input:zmq", "protocols output:srt", "bsfs vvc_mp4toannexb", "hwaccels cuda", "hwaccels vaapi"]) {
    assert.ok(only.includes(want), `${want} missing from stock-only: ${only.join(" | ")}`)
  }
  assert.ok(!only.includes("protocols input:file"), "a protocol both have is not reported")
  const md = readFileSync(join(out, "DROPPED.md"), "utf8")
  assert.match(md, /\*\*protocols:\*\*/)
  assert.match(md, /\*\*bsfs:\*\*/)
  assert.match(md, /\*\*hwaccels:\*\*/)
  rmSync(dir, { recursive: true, force: true })
})

// --- release: reproducibility is a gate, the source offer is held ----------------

test("a release needs two byte-identical builds per architecture and holds the corresponding source", () => {
  assert.match(workflow, /run: \[1, 2\]/, "every architecture is built twice")
  assert.match(workflow, /reproducible:[\s\S]*the two builds differ/)
  assert.match(workflow, /release:[\s\S]*needs: reproducible/, "the release waits for the comparison")
  assert.match(workflow, /contents: write/)
  assert.equal((workflow.match(/contents: write/g) ?? []).length, 1, "write permission on the release job only")
  assert.match(workflow, /gh release create/)
  // the corresponding source is an asset of the release, per architecture
  assert.match(script, /-source-\$\{TAR_ARCH\}/)
  assert.match(script, /git -C "\$3" archive/, "every library built from source is kept pristine")
  assert.match(script, /apt-get source --download-only/, "Debian source packages are downloaded, not just named")
  assert.match(script, /-Wl,-Map=/, "the Debian libraries in the offer are the ones the linker used")
  assert.match(workflow, /tag \$GITHUB_REF_NAME does not match/, "the tag names the version build.sh builds")
})

test("nothing internal is in the public tree", () => {
  for (const rel of ["build.sh", "compare-stock.sh", "README.md", "DROPPED.md", "LICENSE.md", ".github/workflows/release.yml", ".github/workflows/test.yml"]) {
    const text = read(rel)
    assert.doesNotMatch(text, /internal|plan\.nodaro|railway|superpowers|speaker.?view|install-pinned|nodaro-ci|epyc|\.remember|session_|backend\/|packages\//i, rel)
  }
})

const readme = read("README.md")
const patchText = () => readFileSync(new URL(patchFiles[0], patchDir), "utf8")

test("the patch header places close_input() and eof_in in the filter thread, not on a scheduler side", () => {
  const header = patchText().slice(0, patchText().indexOf("diff --git"))
  assert.doesNotMatch(header, /scheduler side/)
  assert.match(header, /filter thread/)
  assert.match(header, /eof_in/)
  assert.match(header, /ifp->eof/)
})

test("the patch header dates the ffmpeg master commit it cites by that commit, and names the master it re-checked", () => {
  const header = patchText().slice(0, patchText().indexOf("diff --git"))
  assert.doesNotMatch(header, /b5902e69c7, 2026-10-11/)
  assert.match(header, /b5902e69c7 \(committed 2026-10-06\)/)
  assert.match(header, /793f6013e7 \(2026-10-11\)/)
})

test("the measurements the patch header points at are in the README, with their limits", () => {
  const header = patchText().slice(0, patchText().indexOf("diff --git"))
  assert.match(header, /README\.md \(Verification\)/)
  const verification = readme.slice(readme.indexOf("## Verification"), readme.indexOf("## Licence"))
  assert.doesNotMatch(verification, /release notes/i, "the README must not point at release notes that carry no numbers")
  assert.match(verification, /43 of 397/)
  assert.match(verification, /0 of 394/)
  assert.match(verification, /earlier form/i, "numbers were taken on the earlier form of the fix")
  assert.match(verification, /has not yet been repeated/i)
})

test("the README claims reproducibility only where it was compared", () => {
  assert.doesNotMatch(readme, /equals the release's SHA256SUMS/)
  assert.match(readme, /has not yet been compared/i)
  assert.match(readme, /BASE_IMAGE/)
})
