//! /api 浏览器信任栅栏（protocol.md §2.5）—— api-request-trust.ts 逐函数语义移植。
//! DNS-rebinding 防护：Host 头绑定 + sec-fetch-site/origin 跨界拒绝。
//! 子集决策（fail-closed）：非括号 IPv6 与未压缩 IPv6 形态拒绝（TS 经 WHATWG
//! 规范化比较，未压缩形态必然失配；此处 load 期拒绝，绝不静默放行）。
//! 零分配：比较全部经大小写不敏感切片（WHATWG hostname 归一 ≈ lowercase）。
//! 基准：packages/client/connection/tests/api-request-trust.host.spec.ts 全部用例。
//! 验证：`zig build trust-fence-smoke-run`。

const std = @import("std");

pub const Authority = struct {
    /// hostname（原样；比较时大小写不敏感；IPv6 保留括号与"已压缩"形态）
    host: []const u8,
    /// 显式端口（无默认端口剥离——TS 经 http/https 双 scheme 检回，显式端口恒保留）
    port: ?[]const u8,
};

fn isForbiddenChar(ch: u8) bool {
    if (ch < 0x20 or ch == 0x7f) return true;
    return ch == '/' or ch == '?' or ch == '#' or ch == '@' or ch == '\\' or ch == ' ' or ch == '"' or ch == '<' or ch == '>';
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c\xc2\xa0");
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lo_x = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const lo_y = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lo_x != lo_y) return false;
    }
    return true;
}

/// `host[:port]` 裸 authority 解析（WHATWG 近似子集）：
///   - 前后空白 trim（TS：WHATWG strip；isTrustedAuthority 须匹配）
///   - 内嵌空白/控制/`/ ? # @ \` → 失败（bare authority 要求）
///   - 非括号形态含 ':' → 失败（unbracketed IPv6 拒绝）
///   - port 非纯十进制 / 前导零 → 失败（不静默收窄放宽口径）
///   - 括号 IPv6：未压缩形态（无 "::"）→ 失败（fail-closed）
pub fn parseAuthority(a: []const u8) ?Authority {
    const entry = trimWs(a);
    if (entry.len == 0) return null;
    for (entry) |ch| {
        if (isForbiddenChar(ch)) return null;
    }
    if (isHexIpv4Like(entry)) return null; // 0x7f.0.0.1 形：WHATWG 会规范化改写 → 拒绝
    if (entry[0] == '[') {
        const close = std.mem.indexOfScalar(u8, entry, ']') orelse return null;
        const host_raw = entry[1..close];
        if (host_raw.len == 0) return null;
        if (std.mem.indexOf(u8, host_raw, "::") == null) return null; // 未压缩 IPv6 → 拒绝
        var port: ?[]const u8 = null;
        if (close + 1 < entry.len) {
            if (entry[close + 1] != ':') return null;
            const port_raw = entry[close + 2 ..];
            if (!validPort(port_raw)) return null;
            port = port_raw;
        }
        return .{ .host = entry[0 .. close + 1], .port = port }; // hostname 保留括号（WHATWG 形状）
    }
    const idx = std.mem.lastIndexOfScalar(u8, entry, ':') orelse {
        return .{ .host = entry, .port = null };
    };
    if (idx == entry.len - 1) return null; // 悬空冒号
    if (std.mem.indexOfScalar(u8, entry[0..idx], ':') != null) return null; // 非括号多':' → IPv6 拒绝
    const port_raw = entry[idx + 1 ..];
    if (!validPort(port_raw)) return null;
    return .{ .host = entry[0..idx], .port = port_raw };
}

fn isHexIpv4Like(s: []const u8) bool {
    // 含 'x'/'X' 且无括号 → 十六进制 IPv4 形（WHATWG 会改写）
    if (s.len == 0 or s[0] == '[') return false;
    return std.mem.indexOfAny(u8, s, "xX") != null;
}

fn validPort(p: []const u8) bool {
    if (p.len == 0) return false;
    if (p[0] == '0' and p.len > 1) return false; // 前导零
    for (p) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// canonical（TS: canonicalAuthority）—— 渲染 host 或 host:port，
/// 与原始串的"大小写不敏感版本"比对（WHATWG 归一 ≈ lowercase）。
fn matchesCanonical(entry: []const u8, a: Authority) bool {
    var i: usize = 0;
    // host 段
    for (a.host) |ch| {
        if (i >= entry.len) return false;
        const e = entry[i];
        const lo_e = if (e >= 'A' and e <= 'Z') e + 32 else e;
        const lo_c = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        if (lo_e != lo_c) return false;
        i += 1;
    }
    if (a.port) |p| {
        if (i >= entry.len or entry[i] != ':') return false;
        i += 1;
        for (p) |ch| {
            if (i >= entry.len or entry[i] != ch) return false;
            i += 1;
        }
    }
    return i == entry.len;
}

/// loopback：localhost | [::1] | 127/8 四段 IPv4（≤255；大小写不敏感）
pub fn isLoopbackHostname(host: []const u8) bool {
    if (eqIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const part = it.next() orelse return false;
        if (part.len == 0 or part.len > 3) return false;
        for (part) |ch| {
            if (ch < '0' or ch > '9') return false;
        }
        const v = std.fmt.parseInt(u16, part, 10) catch return false;
        if (v > 255) return false;
        if (i == 0 and !std.mem.eql(u8, part, "127")) return false;
    }
    return it.next() == null;
}

/// WHATWG URL.host 归一：默认端口 80 剥离（TS: entryUrl.host 经 http scheme）。
fn normUrlPort(p: ?[]const u8) ?[]const u8 {
    if (p) |x| {
        if (std.mem.eql(u8, x, "80")) return null;
        return x;
    }
    return null;
}

/// trusted 条目匹配：无端口条目 → hostname 任意端口；显式端口 → 精确 host:port。
/// 不可解析的条目不匹配（不抛、不毒化列表——TS 同语义）。
pub fn isTrustedAuthority(a: Authority, trustedHosts: []const []const u8) bool {
    for (trustedHosts) |entry| {
        const ea = parseAuthority(entry) orelse continue;
        if (!eqIgnoreCase(ea.host, a.host)) continue;
        // TS 三目：canonical 无端口（entry 无显式端口）→ 比 hostname；
        // canonical 有端口（显式任意端口，含 :80 经 https 检回）→ 比 URL.host
        //（80 剥默认端口；其余显式精确）。
        if (ea.port == null) return true;
        const entry_norm = normUrlPort(ea.port);
        const host_norm = normUrlPort(a.port);
        if (entry_norm == null and host_norm == null) return true;
        if (entry_norm == null or host_norm == null) continue;
        if (std.mem.eql(u8, entry_norm.?, host_norm.?)) return true;
    }
    return false;
}

/// 配置边界：bare authority 校验（TS assertTrustedAuthority 的判定；调用侧决定失败动作）。
pub fn assertTrustedAuthority(entry: []const u8) bool {
    const a = parseAuthority(entry) orelse return false;
    return matchesCanonical(entry, a);
}

/// 主入口：Host 头绑定（DNS-rebinding 防线，markerless 请求同样适用）→
/// cross-site 标记拒绝 → Origin 同源比较（缺失 Origin 由 Host 已绑定放行）。"null" opaque 拒绝。
pub fn isTrustedApiRequest(
    host: ?[]const u8,
    sec_fetch_site: ?[]const u8,
    origin: ?[]const u8,
    trustedHosts: []const []const u8,
) bool {
    const h = host orelse return false;
    if (h.len == 0) return false;
    const ha = parseAuthority(h) orelse return false;
    if (!isLoopbackHostname(ha.host) and !isTrustedAuthority(ha, trustedHosts)) return false;
    if (sec_fetch_site) |s| {
        if (std.mem.eql(u8, s, "cross-site")) return false;
    }
    const o = origin orelse return true;
    const scheme_end = std.mem.indexOf(u8, o, "://") orelse return false;
    var auth_end = o.len;
    var k = scheme_end + 3;
    while (k < o.len) : (k += 1) {
        if (o[k] == '/' or o[k] == '?' or o[k] == '#') {
            auth_end = k;
            break;
        }
    }
    const oa = parseAuthority(o[scheme_end + 3 .. auth_end]) orelse return false;
    if (!eqIgnoreCase(oa.host, ha.host)) return false;
    const o_norm = normUrlPort(oa.port);
    const h_norm = normUrlPort(ha.port);
    if (o_norm == null and h_norm == null) return true;
    if (o_norm == null or h_norm == null) return false;
    return std.mem.eql(u8, o_norm.?, h_norm.?);
}
