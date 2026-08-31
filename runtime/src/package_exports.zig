//! package.json exports 解析子集。
//! 只返回包声明的 JS 目标；未声明 subpath 时由调用方 fail-closed。

const std = @import("std");

pub const Result = struct {
    declared: bool,
    target: ?[]const u8,
};

const conditions = [_][]const u8{ "import", "node", "default" };

/// Resolve one bare package specifier against its package.json exports field.
/// The output target is a package-relative path such as ./lib/index.js.
pub fn resolve(package_name: []const u8, specifier: []const u8, package_json: []const u8, out: []u8) Result {
    return resolveWithOptions(package_name, specifier, package_json, out, false);
}

pub fn resolveWithModule(package_name: []const u8, specifier: []const u8, package_json: []const u8, out: []u8) Result {
    return resolveWithOptions(package_name, specifier, package_json, out, true);
}

fn resolveWithOptions(package_name: []const u8, specifier: []const u8, package_json: []const u8, out: []u8, prefer_module: bool) Result {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, package_json, .{}) catch {
        return .{ .declared = false, .target = null };
    };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .declared = false, .target = null };
    const exports = parsed.value.object.get("exports") orelse
        return .{ .declared = false, .target = null };

    var subpath_buf: [768]u8 = undefined;
    const subpath = if (std.mem.eql(u8, specifier, package_name))
        "."
    else if (std.mem.startsWith(u8, specifier, package_name) and
        specifier.len > package_name.len and specifier[package_name.len] == '/')
        std.fmt.bufPrint(&subpath_buf, "./{s}", .{specifier[package_name.len + 1 ..]}) catch
            return .{ .declared = true, .target = null }
    else
        return .{ .declared = true, .target = null };

    return .{ .declared = true, .target = resolveExports(exports, subpath, out, prefer_module) };
}

fn resolveExports(value: std.json.Value, subpath: []const u8, out: []u8, prefer_module: bool) ?[]const u8 {
    if (value == .object and hasSubpathKeys(value.object)) {
        return resolveSubpathMap(value.object, subpath, out, prefer_module);
    }
    return resolveValue(value, null, out, prefer_module);
}

fn hasSubpathKeys(object: std.json.ObjectMap) bool {
    var it = object.iterator();
    while (it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, ".")) return true;
    }
    return false;
}

fn resolveSubpathMap(object: std.json.ObjectMap, subpath: []const u8, out: []u8, prefer_module: bool) ?[]const u8 {
    if (object.get(subpath)) |value| return resolveValue(value, null, out, prefer_module);

    var best_value: ?std.json.Value = null;
    var best_suffix: []const u8 = "";
    var best_prefix_len: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, key, "*")) continue;
        const prefix = key[0 .. key.len - 1];
        if (!std.mem.startsWith(u8, subpath, prefix) or prefix.len < best_prefix_len) continue;
        best_value = entry.value_ptr.*;
        best_suffix = subpath[prefix.len..];
        best_prefix_len = prefix.len;
    }
    if (best_value) |value| return resolveValue(value, best_suffix, out, prefer_module);
    return null;
}

fn resolveValue(value: std.json.Value, wildcard: ?[]const u8, out: []u8, prefer_module: bool) ?[]const u8 {
    switch (value) {
        .string => |target| return writeTarget(target, wildcard, out),
        .array => |items| {
            for (items.items) |item| {
                if (resolveValue(item, wildcard, out, prefer_module)) |hit| return hit;
            }
            return null;
        },
        .object => |object| {
            if (prefer_module) {
                if (object.get("module")) |candidate| {
                    if (resolveValue(candidate, wildcard, out, prefer_module)) |hit| return hit;
                }
            }
            for (conditions) |condition| {
                if (object.get(condition)) |candidate| {
                    if (resolveValue(candidate, wildcard, out, prefer_module)) |hit| return hit;
                }
            }
            return null;
        },
        else => return null,
    }
}

fn writeTarget(target: []const u8, wildcard: ?[]const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, target, "./")) return null;
    var segments = std.mem.splitScalar(u8, target[2..], '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return null;
    }

    var w: usize = 0;
    var i: usize = 0;
    while (i < target.len) : (i += 1) {
        if (target[i] == '*') {
            const suffix = wildcard orelse return null;
            if (w + suffix.len > out.len) return null;
            @memcpy(out[w .. w + suffix.len], suffix);
            w += suffix.len;
        } else {
            if (w >= out.len) return null;
            out[w] = target[i];
            w += 1;
        }
    }
    if (w == 0) return null;
    return out[0..w];
}

test "exports conditions and exact subpaths" {
    const metadata =
        "{\"exports\":{\".\":{\"import\":\"./esm/index.js\",\"node\":\"./node/index.js\",\"default\":\"./fallback.js\"},\"./invariant\":\"./lib/invariant.js\"}}";
    var out: [128]u8 = undefined;
    const root = resolve("demo", "demo", metadata, &out);
    try std.testing.expect(root.declared);
    try std.testing.expectEqualStrings("./esm/index.js", root.target.?);

    const sub = resolve("demo", "demo/invariant", metadata, &out);
    try std.testing.expectEqualStrings("./lib/invariant.js", sub.target.?);

    const hidden = resolve("demo", "demo/private", metadata, &out);
    try std.testing.expect(hidden.declared);
    try std.testing.expect(hidden.target == null);
}

test "exports patterns arrays and blocked targets" {
    const metadata =
        "{\"exports\":{\"./src/*\":[null,\"./src/*.js\"],\"./blocked\":null}}";
    var out: [128]u8 = undefined;
    const pattern = resolve("demo", "demo/src/util", metadata, &out);
    try std.testing.expectEqualStrings("./src/util.js", pattern.target.?);

    const blocked = resolve("demo", "demo/blocked", metadata, &out);
    try std.testing.expect(blocked.declared);
    try std.testing.expect(blocked.target == null);
}

test "module condition is explicit and does not alter node ordering" {
    const metadata = "{\"exports\":{\".\":{\"module\":\"./esm/index.js\",\"default\":\"./cjs/index.js\"}}}";
    var out: [128]u8 = undefined;
    const node_result = resolve("demo", "demo", metadata, &out);
    try std.testing.expectEqualStrings("./cjs/index.js", node_result.target.?);
    const module_result = resolveWithModule("demo", "demo", metadata, &out);
    try std.testing.expectEqualStrings("./esm/index.js", module_result.target.?);
}

test "packages without exports keep legacy fallback available" {
    const metadata = "{\"name\":\"demo\",\"main\":\"lib/index.js\"}";
    var out: [64]u8 = undefined;
    const result = resolve("demo", "demo/private", metadata, &out);
    try std.testing.expect(!result.declared);
    try std.testing.expect(result.target == null);
}
