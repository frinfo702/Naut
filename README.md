# Naut

Markdown notes on your Mac. One switch puts a note on the web.

Notes are plain `.md` files in `~/Documents/Naut`. The preview and the
published page are the same HTML, so what you see while writing is what
readers get. Publishing runs on your own Cloudflare account: Naut creates a
Worker and a KV namespace with Terraform, and after that they are ordinary
resources you can change in the dashboard.

## Build

```sh
direnv allow        # or: nix develop
zig build run       # builds libnaut, the xcframework and Naut.app, then opens it
zig build test      # core tests
(cd macos && swift test)
```

Swift comes from Xcode; Zig and Terraform come from the flake.

## Layout

| Path | What |
| --- | --- |
| `src/` | libnaut, the Zig core: Markdown, page template, Cloudflare publishing |
| `include/naut.h` | C API |
| `macos/Sources/NautKit` | Swift package wrapping the C API |
| `macos/Sources/Naut` | The SwiftUI app, one consumer of NautKit |

libnaut is also a Zig package (`b.dependency("naut", .{}).module("naut")`).

## Publishing

In Settings, enter your account ID and an API token with **Workers Scripts:
Edit**, **Workers KV Storage: Edit** and **Account Settings: Read**, then
**Set Up Publishing**. Each note's globe button publishes it to
`https://naut.<your-subdomain>.workers.dev/<note-name>`.

> **Note:** Terraform state lives in `~/Library/Application Support/Naut/terraform`.
> Don't delete it, or Terraform forgets what it created.
