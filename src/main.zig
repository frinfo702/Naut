//! libnaut: the core of Naut, usable on its own.
//!
//! Naut is a Markdown notes app whose notes can be published to the web
//! with one switch. Everything that is not UI lives here so that the macOS
//! app is just one consumer: rendering (`markdown`, `page`) and publishing
//! (`cloudflare`). The C API in c.zig wraps these for Swift.

const std = @import("std");

pub const markdown = @import("markdown.zig");
pub const page = @import("page.zig");
pub const cloudflare = @import("cloudflare.zig");
pub const css = @import("css");
pub const highlight = @import("highlight");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("c.zig"));
}
