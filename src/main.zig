//! courier: a `zig fetch` alternative that honours HTTP proxy settings.
//!
//! It reads `build.zig.zon`, clones every `git+` dependency (recursively) with
//! the `git` CLI, then rewrites each manifest so the dependency is a `.path`
//! dependency pointing at the clone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zlog = @import("zlog");

var log: zlog.Logger = undefined;

const usage =
    \\Usage: courier [options] [project_dir]
    \\
    \\Fetch all dependencies listed in project_dir/build.zig.zon (and their
    \\dependencies) and rewrite the manifests to use `.path` instead.
    \\git+ URLs are cloned with git; http(s) tarballs are downloaded with curl
    \\(hashes are not verified).
    \\
    \\Options:
    \\  --deps-dir <dir>   Where to clone, relative to project_dir (default: .courier-deps)
    \\  --proxy <url>      Proxy for git and curl (default: their own config / http_proxy / https_proxy)
    \\  -h, --help         Show this help
    \\
;

const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

const GitUrl = struct {
    /// Repository URL without the `git+` prefix, fragment and query.
    repo: []const u8,
    /// Commit (or ref) from the `#fragment`.
    commit: []const u8,
};

const Ctx = struct {
    gpa: Allocator,
    io: std.Io,
    root: []const u8,
    deps_dir: []const u8,
    proxy: ?[]const u8,
    /// Folder names already cloned and processed in this run.
    seen: std.StringHashMapUnmanaged(void) = .empty,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    log = try zlog.Logger.init(.INFO, true, null, null, null, arena, init.io);
    defer log.deinit();

    var root: []const u8 = ".";
    var deps_dir: []const u8 = ".courier-deps";
    var proxy: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, a, "--deps-dir") or std.mem.eql(u8, a, "--proxy")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: {s} needs a value\n\n{s}", .{ a, usage });
                return 2;
            }
            if (a[2] == 'd') deps_dir = args[i] else proxy = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("error: unknown option '{s}'\n\n{s}", .{ a, usage });
            return 2;
        } else root = a;
    }

    var ctx: Ctx = .{
        .gpa = arena,
        .io = init.io,
        .root = root,
        .deps_dir = deps_dir,
        .proxy = proxy,
    };

    const root_manifest = try std.fmt.allocPrint(arena, "{s}/build.zig.zon", .{root});
    std.Io.Dir.cwd().access(init.io, root_manifest, .{}) catch {
        log.err("{s} not found", .{root_manifest});
        return 1;
    };

    processManifest(&ctx, root, true) catch |err| {
        log.err("{s}", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// Handles `<dir>/build.zig.zon`. `is_root` selects how relative paths to the
/// deps directory are built and whether a `.orig` backup is written.
fn processManifest(ctx: *Ctx, dir: []const u8, is_root: bool) anyerror!void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const path = try std.fmt.allocPrint(gpa, "{s}/build.zig.zon", .{dir});

    const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(4 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("{s} has no build.zig.zon, skipping", .{dir});
            return;
        },
        else => return err,
    };

    const ast = try std.zig.Ast.parse(gpa, source, .zon);
    const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    if (zoir.hasCompileErrors() or ast.errors.len != 0) {
        log.err("{s} has syntax errors", .{path});
        return error.InvalidManifest;
    }

    var edits: std.ArrayList(Edit) = .empty;

    const root_node = std.zig.Zoir.Node.Index.root.get(zoir);
    if (root_node == .struct_literal) {
        const top = root_node.struct_literal;
        for (top.names, 0..) |field, fi| {
            if (!std.mem.eql(u8, field.get(zoir), "dependencies")) continue;
            const deps = top.vals.at(@intCast(fi)).get(zoir);
            if (deps != .struct_literal) continue;
            for (deps.struct_literal.names, 0..) |dep_name, di| {
                const dep = deps.struct_literal.vals.at(@intCast(di)).get(zoir);
                if (dep != .struct_literal) continue;
                try processDep(ctx, ast, zoir, source, dep_name.get(zoir), dep.struct_literal, is_root, &edits);
            }
        }
    }

    if (edits.items.len == 0) return;

    std.mem.sort(Edit, edits.items, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (edits.items) |e| {
        try out.appendSlice(gpa, source[pos..e.start]);
        try out.appendSlice(gpa, e.text);
        pos = e.end;
    }
    try out.appendSlice(gpa, source[pos..]);

    if (is_root) {
        const orig = try std.fmt.allocPrint(gpa, "{s}.orig", .{path});
        std.Io.Dir.cwd().access(io, orig, .{}) catch {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = orig, .data = source });
            log.info("backup: {s}", .{orig});
        };
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    log.info("rewrote {s}", .{path});
}

fn processDep(
    ctx: *Ctx,
    ast: std.zig.Ast,
    zoir: std.zig.Zoir,
    source: []const u8,
    name: []const u8,
    dep: anytype,
    is_root: bool,
    edits: *std.ArrayList(Edit),
) anyerror!void {
    const gpa = ctx.gpa;

    var url_idx: ?usize = null;
    var hash_idx: ?usize = null;
    for (dep.names, 0..) |f, i| {
        const fname = f.get(zoir);
        if (std.mem.eql(u8, fname, "url")) url_idx = i;
        if (std.mem.eql(u8, fname, "hash")) hash_idx = i;
    }
    const ui = url_idx orelse return; // `.path` dependency: nothing to do
    const url_node = dep.vals.at(@intCast(ui));
    const url = switch (url_node.get(zoir)) {
        .string_literal => |s| s,
        else => return,
    };

    const git = parseGitUrl(url);
    const is_http = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    if (git == null and !is_http) {
        log.warn("dependency '{s}': unsupported URL scheme, leaving '{s}' untouched", .{ name, url });
        return;
    }

    const folder = if (git) |g| try folderName(gpa, g) else try tarballFolderName(gpa, name, url);
    if (!ctx.seen.contains(folder)) {
        try ctx.seen.put(gpa, folder, {});
        const dest = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ ctx.root, ctx.deps_dir, folder });
        if (git) |g| try cloneRepo(ctx, g, dest) else try fetchTarball(ctx, url, dest);
        try processManifest(ctx, dest, false);
    }

    const rel = if (is_root)
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ ctx.deps_dir, folder })
    else
        try std.fmt.allocPrint(gpa, "../{s}", .{folder});

    const url_span = fieldSpan(ast, url_node.getAstNode(zoir));
    try edits.append(gpa, .{
        .start = url_span.start,
        .end = url_span.end,
        .text = try std.fmt.allocPrint(gpa, ".path = \"{s}\"", .{rel}),
    });

    if (hash_idx) |hi| {
        const span = fieldSpan(ast, dep.vals.at(@intCast(hi)).getAstNode(zoir));
        // Remove the whole `.hash = "...",` field; take the whole line if it is alone on it.
        var start = span.start;
        var end = span.end;
        if (std.mem.startsWith(u8, source[end..], ",")) end += 1;
        var s = start;
        while (s > 0 and (source[s - 1] == ' ' or source[s - 1] == '\t')) s -= 1;
        var e = end;
        while (e < source.len and (source[e] == ' ' or source[e] == '\t')) e += 1;
        if ((s == 0 or source[s - 1] == '\n') and e < source.len and source[e] == '\n') {
            start = s;
            end = e + 1;
        }
        try edits.append(gpa, .{ .start = start, .end = end, .text = "" });
    }
}

/// Byte span of `.name = value`, given the AST node of `value`.
fn fieldSpan(ast: std.zig.Ast, value: std.zig.Ast.Node.Index) struct { start: usize, end: usize } {
    const first = ast.firstToken(value);
    const last = ast.lastToken(value);
    // Tokens before the value: `.`, `name`, `=`.
    return .{
        .start = ast.tokenStart(first - 3),
        .end = ast.tokenStart(last) + ast.tokenSlice(last).len,
    };
}

fn parseGitUrl(url: []const u8) ?GitUrl {
    const prefix = "git+";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    var rest = url[prefix.len..];
    var commit: []const u8 = "HEAD";
    if (std.mem.findScalar(u8, rest, '#')) |i| {
        commit = rest[i + 1 ..];
        rest = rest[0..i];
    }
    if (std.mem.findScalar(u8, rest, '?')) |i| rest = rest[0..i];
    if (rest.len == 0 or commit.len == 0) return null;
    return .{ .repo = rest, .commit = commit };
}

/// `<repo basename>-<first 12 chars of commit>`, with unsafe characters replaced.
fn folderName(gpa: Allocator, git: GitUrl) ![]const u8 {
    var base = git.repo;
    while (std.mem.endsWith(u8, base, "/")) base = base[0 .. base.len - 1];
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.endsWith(u8, base, ".git")) base = base[0 .. base.len - 4];
    const commit = git.commit[0..@min(12, git.commit.len)];
    const out = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ base, commit });
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-' and c.* != '_' and c.* != '.') c.* = '_';
    }
    return out;
}

/// `<dep name>-<first 12 hex chars of sha256(url)>`.
fn tarballFolderName(gpa: Allocator, name: []const u8, url: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "{s}-{s}", .{ name, hex[0..12] });
}

/// Downloads `url` with curl (honours http_proxy/https_proxy/--proxy) and
/// unpacks it into `dest` with tar. A single top-level directory is stripped,
/// like `zig fetch` does. The package hash is NOT verified.
fn fetchTarball(ctx: *Ctx, url: []const u8, dest: []const u8) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    if (std.Io.Dir.cwd().access(io, dest, .{})) |_| {
        log.info("exists: {s}", .{dest});
        return;
    } else |_| {}

    log.info("download: {s}", .{url});
    try std.Io.Dir.cwd().createDirPath(io, dest);
    errdefer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    const archive = try std.fmt.allocPrint(gpa, "{s}.download", .{dest});
    defer std.Io.Dir.cwd().deleteFile(io, archive) catch {};

    var curl: std.ArrayList([]const u8) = .empty;
    try curl.append(gpa, "curl");
    if (ctx.proxy) |p| try curl.appendSlice(gpa, &.{ "--proxy", p });
    try curl.appendSlice(gpa, &.{ "--fail", "--silent", "--show-error", "--location", "--output", archive, url });
    _ = try runTool(ctx, curl.items);

    const listing = try runTool(ctx, &.{ "tar", "-tf", archive });
    var strip = false;
    var root: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const slash = std.mem.findScalar(u8, line, '/') orelse {
            strip = false;
            break;
        };
        const first = line[0..slash];
        if (root) |r| {
            if (!std.mem.eql(u8, r, first)) {
                strip = false;
                break;
            }
        } else root = first;
        strip = true;
    }

    var untar: std.ArrayList([]const u8) = .empty;
    try untar.appendSlice(gpa, &.{ "tar", "-xf", archive, "-C", dest });
    if (strip) try untar.append(gpa, "--strip-components=1");
    _ = try runTool(ctx, untar.items);
}

fn cloneRepo(ctx: *Ctx, git: GitUrl, dest: []const u8) !void {
    const gpa = ctx.gpa;
    if (std.Io.Dir.cwd().access(ctx.io, dest, .{})) |_| {
        log.info("exists: {s}", .{dest});
        return;
    } else |_| {}

    log.info("clone: {s} @ {s}", .{ git.repo, git.commit });

    var clone: std.ArrayList([]const u8) = .empty;
    try clone.append(gpa, "git");
    if (ctx.proxy) |p| {
        try clone.append(gpa, "-c");
        try clone.append(gpa, try std.fmt.allocPrint(gpa, "http.proxy={s}", .{p}));
    }
    try clone.appendSlice(gpa, &.{ "clone", "--quiet", "--no-checkout", git.repo, dest });
    try runGit(ctx, clone.items);

    try runGit(ctx, &.{ "git", "-C", dest, "-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", git.commit });
}

fn runGit(ctx: *Ctx, argv: []const []const u8) !void {
    _ = try runTool(ctx, argv);
}

/// Runs a command, returns its stdout; logs stderr and fails on a non-zero exit.
fn runTool(ctx: *Ctx, argv: []const []const u8) ![]const u8 {
    const res = try std.process.run(ctx.gpa, ctx.io, .{ .argv = argv });
    switch (res.term) {
        .exited => |code| if (code == 0) return res.stdout,
        else => {},
    }
    log.err("{s} failed: {s}\n{s}", .{ argv[0], argv[argv.len - 1], res.stderr });
    return error.ToolFailed;
}

test "parseGitUrl" {
    const g = parseGitUrl("git+https://github.com/a/b.git?ref=v1#abcdef1234567890").?;
    try std.testing.expectEqualStrings("https://github.com/a/b.git", g.repo);
    try std.testing.expectEqualStrings("abcdef1234567890", g.commit);
    try std.testing.expect(parseGitUrl("https://x/y.tar.gz") == null);
}

test "folderName" {
    const n = try folderName(std.testing.allocator, parseGitUrl("git+https://github.com/a/b.git#abcdef1234567890").?);
    defer std.testing.allocator.free(n);
    try std.testing.expectEqualStrings("b-abcdef123456", n);
}
