#!/usr/bin/env node

const fs = require("node:fs");
const crypto = require("node:crypto");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const packageRoot = path.resolve(__dirname, "../..");
const packageMetadata = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
const repository = process.env.JBAR_GITHUB_REPOSITORY || "linjiw/jbar";
const maxDownloadBytes = 100 * 1024 * 1024;

function fail(message) {
  console.error(`jbar: ${message}`);
  process.exitCode = 1;
}

function usage() {
  console.log(`Usage: jbar [--tag latest|vMAJOR.MINOR.PATCH] [--no-launch]

Downloads the matching Universal 2 JBar developer preview from GitHub and
installs it into /Applications or ~/Applications. This command does not run at
npm install time; it only acts when invoked explicitly. The preview is ad-hoc
signed, not notarized, so macOS may ask the user to approve its first launch.

Examples:
  npx --yes @linjiw/jbar
  npx --yes @linjiw/jbar --tag latest
  npm install --global @linjiw/jbar
  jbar
`);
}

function parseArgs(args) {
  const options = { tag: `v${packageMetadata.version}`, noLaunch: false };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--help" || argument === "-h") {
      options.help = true;
    } else if (argument === "--no-launch") {
      options.noLaunch = true;
    } else if (argument === "--tag") {
      const tag = args[++index];
      if (!tag) throw new Error("--tag requires latest or vMAJOR.MINOR.PATCH");
      options.tag = tag;
    } else if (argument === "--version") {
      options.version = true;
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  return options;
}

function normalizeTag(value) {
  if (value === "latest") return value;
  const withoutPrefix = value.startsWith("v") ? value.slice(1) : value;
  if (!/^\d+\.\d+\.\d+$/.test(withoutPrefix)) {
    throw new Error("release tag must be latest or vMAJOR.MINOR.PATCH");
  }
  return `v${withoutPrefix}`;
}

function request(url, { maxBytes = maxDownloadBytes, headers = {}, redirects = 0 } = {}) {
  return new Promise((resolve, reject) => {
    const requestObject = https.get(url, {
      headers: { "User-Agent": "jbar-npm-installer", Accept: "application/json", ...headers },
      timeout: 120000,
    }, (response) => {
      const status = response.statusCode || 0;
      if (status >= 300 && status < 400 && response.headers.location) {
        response.resume();
        if (redirects >= 5) {
          reject(new Error(`too many redirects while downloading: ${url}`));
          return;
        }
        const nextUrl = new URL(response.headers.location, url);
        if (nextUrl.protocol !== "https:") {
          reject(new Error("refusing a non-HTTPS download redirect"));
          return;
        }
        request(nextUrl.toString(), { maxBytes, headers, redirects: redirects + 1 })
          .then(resolve, reject);
        return;
      }
      if (status !== 200) {
        response.resume();
        reject(new Error(`download failed with HTTP ${status}: ${url}`));
        return;
      }
      const contentLength = Number(response.headers["content-length"] || 0);
      if (contentLength > maxBytes) {
        response.resume();
        reject(new Error(`download is larger than ${maxBytes} bytes`));
        return;
      }
      const chunks = [];
      let total = 0;
      response.on("data", (chunk) => {
        total += chunk.length;
        if (total > maxBytes) {
          response.destroy(new Error(`download is larger than ${maxBytes} bytes`));
        } else {
          chunks.push(chunk);
        }
      });
      response.on("end", () => resolve(Buffer.concat(chunks)));
      response.on("error", reject);
    });
    requestObject.on("error", reject);
    requestObject.on("timeout", () => requestObject.destroy(new Error("download timed out")));
  });
}

function writeFile(filePath, data) {
  fs.writeFileSync(filePath, data, { mode: 0o600, flag: "wx" });
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: "inherit", ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed with status ${result.status}`);
  return result;
}

async function resolveTag(requestedTag) {
  if (requestedTag !== "latest") return requestedTag;
  const releases = JSON.parse((await request(`https://api.github.com/repos/${repository}/releases?per_page=1`, {
    maxBytes: 1024 * 1024,
  })).toString("utf8"));
  return latestPublishedReleaseTag(releases);
}

function latestPublishedReleaseTag(releases) {
  const release = Array.isArray(releases) ? releases[0] : undefined;
  if (!release || release.draft === true || typeof release.tag_name !== "string") {
    throw new Error("GitHub returned no published release tag");
  }
  return normalizeTag(release.tag_name);
}

async function install(options) {
  const tag = await resolveTag(normalizeTag(options.tag));
  if (process.platform !== "darwin") throw new Error("JBar's prebuilt installer only supports macOS");
  const version = tag.slice(1);
  const archiveName = `JBar-${version}-universal.zip`;
  const baseUrl = `https://github.com/${repository}/releases/download/${tag}`;
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), "jbar-npm-install-"));
  fs.chmodSync(temporaryRoot, 0o700);
  try {
    const archivePath = path.join(temporaryRoot, archiveName);
    const checksumPath = path.join(temporaryRoot, `${archiveName}.sha256`);
    writeFile(archivePath, await request(`${baseUrl}/${archiveName}`));
    writeFile(checksumPath, await request(`${baseUrl}/${archiveName}.sha256`, { maxBytes: 4096 }));

    const checksumText = fs.readFileSync(checksumPath, "utf8");
    const checksumLine = checksumText.split(/\r?\n/).find((line) => {
      const fields = line.trim().split(/\s+/);
      return fields.length === 2 && (fields[1] === archiveName || fields[1] === `*${archiveName}`);
    });
    const expected = checksumLine && checksumLine.trim().split(/\s+/)[0];
    if (!expected || !/^[0-9a-f]{64}$/i.test(expected)) throw new Error("release checksum file is malformed");
    const actual = crypto.createHash("sha256").update(fs.readFileSync(archivePath)).digest("hex");
    if (actual.toLowerCase() !== expected.toLowerCase()) throw new Error("downloaded release checksum does not match");

    const extractedPath = path.join(temporaryRoot, "extracted");
    fs.mkdirSync(extractedPath, { mode: 0o700 });
    run("/usr/bin/ditto", ["-x", "-k", "--rsrc", "--extattr", "--qtn", "--noacl", archivePath, extractedPath]);
    const appPath = path.join(extractedPath, "JBar.app");
    if (!fs.statSync(appPath).isDirectory() || fs.lstatSync(appPath).isSymbolicLink()) {
      throw new Error("release archive does not contain a regular top-level JBar.app");
    }

    const installerPath = path.join(temporaryRoot, "install-prebuilt.sh");
    writeFile(installerPath, await request(`https://raw.githubusercontent.com/${repository}/${tag}/scripts/install-prebuilt.sh`, { maxBytes: 256 * 1024 }));
    fs.chmodSync(installerPath, 0o700);
    const installerArgs = [installerPath, appPath];
    if (options.noLaunch) installerArgs.push("--no-launch");
    run("/bin/bash", installerArgs);
  } finally {
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

async function main() {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
    throw new Error("JBAR_GITHUB_REPOSITORY must be owner/name");
  }
  const options = parseArgs(process.argv.slice(2));
  if (options.help) return usage();
  if (options.version) return console.log(packageMetadata.version);
  await install(options);
}

if (require.main === module) {
  main().catch((error) => fail(error instanceof Error ? error.message : String(error)));
}

module.exports = { latestPublishedReleaseTag };
