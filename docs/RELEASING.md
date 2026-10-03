# JBar release procedure

JBar currently publishes a free **developer preview**. Its public artifact is
an ad-hoc-signed Universal 2 `JBar.app` ZIP, a standalone Universal 2 CLI archive, and
a reviewed prebuilt installer, each with a SHA-256 sidecar. The app ZIP preserves
the application wrapper, executable bit, and macOS metadata. GitHub Releases
is the source of truth. The matching npm wrapper is implemented but remains
unpublished until npm publication is explicitly enabled and its protected job completes; once published, it
downloads that exact versioned ZIP and verifies its SHA-256 checksum.

The preview supports macOS 13 or later on Apple Silicon and Intel. It is not
notarized and therefore is not a substitute for a Developer ID release. macOS
may ask people to approve its first launch. Never tell users to disable
Gatekeeper or remove quarantine.

## One-time setup

1. Protect `main` with the `Required CI gate` check.
2. Add a tag ruleset for `v*` that restricts creation, update, and deletion to
   the release owner or release bot. Tags must never move after publication.
3. Create a GitHub Actions environment named `release`. This is where the npm
   token lives; use a reviewer requirement if another person maintains releases.
4. Create an npm account named `linjiw` (the package scope is `@linjiw`), turn
   on two-factor authentication, and create a granular token that can publish
   only `@linjiw/jbar` to npm. Store it as the `NPM_TOKEN` secret in the GitHub
   `release` environment. Full instructions are in
   [NPM-PUBLISHING.md](NPM-PUBLISHING.md). Set repository variable `JBAR_PUBLISH_NPM=true`
   only after configuring the token. Otherwise GitHub assets publish normally and npm is skipped.

Do not add Apple signing or notarization credentials for the preview path.

## Publishing a preview

1. Update the version in `Resources/Info.plist` and `package.json` to the same
   `MAJOR.MINOR.PATCH` value. Keep `jbarCLIVersion` in `Sources/JBarCLI/Run.swift`
   aligned when distributing the standalone CLI.
2. Run `npm test`, `swift test`, and `scripts/build-app.sh` locally.
3. Push a reviewed release branch, wait for its required CI gate and merge its pull request.
   Wait for the exact merged commit's `main` push CI gate, then
   create and push the matching immutable tag:

   ```bash
   git tag -a v0.2.0 -m "JBar 0.2.0 developer preview"
   git push origin v0.2.0
   ```

4. `.github/workflows/release.yml` requires the exact `main` CI evidence, builds and checks
   the Universal 2 app and CLI, then publishes a prerelease with six assets:
   `JBar-<version>-universal.zip`, `JBar-CLI-<version>-universal.tar.gz`,
   `JBar-install-prebuilt-<version>.sh`, and their three `.sha256` files.
   The npm job publishes the matching package with provenance only when `JBAR_PUBLISH_NPM=true`.
   Its package includes the reviewed installer, so it executes no separately downloaded raw-tag script.
5. Verify the live release and, when enabled, npm package:

   ```bash
   gh release view v0.2.0 --repo linjiw/jbar
   # Only after enabling npm publication:
   npm view @linjiw/jbar version
   npx --yes @linjiw/jbar --version
   npx --yes @linjiw/jbar --tag v0.2.0 --no-launch
   ```

6. On a clean Apple Silicon Mac, verify the downloaded app has both
   architectures, opens after normal macOS approval, receives Files and
   Folders consent correctly, registers its login item, replaces an older
   preview, and uninstalls cleanly.

## Standalone CLI distribution

The CLI has a separate native `jbar-cli` executable and does not use the npm app installer. Stage its
Universal 2 distribution in a new temporary directory:

```bash
scripts/build-cli.sh /absolute/path/to/a/new/temporary-directory
```

The script builds with strict concurrency and warnings as errors, verifies both architectures and
the ad-hoc signature, checks version alignment and the absence of a direct AppKit dependency, then
creates `JBar-CLI-<version>-universal.tar.gz` and its `.sha256` file. It includes the CLI guide and MIT
license. This script only stages the candidate. CI verifies the extracted standalone CLI on the
same Apple Silicon/Intel platform matrix as the app, including index/search/stdio operations.

The release workflow publishes the reviewed archive/checksum as separate CLI assets after the
required main CI gate. The standalone CLI remains an
ad-hoc developer preview; the app's future notarization flow does not notarize the CLI.

## Future notarized channel

When the paid Apple Developer Program becomes appropriate, set the repository
variable `JBAR_RELEASE_CHANNEL` to `notarized`, configure the Developer ID and
notary secrets in the protected `release` environment, and require immutable
releases. The same workflow then uses the existing hardened-runtime,
notarization, stapling, and Gatekeeper verification jobs before publishing the
GitHub release and npm package.
