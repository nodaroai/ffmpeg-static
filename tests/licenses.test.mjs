import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { execFileSync, spawnSync } from "node:child_process"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * Licences and the source offer. The binary tarball carries the licence text of
 * every statically linked library, derived from the link trace (never a hand
 * list), and the release workflow refuses to publish unless the trace is
 * non-empty and the source archive holds a source tarball for every library the
 * trace names. These tests pin both, and run the checker against fixtures.
 */
const read = rel => readFileSync(new URL(`../${rel}`, import.meta.url), "utf8")
const script = read("build.sh")
const workflow = read(".github/workflows/release.yml")
const readme = read("README.md")
const checker = fileURLToPath(new URL("../check-source-offer.sh", import.meta.url))

// --- the build writes the trace and the licences from the link ---------------------

test("the link trace covers ffmpeg AND ffprobe, taken from the linker map", () => {
  assert.match(script, /for t in ffmpeg ffprobe/)
  assert.match(script, /-Wl,-Map=/)
  assert.match(script, /\$\{t\}_g/)
})

test("each self-built library records which archives it installed, so the trace needs no name table", () => {
  assert.match(script, /record_owner\(\)/)
  for (const lib of ["x264", "x265", "lame", "opus", "freetype", "harfbuzz", "dav1d"]) {
    assert.match(script, new RegExp(`record_owner [^\\n]*${lib}`), `${lib} records its archives`)
  }
})

test("a linked archive that has no licence file, no owner or no source fails the build", () => {
  assert.match(script, /no library owns/)
  assert.match(script, /no licence text found for/)
  assert.match(script, /the link trace found no/)
})

test("the tarball ships LICENSES/ and LINK-TRACE.txt, and the source archive carries the trace too", () => {
  assert.match(script, /cp -r "\$WORK\/licenses" "\$WORK\/pkg\/\$TOP\/LICENSES"/)
  assert.match(script, /cp "\$WORK\/link-trace\.txt" "\$WORK\/pkg\/\$TOP\/LINK-TRACE\.txt"/)
  assert.match(script, /link-trace\.txt"[^\n]*srcout/)
  assert.match(script, /copyright/, "Debian copyright files are collected")
})

test("the build runs the same checker the release workflow runs", () => {
  assert.match(script, /check-source-offer\.sh/)
})

// --- the release workflow: proof of the build before anything is published ---------

test("the release workflow checks the source offer on every architecture before the release job", () => {
  assert.match(workflow, /\n  source-offer:/)
  assert.match(workflow, /source-offer:[\s\S]*arch: \[amd64, arm64\]/)
  assert.match(workflow, /source-offer:[\s\S]*check-source-offer\.sh/)
  assert.match(workflow, /release:[\s\S]*needs: \[reproducible, source-offer\]/)
  const release = workflow.slice(workflow.indexOf("\n  release:"))
  assert.doesNotMatch(release, /continue-on-error/)
})

test("the smoke step looks for the licences in the tarball", () => {
  assert.match(workflow, /\/dist\/LICENSES/)
  assert.match(workflow, /\/dist\/LINK-TRACE\.txt/)
})

// --- the checker, run against fixtures --------------------------------------------

const sh = (cmd, cwd) => execFileSync("bash", ["-c", cmd], { cwd, stdio: "pipe" })

/** Build a binary tarball + source archive pair. */
function fixture({ trace, licenses, srcFiles, dsc }) {
  const dir = mkdtempSync(join(tmpdir(), "offer-"))
  const top = join(dir, "bin", "ffmpeg-x-linux64")
  const src = join(dir, "src", "ffmpeg-x-source-linux64")
  mkdirSync(join(top, "LICENSES"), { recursive: true })
  mkdirSync(join(src, "debian"), { recursive: true })
  writeFileSync(join(top, "LINK-TRACE.txt"), trace)
  for (const rel of licenses) {
    mkdirSync(join(top, "LICENSES", rel, ".."), { recursive: true })
    writeFileSync(join(top, "LICENSES", rel), "licence text\n")
  }
  for (const rel of srcFiles) writeFileSync(join(src, rel), "x")
  for (const [name, text] of Object.entries(dsc)) writeFileSync(join(src, "debian", name), text)
  sh("tar -cf ../bin.tar.xz ffmpeg-x-linux64", join(dir, "bin"))
  sh("tar -cf ../src.tar.xz ffmpeg-x-source-linux64", join(dir, "src"))
  return { dir, bin: join(dir, "bin.tar.xz"), src: join(dir, "src.tar.xz") }
}

const dscText = `-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

Format: 3.0 (quilt)
Source: zlib
Version: 1:1.2.13.dfsg-1
Checksums-Sha1:
 aaaa 1 zlib_1.2.13.dfsg.orig.tar.xz
Checksums-Sha256:
 ${"a".repeat(64)} 100 zlib_1.2.13.dfsg.orig.tar.xz
 ${"b".repeat(64)} 10 zlib_1.2.13.dfsg-1.debian.tar.xz
Files:
 cccc 1 zlib_1.2.13.dfsg.orig.tar.xz
`
const goodTrace = [
  ["built", "ffmpeg", "ffmpeg-abc.tar", "ffmpeg"],
  ["built", "x264", "x264-def.tar", "x264"],
  ["debian", "zlib", "1.2.13.dfsg-1", "debian/zlib"],
  ["runtime", "libstdc++-12-dev", "libstdc++-12-dev", "gcc-runtime/libstdc++-12-dev"],
].map(r => r.join("\t")).join("\n") + "\n"
const goodLicenses = ["ffmpeg/COPYING.GPLv3", "x264/COPYING", "debian/zlib/copyright", "gcc-runtime/libstdc++-12-dev/copyright"]
const goodSrc = ["ffmpeg-abc.tar", "x264-def.tar", "debian/zlib_1.2.13.dfsg.orig.tar.xz", "debian/zlib_1.2.13.dfsg-1.debian.tar.xz"]
const good = () => ({ trace: goodTrace, licenses: goodLicenses, srcFiles: goodSrc, dsc: { "zlib_1.2.13.dfsg-1.dsc": dscText } })
const run = f => spawnSync("bash", [checker, f.bin, f.src], { encoding: "utf8" })
const cleanup = f => rmSync(f.dir, { recursive: true, force: true })

test("check-source-offer.sh accepts a complete offer", () => {
  const f = fixture(good())
  const r = run(f)
  assert.equal(r.status, 0, r.stderr)
  cleanup(f)
})

test("check-source-offer.sh refuses an empty link trace", () => {
  const f = fixture({ ...good(), trace: "" })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /link trace is empty/)
  cleanup(f)
})

test("check-source-offer.sh refuses a trace that names no Debian library (the trace is broken)", () => {
  const trace = goodTrace.split("\n").filter(l => !l.startsWith("debian")).join("\n")
  const f = fixture({ ...good(), trace })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /no Debian library/)
  cleanup(f)
})

test("check-source-offer.sh refuses a built library whose source tarball is not in the archive", () => {
  const f = fixture({ ...good(), srcFiles: goodSrc.filter(s => s !== "x264-def.tar") })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /x264-def\.tar/)
  cleanup(f)
})

test("check-source-offer.sh refuses a Debian library whose .dsc is missing", () => {
  const f = fixture({ ...good(), dsc: {} })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /zlib_1\.2\.13\.dfsg-1\.dsc/)
  cleanup(f)
})

test("check-source-offer.sh refuses a Debian library whose orig tarball the .dsc lists but the archive lacks", () => {
  const f = fixture({ ...good(), srcFiles: goodSrc.filter(s => !s.includes("orig")) })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /orig\.tar\.xz/)
  cleanup(f)
})

test("check-source-offer.sh refuses a linked library with no licence text in the tarball", () => {
  const f = fixture({ ...good(), licenses: goodLicenses.filter(l => !l.startsWith("debian/zlib")) })
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /LICENSES\/debian\/zlib/)
  cleanup(f)
})

test("check-source-offer.sh refuses a tarball with no link trace file at all", () => {
  const f = fixture(good())
  sh("rm ffmpeg-x-linux64/LINK-TRACE.txt && tar -cf ../bin.tar.xz ffmpeg-x-linux64", join(f.dir, "bin"))
  const r = run(f)
  assert.notEqual(r.status, 0)
  assert.match(r.stderr, /LINK-TRACE\.txt/)
  cleanup(f)
})

// --- the documentation says where the licences are ---------------------------------

test("the README lists LICENSES/ and LINK-TRACE.txt in the tarball layout", () => {
  assert.match(readme, /`LICENSES\/`/)
  assert.match(readme, /`LINK-TRACE\.txt`/)
})

// --- wording: the goal and what has been measured, not a finished claim -------------

test("nothing says the patched build produces the same output as stock without saying it is a goal and what was measured", () => {
  const dropped = read("DROPPED.md")
  const intro = readme.slice(0, readme.indexOf("## Download and verify"))
  const header = script.slice(0, script.indexOf("set -euo pipefail"))
  // every "same output" is inside a "the goal is ..." sentence
  for (const [where, text] of [["README intro", intro], ["build.sh header", header]]) {
    const hits = [...text.matchAll(/same\s+output/g)]
    assert.ok(hits.length > 0, `${where} states the goal`)
    for (const h of hits) assert.match(text.slice(Math.max(0, h.index - 160), h.index), /goal/i, `${where}: "same output" must be stated as the goal`)
  }
  assert.match(intro, /Verification/)
  assert.match(header, /README\.md \(Verification\)/)
  assert.doesNotMatch(dropped, /are the same code as before/, "DROPPED.md")
  assert.match(dropped, /same source revisions/)
})
