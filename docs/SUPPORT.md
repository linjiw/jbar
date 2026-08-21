# Support and validation policy

JBar's intended v1 support contract is deliberately narrower than “every Mac ever made,” so every
claim can be tested and maintained:

- macOS 13 Ventura or later;
- Apple Silicon (`arm64`) and Intel (`x86_64`) from one Universal 2 application;
- any macOS system language and input source, using AppKit's standard text-input contract;
- an English user interface for v1. System-language compatibility does not yet mean that every UI
  string is translated.

macOS 12 and older are outside this contract. JBar uses `SMAppService` and has a macOS 13 deployment
target; changing that would be a separate compatibility project, not a packaging workaround. npm is
only an installer entry point and cannot bypass the operating-system APIs, code signing, notarization,
or architecture requirements.

## Evidence levels

A matrix cell is never marked verified merely because it compiled.

1. **Automated** — unit/integration tests pass for the architecture and deployment target.
2. **Runtime** — a signed build launches, searches, navigates, opens a fixture, relaunches, and leaves
   no crash report on that OS/architecture.
3. **Input/UI** — a human exercises the real input source, candidate window, keyboard layout,
   multi-display geometry, scrolling, and accessibility settings.
4. **Release** — the exact downloadable ZIP passes strict code-signature verification, Apple
   notarization/stapling, Gatekeeper assessment, checksum verification, and clean-machine install.

Only levels actually recorded in release evidence count. Simulator-style marked-text tests are useful
regressions, but they do not replace a Sequoia 15.x Chinese Pinyin test on the reporting Mac.

## Required v1 matrix

| Dimension | Required coverage |
|---|---|
| macOS | 13 Ventura, 14 Sonoma, 15 Sequoia, and the current shipping macOS |
| CPU | Intel and Apple Silicon; `lipo` must show both slices |
| System language | Simplified Chinese plus English; one RTL language smoke |
| Input source | Simplified Chinese Pinyin, Shuangpin, Wubi, Korean 2-Set, Japanese Romaji/Kana, US, French AZERTY, German QWERTZ, Dvorak |
| Key paths | Control alone, Control-Space input switch, Delete, Fn-Delete, held Delete, Return, Tab, arrows, Page Up/Down, Escape, Command shortcuts |
| Displays | one small built-in display, Retina/external display, multiple displays, changed resolution while open |
| Lifecycle | first run, hot reload, index/cancel/restart, login item, upgrade, rollback, uninstall/purge |

For IMEs, test both active marked text and committed text. The first Escape must remain available to
the input method; Delete must never close the panel; input-source or candidate-window focus changes
must not terminate the process. Verification includes checking the menu-bar process is still alive and
that no new `JBar-*.ips` report was written.

## Current evidence and release blockers

The repository currently has automated coverage for Chinese/Korean marked-text policy, NFC/NFD
matching and highlighting, physical Command-number keys, empty-table teardown, and short-screen row
geometry. A packaged-clone AppKit smoke also drives a real `NSApplication`/panel lifecycle with
synthetic Control `flagsChanged`, text, Delete, Down, and Return events; it proves the panel stays
visible through editing, opens only the expected in-memory fixture through a recording workspace,
terminates cleanly, and emits no new crash report during the bounded run. The smoke never invokes
the real workspace, hotkey, index, history, login item, or input method. The local build can be
assembled as Universal 2 with a macOS 13 minimum version.

That is not proof of a trusted public release. Synthetic events are not a physical keyboard or IME,
and the current ad-hoc developer preview is not a Developer ID release. Before a fully trusted v1,
the project still needs the physical matrix above, Developer ID credentials, Hardened Runtime signing,
Apple notarization and stapling, and Gatekeeper verification on a clean Mac. The preview GitHub and
npm channels publish the same checksum-verified Universal 2 ZIP; see the open GitHub issues for the
live implementation and evidence checklist.
