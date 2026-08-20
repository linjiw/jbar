# JBar release procedure

JBar's public artifact is one notarized Universal 2 `JBar.app`, distributed as a ZIP that preserves
the bundle wrapper, executable bit, and macOS metadata. GitHub Release is the source of truth;
Homebrew Cask installs that exact ZIP. npm, a Homebrew formula, and source-built SwiftPM binaries are
not release channels because they add a toolchain without solving code signing, Gatekeeper, TCC, or
architecture compatibility.

## One-time repository controls

The release workflow deliberately cannot produce a public build until all of these external controls
exist. They are repository settings, not checks that untrusted tag code can safely configure for
itself:

1. Protect `main` with the `Required CI gate` check and disallow bypass for ordinary contributors.
2. Add a ruleset for `v*` tags that restricts creation, update, and deletion to the release owner or
   bot. A tag must never be movable during an approval or release run.
3. Create a GitHub Actions environment named `release`; require an independent reviewer, prevent
   self-review, disallow administrators from bypassing its protection rules, and restrict deployments
   to the protected `v*` tags.
4. Enable GitHub **immutable releases** for the repository, record an owner-authenticated screenshot
   or API result in the release evidence, and only then set the protected `release` environment
   variable `IMMUTABLE_RELEASES_ATTESTED` to the exact string `true`. `GITHUB_TOKEN` cannot query the
   Administration-read setting, so this reviewed attestation blocks accidental publication without
   pretending that tag-controlled workflow code can self-attest the repository setting.
5. Set the candidate-artifact retention/approval service level so that approval happens within seven
   days. An expired candidate must be rebuilt from the unchanged tag, never recreated by hand.

GitHub documents [deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
and [immutable releases](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes).

Add these environment secrets only to `release`:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`: base64 of the Developer ID Application `.p12`.
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`: `.p12` export password.
- `APPLE_DEVELOPER_ID_APPLICATION`: full identity, such as `Developer ID Application: … (TEAMID)`.
- `APPLE_NOTARY_KEY_BASE64`: base64 of an App Store Connect API `.p8` key authorized for notarization.
- `APPLE_NOTARY_KEY_ID` and `APPLE_NOTARY_ISSUER_ID`.

Also add the non-secret protected environment variables `APPLE_DEVELOPER_TEAM_ID`, with the exact
10-character Team ID, and `IMMUTABLE_RELEASES_ATTESTED`, as described above. The workflow requires
both the configured signing identity and the signed bundle's `TeamIdentifier` to equal the
independently pinned Team ID; it never trusts a Team ID read only from the candidate app. It propagates
the reviewed immutability attestation to the write-token job and still requires the newly published
release itself to report `isImmutable: true`.

The private certificate and API key are decoded only into the ephemeral runner. The signing keychain
and files are removed by traps. Do not put any credential, generated `.p12`, or `.p8` in the repo.

The workflow has four isolation boundaries:

- `candidate` has only `contents: read` plus `actions: read`, checks out the tag, proves the tagged
  commit is on `main`, verifies exact-commit CI evidence, and only then executes tag code. It has no
  Apple credentials;
- `sign_and_notarize` does not check out the repository. The certificate and notarization secrets are
  step-scoped and supplied separately; the candidate is never executed anywhere on this runner;
- `verify_signed` downloads the exact immutable signed artifact onto a fresh runner with no Apple
  credentials and performs Gatekeeper plus CLI runtime smoke there;
- `publish` receives no Apple credential, does not check out or execute repository code, and is the
  only job with `contents: write`. Immediately before publication it peels the live tag again and
  requires the exact tested commit.

This separation limits credential exposure; it does not replace protected tags, a protected release
environment, or immutable releases. GitHub cannot atomically compare a tag and create a release in
one repository API operation, so those external controls close the remaining tag-move window.

## Release gate

Before any tag-controlled build or test command runs, the candidate job enforces a machine-verifiable
CI precondition. The tagged commit must be an ancestor of the fetched `origin/main`. With a read-only
token, the job queries runs for the exact `.github/workflows/ci.yml` file, `main` branch, `push` event,
and tagged commit SHA. It accepts only the newest matching run, requires that run to be completed and
successful, and then queries that run's current attempt. Exactly one completed, successful
`Required CI gate` job and its `Require every evidence job` step must be present. The run and job must
both report the exact commit, `main`, workflow name `CI`, and the same repository as both the base and
head repository; fork evidence is rejected. See GitHub's [workflow-runs
API](https://docs.github.com/en/rest/actions/workflow-runs?apiVersion=2026-03-10#list-workflow-runs-for-a-workflow)
and [attempt-jobs
API](https://docs.github.com/en/rest/actions/workflow-jobs?apiVersion=2026-03-10#list-jobs-for-a-workflow-run-attempt).

The release workflow never dispatches or reruns CI, so this evidence check cannot create a workflow
cycle. A newer failed, cancelled, or in-progress run cannot fall back to an older success. A rerun is
accepted only after its current attempt is complete and contains the successful required gate; a
single-job rerun that omits that gate fails closed. Use **Re-run all jobs** when refreshing evidence,
then rerun the unchanged protected-tag release after CI is green. After inspecting the attempt's jobs,
the release workflow reads the newest matching run again and rejects any intervening run or attempt
change. This machine check supplements, but does not replace, `main` protection and protected
immutable tags.

1. Complete the automated and physical matrix in [SUPPORT.md](SUPPORT.md), including Sequoia 15.x
   with Simplified Chinese Pinyin and both Intel and Apple Silicon runtime smoke tests.
2. Ensure CI is green and the strict-concurrency, release, sanitizer, and UI smoke jobs have evidence.
3. Update user-facing release notes and verify the tag is `vMAJOR.MINOR.PATCH` on the intended commit.
4. Push the protected tag. `.github/workflows/release.yml` runs optimized tests, enforces strict
   concurrency, cross-builds both architectures, injects the tag/build number, signs with Hardened
   Runtime and timestamp, notarizes, staples, checks Gatekeeper, packages, and publishes checksums.
   The final ZIP is extracted again and its app must pass `codesign`, `stapler validate`,
   `syspolicy_check distribution`, `spctl`, architecture, minimum-OS, and version checks before the
   write-token job can publish it. After publication, the workflow also requires GitHub to report
   that the release is immutable and contains exactly the three expected assets.
   A manual rerun must be dispatched on the tag ref itself, for example
   `gh workflow run release.yml --ref v1.2.3 -f tag=v1.2.3`; dispatching from `main` intentionally
   fails before the protected environment because its deployment ref would not be the protected tag.
5. Download the published ZIP on a clean Mac rather than using the runner's checkout. Verify
   Gatekeeper, first launch, hotkey, Files and Folders consent, login item, update/replacement, and
   uninstall. Record OS, CPU, language, input source, artifact SHA-256, and result.
6. Copy the generated `jbar.rb` asset into `linjiw/homebrew-tap/Casks/jbar.rb`, run `brew audit
   --cask --strict` and `brew install --cask linjiw/tap/jbar`, then verify the installed app's SHA and
   signature. Moving to the official Homebrew Cask repository is a later notability decision.

The workflow intentionally fails when credentials, signature, timestamp, notarization, stapling,
Gatekeeper assessment, architecture, minimum OS, version, packaging, or release upload fails. An
ad-hoc CI artifact is development-only and must never be renamed or presented as a public release.

At the time this procedure was written, the repository did not yet have the `release` environment,
Apple secrets, protected-tag/main rulesets, or immutable releases enabled. Therefore a green local
build is not a releasable artifact, and the public release gate remains blocked until the repository
owner configures and independently records those controls.
