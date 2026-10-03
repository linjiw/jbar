const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const entrypoint = path.resolve(__dirname, "../bin/jbar.js");
const { latestPublishedReleaseTag, parseChecksum, reviewedInstallerPath } = require(entrypoint);
const packageVersion = require("../../package.json").version;

function run(...args) {
  return spawnSync(process.execPath, [entrypoint, ...args], { encoding: "utf8" });
}

test("prints help without touching the network", () => {
  const result = run("--help");
  assert.equal(result.status, 0);
  assert.match(result.stdout, /npx --yes @linjiw\/jbar/);
});

test("reports the package version without touching the network", () => {
  const result = run("--version");
  assert.equal(result.status, 0);
  assert.equal(result.stdout, `${packageVersion}\n`);
});

test("rejects malformed release selectors before downloading", () => {
  const result = run("--tag", "not-a-version");
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /release tag must be latest or vMAJOR\.MINOR\.PATCH/);
});

test("latest includes a published developer preview", () => {
  assert.equal(latestPublishedReleaseTag([
    { tag_name: "v0.1.0", draft: false, prerelease: true },
  ]), "v0.1.0");
  assert.throws(() => latestPublishedReleaseTag([]), /no published release tag/);
  assert.throws(() => latestPublishedReleaseTag([
    { tag_name: "v0.1.0", draft: true, prerelease: false },
  ]), /no published release tag/);
  assert.throws(() => latestPublishedReleaseTag([
    { tag_name: "latest", draft: false },
  ]), /no versioned release tag/);
});

test("accepts only an unambiguous checksum for the selected asset", () => {
  const hash = "a".repeat(64);
  assert.equal(parseChecksum(`${hash}  JBar.zip\n`, "JBar.zip"), hash);
  assert.equal(parseChecksum(`${hash.toUpperCase()} *JBar.zip\r\n`, "JBar.zip"), hash);
  for (const value of ["", `${hash} other.zip\n`, `${hash} JBar.zip extra\n`,
    `${hash} JBar.zip\n${hash} JBar.zip\n`, `${hash} JBar.zip\nother\n`]) {
    assert.throws(() => parseChecksum(value, "JBar.zip"), /malformed/);
  }
});

test("installer comes from the reviewed npm package and rejects unsafe replacement", () => {
  const packageRoot = path.resolve(__dirname, "../..");
  assert.equal(reviewedInstallerPath(), path.join(packageRoot, "scripts/install-prebuilt.sh"));
  assert.ok(require("../../package.json").files.includes("scripts/install-prebuilt.sh"));
  const parent = path.join(packageRoot, ".build/release-safety-review");
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const root = fs.mkdtempSync(path.join(parent, "npm-installer-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"), { mode: 0o700 });
    const script = path.join(root, "scripts/install-prebuilt.sh");
    fs.symlinkSync(reviewedInstallerPath(), script);
    assert.throws(() => reviewedInstallerPath(root), /safe reviewed installer/);
    fs.unlinkSync(script);
    fs.writeFileSync(script, "echo test\n", { mode: 0o666 });
    fs.chmodSync(script, 0o666);
    assert.throws(() => reviewedInstallerPath(root), /safe reviewed installer/);
    fs.chmodSync(script, 0o600);
    assert.equal(reviewedInstallerPath(root), script);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
