const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const zlib = require("node:zlib");
const test = require("node:test");

const packageRoot = path.resolve(__dirname, "../..");
const installer = path.join(packageRoot, "scripts/install-prebuilt.sh");

// Small stored ZIP fixtures exercise pre-extraction validation without extracting anything.
function zip(entries) {
  const localRecords = [];
  const centralRecords = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.name);
    const localName = Buffer.from(entry.localName ?? entry.name);
    const extra = entry.extra ?? Buffer.alloc(0);
    const body = Buffer.from(entry.body ?? "");
    const method = entry.method ?? 0;
    const compressed = entry.compressedBody ?? (method === 8 ? zlib.deflateRawSync(body) : body);
    const directory = entry.name.endsWith("/");
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(entry.flags ?? 0, 6);
    local.writeUInt16LE(method, 8);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(entry.expanded ?? body.length, 22);
    local.writeUInt16LE(localName.length, 26);
    local.writeUInt16LE(extra.length, 28);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(0x0314, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(entry.flags ?? 0, 8);
    central.writeUInt16LE(method, 10);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(entry.expanded ?? body.length, 24);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt16LE(extra.length, 30);
    const mode = entry.mode ?? (directory ? 0o40755 : 0o100644);
    central.writeUInt32LE((mode << 16) >>> 0, 38);
    central.writeUInt32LE(offset, 42);
    const record = Buffer.concat([local, localName, extra, compressed]);
    localRecords.push(record);
    centralRecords.push(Buffer.concat([central, name, extra]));
    offset += record.length;
  }
  const directory = Buffer.concat(centralRecords);
  const ending = Buffer.alloc(22);
  ending.writeUInt32LE(0x06054b50, 0);
  ending.writeUInt16LE(entries.length, 8);
  ending.writeUInt16LE(entries.length, 10);
  ending.writeUInt32LE(directory.length, 12);
  ending.writeUInt32LE(offset, 16);
  return Buffer.concat([...localRecords, directory, ending]);
}

function validate(data) {
  const parent = path.join(packageRoot, ".build/release-safety-review");
  fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
  const root = fs.mkdtempSync(path.join(parent, "archive-test-"));
  try {
    const file = path.join(root, "candidate.zip");
    fs.writeFileSync(file, data, { mode: 0o600 });
    return spawnSync("/bin/bash", [installer, "--validate-archive", file], { encoding: "utf8" });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

const root = { name: "JBar.app/" };
test("accepts a bounded ordinary JBar ZIP before extraction", () => {
  const result = validate(zip([root, { name: "JBar.app/Contents/readme", body: "fixture" }]));
  assert.equal(result.status, 0, result.stderr);
});
test("accepts a bounded deflate stream and verifies its real expanded size", () => {
  const result = validate(zip([root, { name: "JBar.app/Contents/readme", method: 8, body: "fixture".repeat(1000) }]));
  assert.equal(result.status, 0, result.stderr);
});

const unicodeOverride = Buffer.from([0x75, 0x70, 0x01, 0x00, 0x00]);
const unsafe = [
  ["traversal", [root, { name: "JBar.app/../../escaped" }]],
  ["absolute path", [root, { name: "/tmp/escaped" }]],
  ["outside root", [root, { name: "Other.app/Contents/file" }]],
  ["symbolic link", [root, { name: "JBar.app/Contents/link", mode: 0o120777 }]],
  ["special file", [root, { name: "JBar.app/Contents/fifo", mode: 0o10644 }]],
  ["case-insensitive alias", [root, { name: "jbar.app/Contents/file" }]],
  ["duplicate", [root, { name: "JBar.app/Contents/file" }, { name: "JBar.app/Contents/file" }]],
  ["file ancestor after child", [root, { name: "JBar.app/Contents/file" }, { name: "JBar.app/Contents" }]],
  ["local path mismatch", [root, { name: "JBar.app/Contents/file", localName: "JBar.app/../../escaped" }]],
  ["encrypted entry", [root, { name: "JBar.app/Contents/file", flags: 1 }]],
  ["path override extra", [root, { name: "JBar.app/Contents/file", extra: unicodeOverride }]],
  ["expansion limit", [root, { name: "JBar.app/Contents/file", expanded: 536870913 }]],
  ["false expanded size", [root, { name: "JBar.app/Contents/file", method: 8, body: "x".repeat(1048576), expanded: 1 }]],
  ["corrupt deflate stream", [root, { name: "JBar.app/Contents/file", method: 8, compressedBody: Buffer.from("invalid") }]],
  ["newline path", [root, { name: "JBar.app/Contents/file\nother" }]],
];
for (const [label, entries] of unsafe) {
  test(`rejects ${label} before extraction`, () => {
    const result = validate(zip(entries));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /pre-extraction safety validation/);
  });
}
test("rejects a truncated ZIP before extraction", () => {
  const result = validate(zip([root]).subarray(0, 10));
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /pre-extraction safety validation/);
});
