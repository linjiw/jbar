# JBar release procedure

JBar currently publishes a free **developer preview**. Its public artifact is
one ad-hoc-signed Universal 2 `JBar.app`, distributed as a ZIP that preserves
the application wrapper, executable bit, and macOS metadata. GitHub Releases
is the source of truth; the public npm package downloads that exact versioned
ZIP and verifies its SHA-256 checksum.

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
   [NPM-PUBLISHING.md](NPM-PUBLISHING.md).

Do not add Apple signing or notarization credentials for the preview path.

## Publishing a preview

1. Update the version in `Resources/Info.plist` and `package.json` to the same
   `MAJOR.MINOR.PATCH` value.
2. Run `npm test`, `swift test`, and `scripts/build-app.sh` locally.
3. Commit the release changes on `main`, wait for the required CI gate, then
   create and push the matching immutable tag:

   ```bash
   git tag -a v0.1.0 -m "JBar 0.1.0 developer preview"
   git push origin v0.1.0
   ```

4. `.github/workflows/release.yml` builds and checks the Universal 2 app on a
   macOS runner, publishes a prerelease containing
   `JBar-<version>-universal.zip` and its `.sha256` file, then publishes the
   matching `@linjiw/jbar` npm package with provenance.
5. Verify the live release and package:

   ```bash
   npm view @linjiw/jbar version
   npx --yes @linjiw/jbar --version
   npx --yes @linjiw/jbar --tag v0.1.0 --no-launch
   ```

6. On a clean Apple Silicon Mac, verify the downloaded app has both
   architectures, opens after normal macOS approval, receives Files and
   Folders consent correctly, registers its login item, replaces an older
   preview, and uninstalls cleanly.

## Future notarized channel

When the paid Apple Developer Program becomes appropriate, set the repository
variable `JBAR_RELEASE_CHANNEL` to `notarized`, configure the Developer ID and
notary secrets in the protected `release` environment, and require immutable
releases. The same workflow then uses the existing hardened-runtime,
notarization, stapling, and Gatekeeper verification jobs before publishing the
GitHub release and npm package.
