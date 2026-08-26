# @linjiw/jbar

This package is a small installer for the native JBar macOS developer preview.
It does not run during `npm install`; it downloads the matching GitHub Release
ZIP only when invoked and verifies the published SHA-256 checksum before
installing. The preview is ad-hoc signed but not notarized, so macOS may ask the
user to approve its first launch.

> **Publication status:** the wrapper is implemented, but `@linjiw/jbar` is not
> yet live in the npm registry. The commands below are the intended interface
> after the protected release job completes. Until then, use the GitHub installer
> shown at the end of this page.

```bash
npx --yes @linjiw/jbar
```

Or install the command globally:

```bash
npm install --global @linjiw/jbar
jbar
```

The package supports macOS 13 or later on Apple Silicon and Intel. The app is a
Universal 2 native Swift/AppKit bundle; Node is only used as the download
launcher and is not bundled into JBar.

Useful options:

```bash
npx --yes @linjiw/jbar --tag latest
npx --yes @linjiw/jbar --no-launch
```

For a source-free GitHub install without npm, use the documented installer:

```bash
curl -fsSL https://raw.githubusercontent.com/linjiw/jbar/main/scripts/install-from-github.sh | bash
```
