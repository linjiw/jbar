const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const entrypoint = path.resolve(__dirname, "../bin/jbar.js");
const { latestPublishedReleaseTag } = require(entrypoint);

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
  assert.match(result.stdout, /^0\.1\.0\n$/);
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
});
