| `site/` | The website, on GitHub Pages |
| `Casks/` | Homebrew cask; the repository is its own tap |
# Naut

Markdown notes on your Mac. One switch puts a note on the web.

<https://frinfo702.github.io/Naut/>

Notes are plain `.md` files in `~/Documents/Naut`. The preview and the
published page are the same HTML, so what you see while writing is what
readers get. Publishing runs on your own Cloudflare account: Naut creates a
Worker and a KV namespace with Terraform, and after that they are ordinary
resources you can change in the dashboard.

## Install

Download [Naut.dmg](https://github.com/frinfo702/Naut/releases/latest/download/Naut.dmg)
(Apple silicon, macOS 14 or later), or with Homebrew:

```sh
brew tap frinfo702/naut https://github.com/frinfo702/Naut
brew install --cask naut
```

Naut → Check for Updates… installs new releases in place.

## Build

```sh
direnv allow        # or: nix develop
zig build run       # builds libnaut, the xcframework and Naut.app, then opens it
zig build test      # core tests
(cd macos && swift test)
```

Swift comes from Xcode; Zig and Terraform come from the flake.

## Releasing

Run the **Release** workflow from the Actions tab and pick patch, minor or
major; it raises the last `vX.Y.Z` tag accordingly, builds `Naut.dmg` with
`macos/package.sh` and publishes the release. The app's updater, the cask
(`Casks/naut.rb`) and the site (`site/`, deployed by the **Site** workflow)
all follow the latest release.

Releases are signed ad hoc. To sign with a Developer ID and notarize, add
the secrets `MACOS_CERTIFICATE` (base64 .p12), `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_TEAM_ID` and `MACOS_NOTARY_PASSWORD`.
Once a signed release is out, the updater only accepts releases from the
same team.

## Layout

| Path | What |
| --- | --- |
| `src/` | libnaut, the Zig core: Markdown, page template, Cloudflare publishing |
| `src/tex.zig` | TeX math to MathML, a standalone module (`tex`) |
| `src/highlight.zig` | Code highlighting, a standalone module (`highlight`) |
| `include/naut.h` | C API |
| `macos/Sources/NautKit` | Swift package wrapping the C API |
| `macos/Sources/Naut` | The SwiftUI app, one consumer of NautKit |

libnaut is also a Zig package (`b.dependency("naut", .{}).module("naut")`).

Pages need no third-party script and work offline: math is converted to
MathML, which browsers render natively, and code is highlighted when the
note is rendered.

## Publishing

In Settings, enter your account ID and an API token with **Workers Scripts:
Edit**, **Workers KV Storage: Edit** and **Account Settings: Read**, then
**Set Up Publishing**. Each note's globe button publishes it to
`https://naut.<your-subdomain>.workers.dev/<note-name>`.

> **Note:** Terraform state lives in `~/Library/Application Support/Naut/terraform`.
> Don't delete it, or Terraform forgets what it created.
