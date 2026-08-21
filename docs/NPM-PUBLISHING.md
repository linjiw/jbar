# Publishing `@linjiw/jbar`

The package is an explicit installer command for the native JBar developer
preview. `npm install --global @linjiw/jbar` installs the `jbar` command; it
does not download or launch an app during package installation.

## First-time account setup

1. Create or sign in to the npm account named `linjiw` at
   <https://www.npmjs.com/signup>.
2. Enable two-factor authentication for publishing.
3. Run the following on a trusted Mac and confirm it prints `linjiw`:

   ```bash
   npm login
   npm whoami
   ```

4. Create a granular npm access token that has publish access only to
   `@linjiw/jbar`. Add it to the GitHub repository's protected `release`
   environment as `NPM_TOKEN`; do not commit it or put it in a workflow file.
5. After the first successful publish, configure npm Trusted Publishing for
   `@linjiw/jbar` with repository `linjiw/jbar`, workflow `release.yml`, and
   environment `release`. Then remove `NPM_TOKEN` and the token-based
   authentication stanza from the workflow in a follow-up change.

Trusted Publishing is preferred once it is available for the package because
GitHub Actions can obtain short-lived npm credentials through OIDC and npm
automatically creates provenance attestations. See the official
[npm Trusted Publishing guide](https://docs.npmjs.com/trusted-publishers/).

## Local verification

Run before tagging a release:

```bash
npm test
npm pack --dry-run
npm publish --dry-run --access public
```

The package version must exactly match `Resources/Info.plist` and the `v…`
Git tag. The release workflow repacks the package after validating that match;
do not manually publish a different tarball after the GitHub Release is live.
