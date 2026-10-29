//! Publishing notes to Cloudflare.
//!
//! There are two halves with different lifetimes:
//!
//! - `provision` runs once. It drives Terraform with the embedded
//!   cloudflare/main.tf to create a KV namespace and a Worker that serves
//!   it on workers.dev. We use Terraform rather than raw API calls so the
//!   result is ordinary, declarative infrastructure: the user can change it
//!   in the Cloudflare dashboard afterwards, and re-running provision
//!   converges instead of duplicating.
//!
//! - `put` and `delete` run on every publish and unpublish. They talk to
//!   the KV REST API directly. Going through Terraform here would mean
//!   tracking every note in tfstate and a multi-second plan per keystroke
//!   save, for no benefit.
//!
//! Every function takes a `diag` writer. On error, a sentence a person can
//! act on is written there; the error value itself is for control flow.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

const log = std.log.scoped(.cloudflare);

const main_tf = @embedFile("cloudflare/main.tf");
const worker_js = @embedFile("cloudflare/worker.js");

/// Name of the Worker and KV namespace we create. Also the Terraform
/// `name` variable default; keep them in sync.
pub const resource_name = "naut";

pub const Credentials = struct {
    /// 32 hex characters, from the dashboard URL or Account Home.
    account_id: []const u8,
    /// Needs Workers Scripts:Edit, Workers KV Storage:Edit and
    /// Account Settings:Read.
    api_token: []const u8,
};

pub const Site = struct {
    namespace_id: []const u8,
    /// e.g. "https://naut.alice.workers.dev". No trailing slash.
    url: []const u8,
};

pub const Error = error{ InvalidInput, TerraformNotFound, TerraformFailed, RequestFailed } ||
    Allocator.Error || Writer.Error;

/// Create (or converge) the publishing infrastructure. `workdir` holds the
/// Terraform configuration and state between runs; it must persist, since
/// losing tfstate means Terraform forgets what it created.
pub fn provision(
    alloc: Allocator,
    io: Io,
    creds: Credentials,
    workdir: []const u8,
    diag: *Writer,
) Error!Site {
    try validate(creds, diag);
    if (!std.fs.path.isAbsolute(workdir)) {
        try diag.print("workdir must be an absolute path, got '{s}'", .{workdir});
        return error.InvalidInput;
    }

    const terraform = try findTerraform(alloc, io, diag);

    const dir = Io.Dir.cwd().createDirPathOpen(io, workdir, .{}) catch |err| {
        try diag.print("could not create {s}: {t}", .{ workdir, err });
        return error.InvalidInput;
    };
    defer dir.close(io);
    // Always rewrite the config so an app update can change the infra.
    for ([_][2][]const u8{ .{ "main.tf", main_tf }, .{ "worker.js", worker_js } }) |f| {
        dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] }) catch |err| {
            try diag.print("could not write {s}/{s}: {t}", .{ workdir, f[0], err });
            return error.InvalidInput;
        };
    }

    // The app is launched by launchd with a minimal environment, so build
    // the child's from scratch rather than inheriting. HOME is needed for
    // Terraform's plugin cache and credentials lookup.
    var env: std.process.Environ.Map = .init(alloc);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TF_IN_AUTOMATION", "1");
    try env.put("CLOUDFLARE_API_TOKEN", creds.api_token);
    if (std.c.getenv("HOME")) |home| try env.put("HOME", std.mem.span(home));

    const var_arg = try std.fmt.allocPrint(alloc, "account_id={s}", .{creds.account_id});
    _ = try runTerraform(alloc, io, &env, workdir, &.{ terraform, "init", "-input=false", "-no-color" }, diag);
    _ = try runTerraform(alloc, io, &env, workdir, &.{
        terraform, "apply", "-auto-approve", "-input=false", "-no-color", "-var", var_arg,
    }, diag);
    const out = try runTerraform(alloc, io, &env, workdir, &.{ terraform, "output", "-json" }, diag);

    const Outputs = struct { namespace_id: struct { value: []const u8 } };
    const outputs = std.json.parseFromSliceLeaky(Outputs, alloc, out, .{ .ignore_unknown_fields = true }) catch {
        try diag.print("unexpected terraform output: {s}", .{out});
        return error.TerraformFailed;
    };

    const subdomain = try accountSubdomain(alloc, io, creds, diag);
    return .{
        .namespace_id = outputs.namespace_id.value,
        .url = try std.fmt.allocPrint(alloc, "https://{s}.{s}.workers.dev", .{ resource_name, subdomain }),
    };
}

/// Publish `value` under `key`. Overwrites.
pub fn put(
    alloc: Allocator,
    io: Io,
    creds: Credentials,
    namespace_id: []const u8,
    key: []const u8,
    value: []const u8,
    diag: *Writer,
) Error!void {
    try validate(creds, diag);
    const url = try kvUrl(alloc, creds, namespace_id, key, diag);
    _ = try request(alloc, io, creds, .PUT, url, value, diag);
}

/// Unpublish `key`. Deleting a key that does not exist succeeds.
pub fn delete(
    alloc: Allocator,
    io: Io,
    creds: Credentials,
    namespace_id: []const u8,
    key: []const u8,
    diag: *Writer,
) Error!void {
    try validate(creds, diag);
    const url = try kvUrl(alloc, creds, namespace_id, key, diag);
    _ = try request(alloc, io, creds, .DELETE, url, null, diag);
}

/// Check credentials before they get anywhere near a URL or argv. The
/// account id is interpolated into API paths, so it must be exactly hex.
fn validate(creds: Credentials, diag: *Writer) Error!void {
    if (!isHex(creds.account_id, 32)) {
        try diag.writeAll("Account ID should be 32 hexadecimal characters.");
        return error.InvalidInput;
    }
    if (creds.api_token.len == 0) {
        try diag.writeAll("API token is empty.");
        return error.InvalidInput;
    }
    for (creds.api_token) |c| if (!std.ascii.isPrint(c) or c == ' ') {
        try diag.writeAll("API token contains invalid characters.");
        return error.InvalidInput;
    };
}

fn isHex(s: []const u8, len: usize) bool {
    if (s.len != len) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn kvUrl(alloc: Allocator, creds: Credentials, namespace_id: []const u8, key: []const u8, diag: *Writer) Error![]const u8 {
    if (!isHex(namespace_id, 32)) {
        try diag.writeAll("Namespace ID should be 32 hexadecimal characters. Set up publishing again.");
        return error.InvalidInput;
    }
    // KV keys are at most 512 bytes and may not be "." or "..".
    if (key.len == 0 or key.len > 512 or std.mem.eql(u8, key, ".") or std.mem.eql(u8, key, "..")) {
        try diag.print("'{s}' cannot be used as a page address.", .{key});
        return error.InvalidInput;
    }

    var out: Writer.Allocating = .init(alloc);
    try out.writer.print("https://api.cloudflare.com/client/v4/accounts/{s}/storage/kv/namespaces/{s}/values/", .{
        creds.account_id, namespace_id,
    });
    try percentEncode(&out.writer, key);
    return out.written();
}

/// Encode everything except RFC 3986 unreserved characters, so a key can
/// never add path segments or a query to the API URL.
fn percentEncode(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn accountSubdomain(alloc: Allocator, io: Io, creds: Credentials, diag: *Writer) Error![]const u8 {
    const url = try std.fmt.allocPrint(alloc, "https://api.cloudflare.com/client/v4/accounts/{s}/workers/subdomain", .{creds.account_id});
    const body = try request(alloc, io, creds, .GET, url, null, diag);
    const Response = struct { result: ?struct { subdomain: []const u8 } = null };
    const res = std.json.parseFromSliceLeaky(Response, alloc, body, .{ .ignore_unknown_fields = true }) catch null;
    if (res) |r| if (r.result) |result| return result.subdomain;
    try diag.writeAll("This account has no workers.dev subdomain yet. Open Workers & Pages in the Cloudflare dashboard once to create it, then try again.");
    return error.RequestFailed;
}

/// One Cloudflare API call. Returns the response body on 2xx.
fn request(
    alloc: Allocator,
    io: Io,
    creds: Credentials,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    diag: *Writer,
) Error![]const u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{creds.api_token});
    var body: Writer.Allocating = .init(alloc);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = if (payload != null) .{ .override = "application/octet-stream" } else .default,
        },
        .response_writer = &body.writer,
    }) catch |err| {
        log.warn("(request) {t} {s} failed, err={t}", .{ method, url, err });
        try diag.print("Could not reach Cloudflare ({t}). Check your connection.", .{err});
        return error.RequestFailed;
    };

    if (res.status.class() != .success) {
        // Cloudflare's error bodies are JSON with a human message; pass
        // them through rather than guessing at a summary.
        try diag.print("Cloudflare returned {d}: {s}", .{ @intFromEnum(res.status), body.written() });
        return error.RequestFailed;
    }
    return body.written();
}

fn runTerraform(
    alloc: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    workdir: []const u8,
    argv: []const []const u8,
    diag: *Writer,
) Error![]const u8 {
    assert(argv.len >= 2);
    log.info("(runTerraform) terraform {s}", .{argv[1]});
    const res = std.process.run(alloc, io, .{
        .argv = argv,
        .cwd = .{ .path = workdir },
        .environ_map = env,
    }) catch |err| {
        try diag.print("Could not run terraform {s}: {t}", .{ argv[1], err });
        return error.TerraformFailed;
    };
    if (!res.term.success()) {
        try diag.print("terraform {s} failed:\n{s}", .{ argv[1], res.stderr });
        return error.TerraformFailed;
    }
    return res.stdout;
}

/// Find a terraform binary. GUI apps don't get the login shell's PATH, so
/// besides $PATH we look where Nix and Homebrew put it.
fn findTerraform(alloc: Allocator, io: Io, diag: *Writer) Error![]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    if (std.c.getenv("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, std.mem.span(path), ':');
        while (it.next()) |d| try dirs.append(alloc, d);
    }
    if (std.c.getenv("HOME")) |home| {
        try dirs.append(alloc, try std.fmt.allocPrint(alloc, "{s}/.nix-profile/bin", .{home}));
    }
    if (std.c.getenv("USER")) |user| {
        try dirs.append(alloc, try std.fmt.allocPrint(alloc, "/etc/profiles/per-user/{s}/bin", .{user}));
    }
    try dirs.appendSlice(alloc, &.{ "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin", "/opt/homebrew/bin", "/usr/local/bin" });

    for (dirs.items) |d| {
        if (!std.fs.path.isAbsolute(d)) continue;
        const candidate = try std.fs.path.join(alloc, &.{ d, "terraform" });
        Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    try diag.writeAll("terraform is not installed. Install it with: nix profile install nixpkgs#terraform (or brew install terraform)");
    return error.TerraformNotFound;
}

test "cloudflare: rejects malformed account id" {
    var buf: [256]u8 = undefined;
    var diag: Writer = .fixed(&buf);
    try std.testing.expectError(error.InvalidInput, validate(.{ .account_id = "../x", .api_token = "t" }, &diag));
    try std.testing.expectStringStartsWith(diag.buffered(), "Account ID");
}

test "cloudflare: kv url encodes the key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [256]u8 = undefined;
    var diag: Writer = .fixed(&buf);
    const id = "0123456789abcdef0123456789abcdef";
    const url = try kvUrl(arena.allocator(), .{ .account_id = id, .api_token = "t" }, id, "a/b?c 日", &diag);
    try std.testing.expectStringEndsWith(url, "/values/a%2Fb%3Fc%20%E6%97%A5");
    try std.testing.expectError(error.InvalidInput, kvUrl(arena.allocator(), .{ .account_id = id, .api_token = "t" }, id, "..", &diag));
}
