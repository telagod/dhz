//! 插件树启动链 smoke（`zig build boot-smoke-run`）：
//! entry（bootstrap/entry.mjs）经 seam.ModuleHost.import（适配器）进入 →
//! cordis Context + 真实插件装载（fs-local 后端/timer）→ consumer 消费 →
//! 完成标志。验证「entry import → seam → cordis bootstrap」链。零泄漏哨兵。
const std = @import("std");
const adapter = @import("loader_adapter.zig");
const engine_c = @import("engine_c.zig");
const hs = @import("host_services.zig");
const bridge = @import("fs_bridge.zig");
const sqlite_bridge = @import("sqlite_bridge.zig");
const crypto_bridge = @import("crypto_bridge.zig");
const proc_bridge = @import("proc_bridge.zig");
const http_bridge = @import("http_bridge.zig");
const loop_mod = @import("event_loop.zig");
const pol_mod = @import("policy.zig");
const http_svc = @import("http_server.zig");
const fs_svc = @import("fs_service.zig");
const sock_c = http_svc.c;

const c = engine_c.c;

fn readGlobalStr(ctx: ?*c.JSContext, name: [*c]const u8) ![]const u8 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    const s = c.JS_ToCStringLen(ctx, null, v) orelse return error.NoText;
    defer c.JS_FreeCString(ctx, s);
    return std.heap.page_allocator.dupe(u8, std.mem.span(s));
}

fn readGlobalInt(ctx: ?*c.JSContext, name: [*c]const u8) !i32 {
    const global = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global);
    const v = c.JS_GetPropertyStr(ctx, global, name);
    defer c.JS_FreeValue(ctx, v);
    var out: c_int = 0;
    _ = c.JS_ToInt32(ctx, &out, v);
    return out;
}

// —— headless 模式（M-2 CLI 合约雏形）：dsh headless --profile <json> [--prompt p --model m --mock-port n]
const HeadlessCfg = struct {
    provider: []const u8 = "mock",
    model: []const u8 = "mock-model",
    prompt: []const u8 = "hi",
    base_url: []const u8 = "http://127.0.0.1:18099",
    mock_port: u16 = 18099,
};

fn parseHeadlessArgs(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !HeadlessCfg {
    var cfg: HeadlessCfg = .{};
    var profile_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--profile") and i + 1 < args.len) {
            profile_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--prompt") and i + 1 < args.len) {
            cfg.prompt = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--model") and i + 1 < args.len) {
            cfg.model = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--mock-port") and i + 1 < args.len) {
            cfg.mock_port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        }
    }
    if (profile_path) |pp| {
        try loadProfileFile(alloc, io, pp, &cfg);
    } else {
        // 默认发现顺序（CLI 合约雏形）：cwd/headless-profile.json → $DSH_HOME/headless-profile.json
        const cwd_path = "headless-profile.json";
        const cwd_exists = blk: {
            _ = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, cwd_path, .{}) catch |e| {
                if (e == error.FileNotFound) break :blk false;
                break :blk true;
            };
            break :blk true;
        };
        if (cwd_exists) {
            try loadProfileFile(alloc, io, cwd_path, &cfg);
        } else if (std.c.getenv("DSH_HOME")) |dh| {
            const dsh_path = try std.fmt.allocPrint(alloc, "{s}/headless-profile.json", .{dh});
            defer alloc.free(dsh_path);
            const dsh_exists = blk: {
                _ = std.Io.Dir.statFile(std.Io.Dir.cwd(), io, dsh_path, .{}) catch |e| {
                    if (e == error.FileNotFound) break :blk false;
                    break :blk true;
                };
                break :blk true;
            };
            if (dsh_exists) try loadProfileFile(alloc, io, dsh_path, &cfg);
        }
    }
    return cfg;
}

fn loadProfileFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, cfg: *HeadlessCfg) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(1 << 20));
    defer alloc.free(data);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (obj.get("provider")) |v| {
        if (v == .string) cfg.provider = try alloc.dupe(u8, v.string);
    }
    if (obj.get("model")) |v| {
        if (v == .string) cfg.model = try alloc.dupe(u8, v.string);
    }
    if (obj.get("prompt")) |v| {
        if (v == .string) cfg.prompt = try alloc.dupe(u8, v.string);
    }
    if (obj.get("baseURL")) |v| {
        if (v == .string) cfg.base_url = try alloc.dupe(u8, v.string);
    }
    if (obj.get("mockPort")) |v| {
        if (v == .integer) cfg.mock_port = @intCast(v.integer);
    }
}

/// 峰值/即时 RSS 采样（M-4 压力测试：VmRSS 从 /proc/self/status）
fn readVmRss(io: std.Io) u64 {
    const f = std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{}) catch return 0;
    defer f.close(io);
    var data: [65536]u8 = undefined;
    const n = std.Io.File.readPositionalAll(f, io, data[0..], 0) catch { std.debug.print("[rss] read err\n", .{}); return 0; };
    const marker = "VmRSS:";
    const at = std.mem.indexOf(u8, data[0..n], marker) orelse return 0;
    var rest = std.mem.trim(u8, data[at + marker.len .. n], " \t\r\n");
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    rest = rest[0..sp];
    return std.fmt.parseInt(u64, rest, 10) catch 0;
}

fn printJsMemory(rt: *c.JSRuntime, label: []const u8) void {
    if (std.c.getenv("DSH_PERF_TRACE") == null) return;
    c.JS_RunGC(rt);
    var usage: c.JSMemoryUsage = undefined;
    c.JS_ComputeMemoryUsage(rt, &usage);
    std.debug.print("perf: {s} malloc={d}KiB used={d}KiB atoms={d}/{d}KiB strings={d}/{d}KiB objects={d}/{d}KiB props={d}/{d}KiB shapes={d}/{d}KiB funcs={d}/{d}KiB code={d}KiB pc2line={d}KiB arrays={d} binaries={d}/{d}KiB limit={d}KiB\n", .{
        label,
        @divTrunc(usage.malloc_size, 1024),
        @divTrunc(usage.memory_used_size, 1024),
        usage.atom_count, @divTrunc(usage.atom_size, 1024),
        usage.str_count, @divTrunc(usage.str_size, 1024),
        usage.obj_count, @divTrunc(usage.obj_size, 1024),
        usage.prop_count, @divTrunc(usage.prop_size, 1024),
        usage.shape_count, @divTrunc(usage.shape_size, 1024),
        usage.js_func_count, @divTrunc(usage.js_func_size, 1024),
        usage.array_count, usage.binary_object_count, @divTrunc(usage.binary_object_size, 1024),
        @divTrunc(usage.js_func_code_size, 1024), @divTrunc(usage.js_func_pc2line_size, 1024), @divTrunc(usage.malloc_limit, 1024),
    });
}

const ItBudget = struct { limit: i64 = 0, count: i64 = 0 };
fn jsInterruptCb(_: ?*c.JSRuntime, userdata: ?*anyopaque) callconv(.c) c_int {
    const p = userdata orelse return 0;
    const b: *ItBudget = @ptrCast(@alignCast(p));
    b.count += 1;
    return if (b.count >= b.limit) 1 else 0;
}

/// 宿主单调时钟（engine-ready 口径计时）。
fn monoNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

pub fn main(init: std.process.Init) !void {
    const boot_t0 = monoNs();
    const alloc = std.heap.page_allocator;
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var ait = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer ait.deinit();
    while (ait.next()) |a| try args_list.append(alloc, a);
    const cli_args = args_list.items;
    const headless_mode = cli_args.len > 1 and std.mem.eql(u8, cli_args[1], "headless");
    const web_mode = cli_args.len > 1 and std.mem.eql(u8, cli_args[1], "web");
    const core_mode = cli_args.len > 1 and std.mem.eql(u8, cli_args[1], "core");
    const headless_cfg = if (headless_mode) try parseHeadlessArgs(alloc, init.io, cli_args) else HeadlessCfg{ .mock_port = 18099 };
    if (headless_mode) std.debug.print("headless mode: provider={s} model={s} prompt='{s}' mockPort={d}\n", .{ headless_cfg.provider, headless_cfg.model, headless_cfg.prompt, headless_cfg.mock_port });
    // —— Web 常驻服务模式：DSH_WEB_PORT（默认 18086，自检与 guest 监听同口）；
    //    DSH_WEB_SERVE 置位时断言全过后驻留事件循环对外服务，SIGTERM/SIGINT 干净退出。
    const web_port: u16 = blk: {
        const s = std.c.getenv("DSH_WEB_PORT") orelse break :blk 18086;
        break :blk std.fmt.parseInt(u16, std.mem.span(s), 10) catch 18086;
    };
    const web_serve = web_mode and std.c.getenv("DSH_WEB_SERVE") != null;
    // —— 真 LLM 渠道模式：DSH_LLM_REAL 置位 → guest 走 llm-relay（本地 HTTP→上游 HTTPS+Bearer）。
    //    密钥只存在于 relay 进程（读 ~/.dsh/.credentials.yaml），不进 Zig/guest。
    const llm_real = std.c.getenv("DSH_LLM_REAL") != null;
    const llm_provider: []const u8 = blk: {
        const s = std.c.getenv("DSH_LLM_PROVIDER") orelse break :blk "a6api";
        break :blk std.mem.span(s);
    };
    const llm_model: []const u8 = blk: {
        const s = std.c.getenv("DSH_LLM_MODEL") orelse break :blk "glm-5.3-flash";
        break :blk std.mem.span(s);
    };
    const llm_relay_port: u16 = blk: {
        const s = std.c.getenv("DSH_LLM_RELAY_PORT") orelse break :blk 18100;
        break :blk std.fmt.parseInt(u16, std.mem.span(s), 10) catch 18100;
    };
    const llm_import: []const u8 = blk: {
        const s = std.c.getenv("DSH_LLM_IMPORT") orelse break :blk "";
        break :blk std.mem.span(s);
    };
    // seam 适配器（自建引擎）；宿主服务注册到适配器 ctx（同引擎同 ctx）
    var act = try adapter.Adapter.init();
    defer act.deinit();
    const act_ctx = act.host.ctx;
    defer http_stop(act_ctx); // 桥引用纪律：任何路径（含早期错误）都释放路由/连接回调
    // —— 单实例预检：另一存活 boot-smoke/dsh-zig-runtime 进程存在时，本 boot 会在异步链上
    //    停滞（共享 llm-mock 18099 与会话库——历史上反复误报 ScaleSessions，N 次踩坑）。
    //    WAL 空闲窗口下 sqlite BEGIN IMMEDIATE 拦不住（已实测）——单实例的本质是进程，扫 /proc。
    {
        const self_pid = std.os.linux.getpid();
        var proc_dir = std.Io.Dir.openDirAbsolute(init.io, "/proc", .{ .iterate = true }) catch null;
        if (proc_dir) |*pd| {
            defer pd.close(init.io);
            var it = pd.iterate();
            var offenders: usize = 0;
            var first_offender: i32 = 0;
            while (it.next(init.io) catch null) |ent| {
                if (ent.kind != .directory) continue;
                const ep = std.fmt.parseInt(i32, ent.name, 10) catch continue;
                if (ep == self_pid) continue;
                var cmd_buf: [256]u8 = undefined;
                const cmd_path = std.fmt.bufPrintZ(&cmd_buf, "/proc/{d}/cmdline", .{ep}) catch continue;
                var f = std.Io.Dir.cwd().openFile(init.io, cmd_path, .{}) catch continue;
                defer f.close(init.io);
                var cbuf: [256]u8 = undefined;
                const cn = f.readPositionalAll(init.io, &cbuf, 0) catch 0;
                const content = cbuf[0..cn]; // /proc 文件 st_size=0——readFileAlloc 直接回空（已实测）
                // 精确形态：可执行文件路径（/boot-smoke 或 dsh-zig-runtime），排除构建命令行
                // （zig build / build runner / 探测 shell 的 cmdline 含 "boot-smoke-run" 字样——曾致自锁）
                const looks_runner = (std.mem.indexOf(u8, content, "/boot-smoke") != null or std.mem.indexOf(u8, content, "dsh-zig-runtime") != null) and std.mem.indexOf(u8, content, "boot-smoke-run") == null;
                if (looks_runner) {
                    offenders += 1;
                    if (first_offender == 0) first_offender = ep;
                }
            }
            if (offenders > 0) {
                std.debug.print("boot preflight: 检测到 {d} 个存活运行时实例（首个 pid={d}）——单实例设计，并发 boot 必停滞。先停旧实例：dhz-web stop（或 kill {d}）\n", .{ offenders, first_offender, first_offender });
                return error.InstanceAlreadyRunning;
            }
        }
    }
    // —— LLM mock 自拉起（boot 依赖面：fetch/gwPost 断言——端口被占则用现有实例）
    const g_mock_pid = blk: {
        const mw = @cImport({ @cInclude("proc_wrap.h"); });
        var mport_buf: [16]u8 = undefined;
        const mport_z = try std.fmt.bufPrintZ(&mport_buf, "{d}", .{headless_cfg.mock_port});
        const margv = [_]?[*:0]const u8{ "python3", "tools/llm-mock.py", @ptrCast(mport_z.ptr), null };
        var m_in: c_int = 0;
        var m_out: c_int = 0;
        var m_err: c_int = 0;
        var m_pid: c_int = 0;
        if (mw.dsh_proc_spawn(@ptrCast(&margv), null, &m_in, &m_out, &m_err, &m_pid, "", 2) != 0) break :blk 0;
        break :blk m_pid;
    };
    const rss_start = readVmRss(init.io);
    if (g_mock_pid > 0) {
        std.debug.print("boot smoke: llm mock spawned pid={d}\n", .{g_mock_pid});
    } else {
        std.debug.print("boot smoke: llm mock spawn skipped (external instance assumed)\n", .{});
    }
    const mock_pid_caught = g_mock_pid;
    defer killMockPidDo(mock_pid_caught);
    // —— 真渠道中继自拉起（同 mock 形态：端口被占则用现有实例）
    const g_relay_pid = if (llm_real) blk: {
        const rw = @cImport({ @cInclude("proc_wrap.h"); });
        var rport_buf: [16]u8 = undefined;
        const rport_z = try std.fmt.bufPrintZ(&rport_buf, "{d}", .{llm_relay_port});
        const rargv = [_]?[*:0]const u8{ "python3", "tools/llm-relay.py", @ptrCast(rport_z.ptr), null };
        var r_in: c_int = 0;
        var r_out: c_int = 0;
        var r_err: c_int = 0;
        var r_pid: c_int = 0;
        if (rw.dsh_proc_spawn(@ptrCast(&rargv), null, &r_in, &r_out, &r_err, &r_pid, "", 2) != 0) break :blk 0;
        break :blk r_pid;
    } else 0;
    if (llm_real) {
        std.debug.print("boot smoke: llm relay spawned pid={d} port={d} provider={s} model={s}\n", .{ g_relay_pid, llm_relay_port, llm_provider, llm_model });
    }
    const relay_pid_caught = g_relay_pid;
    defer killMockPidDo(relay_pid_caught); // 函数域 defer——块内 defer 会在 if 出块即杀中继（已踩）
    // Web 网关形态：事件循环挂引擎 ctx（http.start 的 opaque 读取面）
    var loop = try loop_mod.Loop.init();
    defer loop.deinit();
    _ = c.JS_SetContextOpaque(act_ctx, @ptrCast(&loop));
    loop.attachEngine(act.host.rt, act_ctx);
    loop.onFdEvent = http_bridge.onLoopFdEvent;
    var env_buf: [256]u8 = undefined;
    const env_home = std.c.getenv("HOME") orelse "/root";
    const env_dsh_home = std.c.getenv("DSH_HOME") orelse "/root/.dsh";
    const env_tmp = std.c.getenv("TMPDIR") orelse "/tmp";
    const env_pairs = [_][]const u8{
        "DSH_PERMISSION_MODE=danger-full-access",
        std.fmt.bufPrint(env_buf[0..], "HOME={s}", .{env_home}) catch "HOME=/root",
        std.fmt.bufPrint(env_buf[64..], "DSH_HOME={s}", .{env_dsh_home}) catch "DSH_HOME=/root/.dsh",
        std.fmt.bufPrint(env_buf[128..], "TMPDIR={s}", .{env_tmp}) catch "TMPDIR=/tmp",
    };
    hs.installProcessShim(@as(?*c.JSContext, act_ctx), &env_pairs);
    const services = [_]hs.Service{
        .{ .name = "fs", .methods = &bridge.serviceMethods },
        .{ .name = "sqlite", .methods = &sqlite_bridge.serviceMethods },
        .{ .name = "crypto", .methods = &crypto_bridge.serviceMethods },
        .{ .name = "proc", .methods = &proc_bridge.serviceMethods },
        .{ .name = "http", .methods = &http_bridge.serviceMethods },
        .{ .name = "timer", .methods = &loop_mod.serviceMethods },
    };
    hs.register(@as(?*c.JSContext, act_ctx), &services);
    // 沙箱政策透传（与 guest SandboxPolicyService 一致：workspace-write /tmp——proc landlock 面）
    const ws_pol = pol_mod.Policy.init(pol_mod.Mode.workspace_write, "/tmp");
    proc_bridge.setPolicy(&ws_pol);

    // —— core 模式注入（性能模式：bundle 行不并入——小闭包基线）
    if (core_mode) {
        const cs = "globalThis.__coreMode = true;";
        _ = c.JS_Eval(act_ctx, cs.ptr, cs.len, "core-mode.js", c.JS_EVAL_TYPE_GLOBAL);
    }
    // —— headless cfg 注入（entry 探测消费：baseURL/prompt——M-2 单次 agent 配置面）
    {
        // 手写 JSON（字段值均为安全字符集——无引号/反斜杠；std.json 0.16 已无 stringifyAlloc）
        const cfg_json = try std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"model\":\"{s}\",\"prompt\":\"{s}\",\"baseURL\":\"{s}\",\"mockPort\":{d}}}", .{ headless_cfg.provider, headless_cfg.model, headless_cfg.prompt, headless_cfg.base_url, headless_cfg.mock_port });
        defer alloc.free(cfg_json);
        const set_src = try std.fmt.allocPrint(alloc, "globalThis.__headlessCfg = '{s}';", .{cfg_json});
        defer alloc.free(set_src);
        _ = c.JS_Eval(act_ctx, set_src.ptr, set_src.len, "headless-cfg.js", c.JS_EVAL_TYPE_GLOBAL);
    }
    // —— 真渠道 cfg 注入（entry 探测消费：provider/model/relay base——DSH_LLM_REAL 面）
    if (llm_real) {
        const rjson = try std.fmt.allocPrint(alloc, "{{\"provider\":\"{s}\",\"model\":\"{s}\",\"base\":\"http://127.0.0.1:{d}\",\"importPath\":\"{s}\"}}", .{ llm_provider, llm_model, llm_relay_port, llm_import });
        defer alloc.free(rjson);
        const rsrc = try std.fmt.allocPrint(alloc, "globalThis.__dshLlmReal = '{s}';", .{rjson});
        defer alloc.free(rsrc);
        _ = c.JS_Eval(act_ctx, rsrc.ptr, rsrc.len, "llm-real-cfg.js", c.JS_EVAL_TYPE_GLOBAL);
    }
    // —— M-4 安全边界（不受信代码面自测）：内存上限 + 执行中断
    {
        // 内存上限：300MB ArrayBuffer 应被 256MB 限制拒绝（异常而非 OOM 崩溃）
        const mem_src = "let __mb = 'bad'; try { new ArrayBuffer(300*1024*1024) } catch (e) { __mb = 'ok' } globalThis.__memBoundary = __mb;";
        const mv = c.JS_Eval(act_ctx, mem_src.ptr, mem_src.len, "mem-boundary.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(mv)) {
            const ex = c.JS_GetException(act_ctx);
            c.JS_FreeValue(act_ctx, ex);
            return error.MemBoundaryProbe;
        }
        c.JS_FreeValue(act_ctx, mv);
        const mem_b = try readGlobalStr(act_ctx, "__memBoundary");
        defer std.heap.page_allocator.free(mem_b);
        std.debug.print("[m4] memBoundary='{s}'\n", .{mem_b});
        if (!std.mem.eql(u8, mem_b, "ok")) return error.MemBoundary;
        // 执行中断：无限循环 + 预算 interrupt handler → 中断异常（而非挂死）
        var budget = ItBudget{ .limit = 3, .count = 0 };
        c.JS_SetInterruptHandler(act.host.rt, jsInterruptCb, &budget);
        const loop_src = "let z = 0; while (true) { z += 1 } globalThis.__itBoundary = 'bad:finished';";
        const lv = c.JS_Eval(act_ctx, loop_src.ptr, loop_src.len, "it-boundary.js", c.JS_EVAL_TYPE_GLOBAL);
        const interrupted = c.JS_IsException(lv);
        if (interrupted) {
            const ex = c.JS_GetException(act_ctx);
            const em = c.JS_ToCStringLen(act_ctx, null, ex);
            if (em) |mm| {
                std.debug.print("[m4] itBoundary interrupted: {s}\n", .{std.mem.span(mm)});
                c.JS_FreeCString(act_ctx, mm);
            }
            c.JS_FreeValue(act_ctx, ex);
        } else {
            c.JS_FreeValue(act_ctx, lv);
        }
        c.JS_SetInterruptHandler(act.host.rt, null, null);
        if (!interrupted) return error.InterruptBoundary;
    }
    { // guest web 监听端口注入（entry.mjs 的 http.start 读取；缺省 18086）
        const g = c.JS_GetGlobalObject(act_ctx);
        defer c.JS_FreeValue(act_ctx, g);
        _ = c.JS_SetPropertyStr(act_ctx, g, "__dshWebPort", c.JS_NewInt32(act_ctx, web_port));
    }
    const ns = try act.module_host.import("bootstrap/entry.mjs", "", .{ .type = null });
    // engine-ready 口径：进程起点 → entry import 落定（cordis bootstrap + 全量模块图
    // 装载完成）。perf 门禁据此把「产品启动」与 smoke 全链路墙钟（含编排等待）分开。
    std.debug.print("boot smoke: engineReadyMs={d}\n", .{@divTrunc(monoNs() - boot_t0, 1_000_000)});
    printJsMemory(act.host.rt, "after-import");
    try std.testing.expect(@intFromPtr(ns) != 0);
    act.module_host.disposeFn(&act.module_host, ns);
    // —— invalid UTF-8 决定性探针：引擎模块系统活动后（动态 import 链已跑完）
    //    C 侧直接 JS_Eval 运行时拼接源（含中文）——若 FAIL 则引擎态复现成立。
    {
        const late_src = try std.fmt.allocPrint(std.heap.page_allocator, "var late_ok = '{s}';", .{"你好"});
        defer std.heap.page_allocator.free(late_src);
        const lv = c.JS_Eval(act_ctx, late_src.ptr, late_src.len, "late.js", c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(lv)) {
            std.debug.print("[utf8-probe] engine late JS_Eval: FAIL\n", .{});
            c.JS_FreeValue(act_ctx, lv);
        } else {
            std.debug.print("[utf8-probe] engine late JS_Eval: OK\n", .{});
            c.JS_FreeValue(act_ctx, lv);
        }
    }

    const done = try readGlobalInt(act_ctx, "__bootDone");
    const boot = try readGlobalStr(act_ctx, "__boot");
    defer std.heap.page_allocator.free(boot);
    const count = try readGlobalInt(act_ctx, "__patchLoaded");
    const skipped = try readGlobalInt(act_ctx, "__patchSkipped");
    const hash_v = try readGlobalStr(act_ctx, "__shaV");
    defer std.heap.page_allocator.free(hash_v);
    const sess_created = try readGlobalInt(act_ctx, "__sessCreated");
    const sq_api = try readGlobalInt(act_ctx, "__sqApi");
    const fts_hit = try readGlobalInt(act_ctx, "__ftsHit");
    const tool_exec = try readGlobalStr(act_ctx, "__toolExec");
    defer std.heap.page_allocator.free(tool_exec);
    const tool_read = try readGlobalInt(act_ctx, "__toolRead");
    const tool_applied = try readGlobalInt(act_ctx, "__toolFsApplied");
    const sq_tried = try readGlobalInt(act_ctx, "__sqTried");
    const sq_err = try readGlobalStr(act_ctx, "__sqErr");
    defer std.heap.page_allocator.free(sq_err);
    const mode = try readGlobalStr(act_ctx, "__bootMode");
    defer std.heap.page_allocator.free(mode);
    const js_mode = try readGlobalStr(act_ctx, "__bootJsmode");
    defer std.heap.page_allocator.free(js_mode);
    const last = try readGlobalStr(act_ctx, "__bootLast");
    const apply_count = try readGlobalInt(act_ctx, "__bootApplyCount");
    std.debug.print("boot smoke: applyCount={d}\n", .{apply_count});
    const z_mod = try readGlobalStr(act_ctx, "__zModProbe");
    defer std.heap.page_allocator.free(z_mod);
    std.debug.print("boot smoke: zModProbe='{s}'\n", .{z_mod});
    const zv1 = try readGlobalStr(act_ctx, "__zVerify1");
    defer std.heap.page_allocator.free(zv1);
    const zv2 = try readGlobalStr(act_ctx, "__zVerify2");
    defer std.heap.page_allocator.free(zv2);
    std.debug.print("boot smoke: zVerify1='{s}' zVerify2='{s}'\n", .{zv1, zv2});
    if (!std.mem.startsWith(u8, zv1, "ok:") or std.mem.indexOf(u8, zv2, "ValidationError") == null) return error.ProtocolZSchema;
    const web_start_err = try readGlobalStr(act_ctx, "__webStartErr");
    defer std.heap.page_allocator.free(web_start_err);
    if (!std.mem.eql(u8, web_start_err, "undefined") and web_start_err.len > 0) {
        std.debug.print("boot smoke: webStartErr='{s}'\n", .{web_start_err});
        return error.WebListenFailed;
    }
    const scale_ok = try readGlobalInt(act_ctx, "__scaleOk");
    const scale_ms = try readGlobalInt(act_ctx, "__scaleMs");
    const scale_err = try readGlobalStr(act_ctx, "__scaleErr");
    defer std.heap.page_allocator.free(scale_err);
    std.debug.print("boot smoke: scaleOk={d} scaleMs={d}ms scaleErr='{s}'\n", .{scale_ok, scale_ms, scale_err});
    if (scale_ok != 1) return error.ScaleSessions;
    const z_verify = try readGlobalStr(act_ctx, "__zVerify");
    defer std.heap.page_allocator.free(z_verify);
    std.debug.print("boot smoke: zVerify='{s}'\n", .{z_verify});
    const z_keys = try readGlobalStr(act_ctx, "__zKeys");
    defer std.heap.page_allocator.free(z_keys);
    const z_def = try readGlobalStr(act_ctx, "__zDefType");
    defer std.heap.page_allocator.free(z_def);
    std.debug.print("boot smoke: zKeys='{s}' zDefType='{s}'\n", .{z_keys, z_def});
    const pending_f = try readGlobalStr(act_ctx, "__pendingFibers");
    defer std.heap.page_allocator.free(pending_f);
    std.debug.print("boot smoke: pendingFibers='{s}'\n", .{pending_f});
    const apply_log = try readGlobalStr(act_ctx, "__applyLog");
    defer std.heap.page_allocator.free(apply_log);
    std.debug.print("boot smoke: applyLog='{s}'\n", .{apply_log});
    defer std.heap.page_allocator.free(last);
    {
        const g = c.JS_GetGlobalObject(act_ctx);
        defer c.JS_FreeValue(act_ctx, g);
        const sv = c.JS_GetPropertyStr(act_ctx, g, "__bootSteps");
        defer c.JS_FreeValue(act_ctx, sv);
        const ln = c.JS_GetPropertyStr(act_ctx, sv, "length");
        defer c.JS_FreeValue(act_ctx, ln);
        var n: c_int = 0;
        _ = c.JS_ToInt32(act_ctx, &n, ln);
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const s = c.JS_GetPropertyUint32(act_ctx, sv, @intCast(i));
            defer c.JS_FreeValue(act_ctx, s);
            const t = c.JS_ToCStringLen(act_ctx, null, s) orelse continue;
            defer c.JS_FreeCString(act_ctx, t);
            std.debug.print("boot step[{d}]: {s}\n", .{ i, std.mem.span(t) });
        }
    }

    std.debug.print("boot smoke: sqTried={d} hash={s} done={d} boot={s}\n", .{sq_tried, hash_v, done, boot});
    if (!std.mem.eql(u8, hash_v, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) return error.RealShaMismatch;
    if (sess_created != 1) return error.SessionStoreCreate;
    if (sq_api != 1) return error.SessionQueryApi;
    if (fts_hit != 1) return error.FtsRealQuery;
    std.debug.print("boot smoke: toolExec='{s}'\n", .{tool_exec});
    const tool_content = try readGlobalStr(act_ctx, "__toolContent");
    defer std.heap.page_allocator.free(tool_content);
    const tool_path = try readGlobalStr(act_ctx, "__toolPath");
    defer std.heap.page_allocator.free(tool_path);
    std.debug.print("boot smoke: toolPath='{s}' total={d} content='{s}'\n", .{tool_path, try readGlobalInt(act_ctx, "__toolTotal"), tool_content});
    const tool_list_at = try readGlobalStr(act_ctx, "__toolListAt");
    defer std.heap.page_allocator.free(tool_list_at);
    std.debug.print("boot smoke: toolListAt='{s}'\n", .{tool_list_at});
    if (std.mem.indexOf(u8, tool_content, "tool-exec-lexicon") == null) return error.ToolReadContentMismatch;
    if (!std.mem.endsWith(u8, tool_path, "/tmp/dsh-tool-read.txt") and !std.mem.eql(u8, tool_path, "/tmp/dsh-tool-read.txt")) return error.ToolReadPathMismatch;
    const write_out = try readGlobalStr(act_ctx, "__writeOut");
    defer std.heap.page_allocator.free(write_out);
    const write_back = try readGlobalStr(act_ctx, "__writeBack");
    defer std.heap.page_allocator.free(write_back);
    const write_err = try readGlobalStr(act_ctx, "__writeErr");
    defer std.heap.page_allocator.free(write_err);
    std.debug.print("boot smoke: writeOut='{s}' writeBack='{s}' writeErr='{s}'\n", .{write_out, write_back, write_err});
    if (std.mem.eql(u8, write_err, "") or std.mem.eql(u8, write_err, "undefined")) {
        if (!std.mem.eql(u8, write_out, "create")) return error.ToolWriteOperation;
        if (!std.mem.eql(u8, try readGlobalStr(act_ctx, "__writeOut2"), "update")) return error.ToolWriteUpdateOperation;
        if (std.mem.indexOf(u8, write_back, "write-tool-lexicon") == null) return error.ToolWriteReadback;
        if (std.mem.indexOf(u8, write_back, "updated-third") == null) return error.ToolWriteUpdateReadback;
        if (try readGlobalInt(act_ctx, "__writeTotal") != 3) return error.ToolWriteTotalLines;
    } else return error.ToolWriteFailed;
    const win_mode = try readGlobalStr(act_ctx, "__winMode");
    defer std.heap.page_allocator.free(win_mode);
    const win_err = try readGlobalStr(act_ctx, "__winErr");
    defer std.heap.page_allocator.free(win_err);
    std.debug.print("boot smoke: winMode='{s}' winTotal={d} winErr='{s}'\n", .{win_mode, try readGlobalInt(act_ctx, "__winTotal"), win_err});
    const win_stream = try readGlobalStr(act_ctx, "__winStream");
    defer std.heap.page_allocator.free(win_stream);
    const win_read = try readGlobalStr(act_ctx, "__winRead");
    defer std.heap.page_allocator.free(win_read);
    std.debug.print("boot smoke: winStream='{s}' winRead='{s}'\n", .{win_stream, win_read});
    const win_d = try readGlobalStr(act_ctx, "__winD");
    defer std.heap.page_allocator.free(win_d);
    std.debug.print("boot smoke: winD='{s}'\n", .{win_d});
    const win_d2 = try readGlobalStr(act_ctx, "__winD2");
    defer std.heap.page_allocator.free(win_d2);
    std.debug.print("boot smoke: winD2='{s}'\n", .{win_d2});
    const td_err = try readGlobalStr(act_ctx, "__tdErr");
    defer std.heap.page_allocator.free(td_err);
    std.debug.print("boot smoke: tdErr='{s}'\n", .{td_err});
    if (std.mem.indexOf(u8, win_stream, "hit") == null) return error.StreamTextPathMiss;
    if (std.mem.indexOf(u8, win_read, "hit") == null) return error.ReadTextPathMiss;
    if (!std.mem.eql(u8, win_d, "d1ok:d2ok:")) return error.DecodeArgsMismatch;
    if (!std.mem.startsWith(u8, win_d2, "ok|")) return error.StreamReplicaMismatch;
    if (!std.mem.eql(u8, td_err, "undefined")) return error.DecodeFlush; 
    const edit_back = try readGlobalStr(act_ctx, "__editBack");
    defer std.heap.page_allocator.free(edit_back);
    const edit_after = try readGlobalStr(act_ctx, "__editAfter");
    defer std.heap.page_allocator.free(edit_after);
    const edit_err = try readGlobalStr(act_ctx, "__editErr");
    defer std.heap.page_allocator.free(edit_err);
    std.debug.print("boot smoke: editAfter='{s}' editBack='{s}' editErr='{s}'\n", .{edit_after, edit_back, edit_err});
    if (!std.mem.eql(u8, edit_err, "undefined") and !std.mem.eql(u8, edit_err, "")) return error.ToolEditFailed;
    if (std.mem.indexOf(u8, edit_back, "edited-line") == null) return error.ToolEditNoApply;
    if (std.mem.indexOf(u8, edit_back, "second-line") != null) return error.ToolEditOldRemains;
    if (std.mem.indexOf(u8, edit_after, "\"after\":\"write-tool-lexicon\\nedited-line\\nupdated-third\"") == null) return error.ToolEditAfterMismatch;
    if (std.mem.indexOf(u8, edit_after, "\"before\":\"write-tool-lexicon\\nsecond-line\\nupdated-third\"") == null) return error.ToolEditBeforeMismatch;
    const read_bytes = try readGlobalStr(act_ctx, "__readBytes");
    defer std.heap.page_allocator.free(read_bytes);
    std.debug.print("boot smoke: readBytes='{s}'\n", .{read_bytes});
    if (std.mem.indexOf(u8, read_bytes, "hit") == null) return error.ReadBytesMiss;
    const img_out = try readGlobalStr(act_ctx, "__imgOut");
    defer std.heap.page_allocator.free(img_out);
    const img_err = try readGlobalStr(act_ctx, "__imgErr");
    defer std.heap.page_allocator.free(img_err);
    std.debug.print("boot smoke: imgOut='{s}' imgErr='{s}'\n", .{img_out, img_err});
    if ((!std.mem.eql(u8, img_err, "")) and (!std.mem.eql(u8, img_err, "undefined"))) return error.ReadImageFailed;
    if (!std.mem.eql(u8, img_out, "boot:image/png:70:70:image/png")) return error.ReadImageOutcome;
    const tool_list = try readGlobalStr(act_ctx, "__toolList");
    defer std.heap.page_allocator.free(tool_list);
    std.debug.print("boot smoke: toolList='{s}'\n", .{tool_list});
    if (std.mem.indexOf(u8, tool_list, "read") == null) return error.ToolListMissingRead;
    if (std.mem.indexOf(u8, tool_list, "write") == null) return error.ToolListMissingWrite;
    if (std.mem.indexOf(u8, tool_list, "edit") == null) return error.ToolListMissingEdit;
    if (std.mem.indexOf(u8, tool_list, "read_image") == null) return error.ToolListMissingImage;
    const svc_list = try readGlobalStr(act_ctx, "__svcList");
    defer std.heap.page_allocator.free(svc_list);
    std.debug.print("boot smoke: svcList='{s}'\n", .{svc_list});
    if (std.mem.indexOf(u8, svc_list, "fs") == null) return error.SvcListMissingFs;
    if (std.mem.indexOf(u8, svc_list, "sqlite") == null) return error.SvcListMissingSqlite;
    if (std.mem.indexOf(u8, svc_list, "crypto") == null) return error.SvcListMissingCrypto;
    if (std.mem.indexOf(u8, svc_list, "proc") == null) return error.SvcListMissingProc;
    if (std.mem.indexOf(u8, svc_list, "http") == null) return error.SvcListMissingHttp;
    if (std.mem.indexOf(u8, svc_list, "timer") == null) return error.SvcListMissingTimer;
    const fs_stat = try readGlobalStr(act_ctx, "__fsStat");
    defer std.heap.page_allocator.free(fs_stat);
    const fs_url = try readGlobalStr(act_ctx, "__fsUrl");
    defer std.heap.page_allocator.free(fs_url);
    const fs_proc = try readGlobalStr(act_ctx, "__fsProc");
    defer std.heap.page_allocator.free(fs_proc);
    std.debug.print("boot smoke: fsStat='{s}' fsUrl='{s}' fsProc='{s}'\n", .{fs_stat, fs_url, fs_proc});
    if (!std.mem.eql(u8, fs_stat, "ok")) return error.FsServiceStat;
    if (std.mem.indexOf(u8, fs_url, "file:///tmp/dsh-tool-read.txt") == null) return error.FsServiceFileUrl;
    if (!std.mem.eql(u8, fs_proc, "/tmp/dsh-tool-read.txt:true")) return error.FsServiceProcessPath;
    const uf_js = try readGlobalStr(act_ctx, "__ufJs");
    defer std.heap.page_allocator.free(uf_js);
    std.debug.print("boot smoke: ufJs='{s}'\n", .{uf_js});
    if (!std.mem.eql(u8, uf_js, "ok")) return error.Utf8LateFunction;
    const fork_ok = try readGlobalInt(act_ctx, "__forkOk");
    const fork_list = try readGlobalStr(act_ctx, "__forkList");
    defer std.heap.page_allocator.free(fork_list);
    const flush_ok = try readGlobalStr(act_ctx, "__flushOk");
    defer std.heap.page_allocator.free(flush_ok);
    const sess_err2 = try readGlobalStr(act_ctx, "__sessErr2");
    defer std.heap.page_allocator.free(sess_err2);
    std.debug.print("boot smoke: forkOk={d} forkList='{s}' flushOk='{s}' sessErr2='{s}'\n", .{fork_ok, fork_list, flush_ok, sess_err2});
    const fork_step = try readGlobalStr(act_ctx, "__forkStep");
    defer std.heap.page_allocator.free(fork_step);
    std.debug.print("boot smoke: forkStep='{s}'\n", .{fork_step});
    const gw_run = try readGlobalInt(act_ctx, "__gwRun");
    std.debug.print("boot smoke: gwRun={d}\n", .{gw_run});
    if (!std.mem.eql(u8, sess_err2, "undefined") and !std.mem.eql(u8, sess_err2, "")) return error.SessionForkFailed;
    if (fork_ok != 1) return error.SessionForkNotLinked;
    if (!std.mem.eql(u8, fork_list, "ok")) return error.SessionListCount;
    if (!std.mem.eql(u8, flush_ok, "ok")) return error.SessionFlush;
    const agent_ok = try readGlobalInt(act_ctx, "__agentOk");
    const agent_err = try readGlobalStr(act_ctx, "__agentErr");
    defer std.heap.page_allocator.free(agent_err);
    std.debug.print("boot smoke: agentOk={d} agentErr='{s}'\n", .{agent_ok, agent_err});
    if (agent_ok != 1) return error.AgentFactoryChain;
    const agent_ok2 = try readGlobalInt(act_ctx, "__agentOk2");
    const agent_gone = try readGlobalInt(act_ctx, "__agentGone");
    const disp_count = try readGlobalInt(act_ctx, "__dispCount");
    const create_count = try readGlobalInt(act_ctx, "__createCount");
    const agent_err2 = try readGlobalStr(act_ctx, "__agentErr2");
    defer std.heap.page_allocator.free(agent_err2);
    std.debug.print("boot smoke: agentOk2={d} agentGone={d} created={d} disposed={d} agentErr2='{s}'\n", .{agent_ok2, agent_gone, create_count, disp_count, agent_err2});
    if (agent_ok2 != 1) return error.AgentDisposeCreate;
    if (agent_gone != 1) return error.AgentDisposeGone;
    if (disp_count < 1) return error.AgentDisposedEvent;
    const msg_ok = try readGlobalInt(act_ctx, "__msgOk");
    const msg_uuid = try readGlobalStr(act_ctx, "__msgUuid");
    defer std.heap.page_allocator.free(msg_uuid);
    const msg_err = try readGlobalStr(act_ctx, "__msgErr");
    defer std.heap.page_allocator.free(msg_err);
    std.debug.print("boot smoke: msgOk={d} msgUuid='{s}' msgErr='{s}'\n", .{msg_ok, msg_uuid, msg_err});
    if (msg_ok != 1) return error.LlmMessageFlow;
    if (msg_uuid.len != 36 or msg_uuid[14] != '4') return error.LlmMessageUuid;
    const hdr_ok = try readGlobalInt(act_ctx, "__hdrOk");
    const hdr_seq = try readGlobalInt(act_ctx, "__hdrSeq");
    const ev_obs = try readGlobalInt(act_ctx, "__evObs");
    const hdr_err = try readGlobalStr(act_ctx, "__hdrErr");
    defer std.heap.page_allocator.free(hdr_err);
    std.debug.print("boot smoke: hdrOk={d} hdrSeq={d} evObs={d} hdrErr='{s}'\n", .{hdr_ok, hdr_seq, ev_obs, hdr_err});
    if (hdr_ok != 1) return error.SessionHeaderFold;
    if (hdr_seq != 1) return error.SessionLogAppend;
    const sq_read = try readGlobalInt(act_ctx, "__sqRead");
    const sq_evt = try readGlobalInt(act_ctx, "__sqEvtCount");
    const sq_title = try readGlobalStr(act_ctx, "__sqTitle");
    defer std.heap.page_allocator.free(sq_title);
    const sq_err3 = try readGlobalStr(act_ctx, "__sqErr3");
    defer std.heap.page_allocator.free(sq_err3);
    std.debug.print("boot smoke: sqRead={d} sqEvtCount={d} sqTitle='{s}' sqErr3='{s}'\n", .{sq_read, sq_evt, sq_title, sq_err3});
    if (sq_read != 1) return error.SessionQueryRead;
    if (sq_evt < 2) return error.SessionQueryEvents;
    const fs_ok = try readGlobalInt(act_ctx, "__fsOk");
    const fe_ok = try readGlobalInt(act_ctx, "__feOk");
    const title_ok = try readGlobalStr(act_ctx, "__titleOk");
    defer std.heap.page_allocator.free(title_ok);
    const ft_err = try readGlobalStr(act_ctx, "__ftErr");
    defer std.heap.page_allocator.free(ft_err);
    std.debug.print("boot smoke: fsOk={d} feOk={d} titleOk='{s}' ftErr='{s}'\n", .{fs_ok, fe_ok, title_ok, ft_err});
    const ts_id = try readGlobalStr(act_ctx, "__tsId");
    defer std.heap.page_allocator.free(ts_id);
    const ts_ev_len = try readGlobalStr(act_ctx, "__tsEvLen");
    defer std.heap.page_allocator.free(ts_ev_len);
    std.debug.print("boot smoke: tsId='{s}' tsEvLen='{s}'\n", .{ts_id, ts_ev_len});
    const ts2b = try readGlobalStr(act_ctx, "__ts2b");
    defer std.heap.page_allocator.free(ts2b);
    std.debug.print("boot smoke: ts2b='{s}'\n", .{ts2b});
    const fs_shape = try readGlobalStr(act_ctx, "__fsShape");
    defer std.heap.page_allocator.free(fs_shape);
    const fe_shape = try readGlobalStr(act_ctx, "__feShape");
    defer std.heap.page_allocator.free(fe_shape);
    const title_last = try readGlobalStr(act_ctx, "__titleLast");
    defer std.heap.page_allocator.free(title_last);
    const title_ev = try readGlobalStr(act_ctx, "__titleEv");
    defer std.heap.page_allocator.free(title_ev);
    std.debug.print("boot smoke: fsShape='{s}'\nfeShape='{s}'\ntitleLast='{s}' titleEv='{s}'\n", .{fs_shape, fe_shape, title_last, title_ev});
    const find_last = try readGlobalStr(act_ctx, "__findLast");
    defer std.heap.page_allocator.free(find_last);
    std.debug.print("boot smoke: findLast='{s}'\n", .{find_last});
    const fold_probe = try readGlobalStr(act_ctx, "__foldProbe");
    defer std.heap.page_allocator.free(fold_probe);
    std.debug.print("boot smoke: foldProbe='{s}'\n", .{fold_probe});
    const scrub = try readGlobalStr(act_ctx, "__scrub");
    defer std.heap.page_allocator.free(scrub);
    std.debug.print("boot smoke: scrub='{s}'\n", .{scrub});
    if (!std.mem.eql(u8, scrub, "ok")) return error.SubprocessScrub;
    if (std.mem.indexOf(u8, fold_probe, "fold:boot-child-title") == null) return error.SessionTitleFold;
    if (!std.mem.eql(u8, ts2b, "hit2")) return error.SessionTitleWarm;
    const os_home = try readGlobalStr(act_ctx, "__osHome");
    defer std.heap.page_allocator.free(os_home);
    const os_tmp = try readGlobalStr(act_ctx, "__osTmp");
    defer std.heap.page_allocator.free(os_tmp);
    const hp_default = try readGlobalStr(act_ctx, "__hpDefault");
    defer std.heap.page_allocator.free(hp_default);
    const hp_resolved = try readGlobalStr(act_ctx, "__hpResolved");
    defer std.heap.page_allocator.free(hp_resolved);
    const hp_err = try readGlobalStr(act_ctx, "__hpErr");
    defer std.heap.page_allocator.free(hp_err);
    std.debug.print("boot smoke: osHome='{s}' osTmp='{s}' hpDefault='{s}' hpResolved='{s}' hpErr='{s}'\n", .{os_home, os_tmp, hp_default, hp_resolved, hp_err});
    if (os_home.len == 0 or os_home[0] != '/') return error.OsHomeSemantics;
    if (os_tmp.len == 0 or os_tmp[0] != '/') return error.OsTmpSemantics;
    if (std.mem.indexOf(u8, hp_default, ".dsh") == null) return error.HomePathsDefault;
    const esc_ok = try readGlobalInt(act_ctx, "__escOk");
    const esc_a = try readGlobalStr(act_ctx, "__escA");
    defer std.heap.page_allocator.free(esc_a);
    const esc_b = try readGlobalStr(act_ctx, "__escB");
    defer std.heap.page_allocator.free(esc_b);
    const esc_c = try readGlobalStr(act_ctx, "__escC");
    defer std.heap.page_allocator.free(esc_c);
    const esc_write = try readGlobalStr(act_ctx, "__escWrite");
    defer std.heap.page_allocator.free(esc_write);
    std.debug.print("boot smoke: escOk={d} escA='{s}' escB='{s}' escC='{s}' escWrite='{s}'\n", .{esc_ok, esc_a, esc_b, esc_c, esc_write});
    if (esc_ok != 1) return error.EscalationValidate;
    if (!std.mem.eql(u8, esc_a, "throw") or !std.mem.eql(u8, esc_b, "throw") or !std.mem.eql(u8, esc_c, "throw")) return error.EscalationRejections;
    if (std.mem.indexOf(u8, esc_write, "not strictly wider") == null) return error.EscalationFailClosed;
    const scope_carrier = try readGlobalInt(act_ctx, "__scopeCarrier");
    const scope_f = try readGlobalStr(act_ctx, "__scopeF");
    defer std.heap.page_allocator.free(scope_f);
    const scope_res = try readGlobalStr(act_ctx, "__scopeRes");
    defer std.heap.page_allocator.free(scope_res);
    const scope_err = try readGlobalStr(act_ctx, "__scopeErr");
    defer std.heap.page_allocator.free(scope_err);
    std.debug.print("boot smoke: scopeCarrier={d} scopeF='{s}' scopeRes='{s}' scopeErr='{s}'\n", .{scope_carrier, scope_f, scope_res, scope_err});
    if (scope_carrier != 1 or !std.mem.eql(u8, scope_f, "fn") or !std.mem.eql(u8, scope_res, "true")) return error.ScopeTargetSemantics;
    const proc_run = try readGlobalStr(act_ctx, "__procRun");
    defer std.heap.page_allocator.free(proc_run);
    std.debug.print("boot smoke: procRun='{s}'\n", .{proc_run});
    if (!std.mem.eql(u8, proc_run, "ok")) return error.ProcRunnerEcho;
    const ll_deny = try readGlobalInt(act_ctx, "__llDeny");
    const ll_ok = try readGlobalInt(act_ctx, "__llOk");
    std.debug.print("boot smoke: llDeny={d} llOk={d}\n", .{ll_deny, ll_ok});
    if (ll_deny == 0) return error.ProcLandlockDeny;
    if (ll_ok != 0) return error.ProcLandlockOk;
    const deep_js = try readGlobalStr(act_ctx, "__deepJs");
    defer std.heap.page_allocator.free(deep_js);
    const js_p1 = try readGlobalStr(act_ctx, "__jsPhase1");
    defer std.heap.page_allocator.free(js_p1);
    const js_p2 = try readGlobalStr(act_ctx, "__jsPhase2");
    defer std.heap.page_allocator.free(js_p2);
    const js_err = try readGlobalStr(act_ctx, "__jsErr");
    defer std.heap.page_allocator.free(js_err);
    std.debug.print("boot smoke: jsP1='{s}' jsP2='{s}' jsErr='{s}'\n", .{js_p1, js_p2, js_err});
    if (!std.mem.eql(u8, js_p1, "ok") or !std.mem.eql(u8, js_p2, "danger-full-access")) return error.DshTwoStageJs;
    const bundle_hit = try readGlobalStr(act_ctx, "__bundleHit");
    defer std.heap.page_allocator.free(bundle_hit);
    const bundle_rows = try readGlobalInt(act_ctx, "__bundleRows");
    std.debug.print("boot smoke: bundleRows={d} bundleHit='{s}'\n", .{bundle_rows, bundle_hit});
    const gw_prof = if (core_mode) "ok:core" else try readGlobalStr(act_ctx, "__profileMatrix");
    defer std.heap.page_allocator.free(gw_prof);
    std.debug.print("boot smoke: profileMatrix='{s}'\n", .{gw_prof});
    if (!std.mem.startsWith(u8, gw_prof, "ok:")) return error.ProfileMatrix;
    const bundle_cover = try readGlobalInt(act_ctx, "__bundleCover");
    std.debug.print("boot smoke: bundleCover={d}\n", .{bundle_cover});
    if (bundle_cover < 50) return error.BundleCover;
    const bundle_ids = try readGlobalStr(act_ctx, "__bundleIds");
    defer std.heap.page_allocator.free(bundle_ids);
    std.debug.print("boot smoke: bundleIds='{s}'\n", .{bundle_ids});
    if (bundle_rows < 50 or !std.mem.eql(u8, bundle_hit, "ok")) return error.BundleRows;
    std.debug.print("boot smoke: deepJs='{s}'\n", .{deep_js});
    if (std.mem.indexOf(u8, deep_js, "\"b\":2") == null or std.mem.indexOf(u8, deep_js, "\"c\":[4") == null) return error.DeepJsExpr;
    const yml_doc = try readGlobalInt(act_ctx, "__ymlDoc");
    const yml_ins = try readGlobalInt(act_ctx, "__ymlInserts");
    const yml_first = try readGlobalStr(act_ctx, "__ymlFirst");
    defer std.heap.page_allocator.free(yml_first);
    const yml_ck = try readGlobalInt(act_ctx, "__ymlCk");
    const yml_err = try readGlobalStr(act_ctx, "__ymlErr");
    defer std.heap.page_allocator.free(yml_err);
    std.debug.print("boot smoke: ymlDoc={d} inserts={d} first='{s}' fsSandboxCfg={d} ymlErr='{s}'\n", .{yml_doc, yml_ins, yml_first, yml_ck, yml_err});
    // yml 面：文件读取+js-yaml 链工作即过（!!js 标签『unknown tag』= schema 边界
    // （entryListSchema 需 cordis-plugin-include —— M-6 后半引入评估；深层 !!js 展开已交正题））
    if (std.mem.indexOf(u8, yml_err, "unknown tag") == null and yml_doc < 1) return error.ProfileYaml;
    const to_clamp = try readGlobalStr(act_ctx, "__toClamp");
    defer std.heap.page_allocator.free(to_clamp);
    std.debug.print("[loop] timer0 used={} id={}\n", .{ loop.timers[0].used, loop.timers[0].id });
    {
        const g = c.JS_GetGlobalObject(act_ctx);
        defer c.JS_FreeValue(act_ctx, g);
        const svc = c.JS_GetPropertyStr(act_ctx, g, "dshServices");
        defer c.JS_FreeValue(act_ctx, svc);
        const tmr = c.JS_GetPropertyStr(act_ctx, svc, "timer");
        defer c.JS_FreeValue(act_ctx, tmr);
        const tp = c.JS_GetPropertyStr(act_ctx, tmr, "setTimeout");
        defer c.JS_FreeValue(act_ctx, tp);
        std.debug.print("[host] timerIsFn={} tag={d}\n", .{c.JS_IsFunction(act_ctx, tp), tp.tag});
    }
    loop.run(80); // 驱动宿主导出 timer（guest setTimeout 的 50ms）
    const st_hit = try readGlobalInt(act_ctx, "__stHit");
    const to_err = try readGlobalStr(act_ctx, "__toErr");
    defer std.heap.page_allocator.free(to_err);
    const st_type = try readGlobalStr(act_ctx, "__stType");
    defer std.heap.page_allocator.free(st_type);
    std.debug.print("boot smoke: toClamp='{s}' stHit={d} toErr='{s}' stType='{s}'\n", .{to_clamp, st_hit, to_err, st_type});
    const timer_keys = try readGlobalStr(act_ctx, "__timerKeys");
    defer std.heap.page_allocator.free(timer_keys);
    std.debug.print("boot smoke: timerKeys='{s}'\n", .{timer_keys});
    if (!std.mem.eql(u8, to_clamp, "ok")) return error.TimeoutClamp;
    if (st_hit != 1) return error.GuestSetTimeout;
    const fs_mode = try readGlobalStr(act_ctx, "__fsMode");
    defer std.heap.page_allocator.free(fs_mode);
    std.debug.print("boot smoke: fsMode='{s}'\n", .{fs_mode});
    if (!std.mem.eql(u8, fs_mode, "workspace-write")) return error.SandboxModeFact;
    const deny_write = try readGlobalStr(act_ctx, "__denyWrite");
    defer std.heap.page_allocator.free(deny_write);
    std.debug.print("boot smoke: denyWrite='{s}'\n", .{deny_write});
    const pol_probe = try readGlobalStr(act_ctx, "__polProbe");
    defer std.heap.page_allocator.free(pol_probe);
    std.debug.print("boot smoke: polProbe='{s}'\n", .{pol_probe});
    const deny_direct = try readGlobalStr(act_ctx, "__denyDirect");
    defer std.heap.page_allocator.free(deny_direct);
    std.debug.print("boot smoke: denyDirect='{s}'\n", .{deny_direct});
    const wrr = try readGlobalStr(act_ctx, "__wrr");
    defer std.heap.page_allocator.free(wrr);
    const tgt = try readGlobalStr(act_ctx, "__tgt");
    defer std.heap.page_allocator.free(tgt);
    std.debug.print("boot smoke: writableRoots='{s}' target='{s}'\n", .{wrr, tgt});
    const mode1 = try readGlobalStr(act_ctx, "__mode1");
    defer std.heap.page_allocator.free(mode1);
    const mode2 = try readGlobalStr(act_ctx, "__mode2");
    defer std.heap.page_allocator.free(mode2);
    std.debug.print("boot smoke: mode1='{s}' mode2='{s}'\n", .{mode1, mode2});
    {
        const fo = try fs_svc.stat("/tmp/dsh-mode.txt");
        const fi = fo orelse return error.ModeStat;
        std.debug.print("[host-stat] mode={d} inode={d} size={d}\n", .{ fi.mode, fi.inode, fi.size });
    }
    const esc_full = try readGlobalStr(act_ctx, "__escFull");
    defer std.heap.page_allocator.free(esc_full);
    std.debug.print("boot smoke: escFull='{s}'\n", .{esc_full});
    if (std.mem.indexOf(u8, esc_full, "ok:") == null) return error.EscalationGranted;
    const ro_mode = try readGlobalStr(act_ctx, "__roMode");
    defer std.heap.page_allocator.free(ro_mode);
    const ro_write = try readGlobalStr(act_ctx, "__roWrite");
    defer std.heap.page_allocator.free(ro_write);
    std.debug.print("boot smoke: roMode='{s}' roWrite='{s}'\n", .{ro_mode, ro_write});
    if (!std.mem.eql(u8, ro_mode, "read-only")) return error.ReadOnlyOverride;
    if (std.mem.indexOf(u8, ro_write, "read-only") == null) return error.ReadOnlyDeny;
    if (std.mem.eql(u8, mode1, "0") or mode1.len == 0) return error.ModeWrite;
    if (!std.mem.eql(u8, mode2, "493")) return error.ModeChmod;
    if (std.mem.indexOf(u8, deny_write, "FS_SANDBOX_DENIED") == null and std.mem.indexOf(u8, deny_write, "denied") == null) return error.SandboxDenyFence;
    if (fs_ok != 1) return error.SessionFilterSessions;
    const img_render = try readGlobalStr(act_ctx, "__imgRender");
    defer std.heap.page_allocator.free(img_render);
    std.debug.print("boot smoke: imgRender='{s}'\n", .{img_render});
    if (!std.mem.startsWith(u8, img_render, "2:text:image:render-x")) return error.ImageRenderSurface;
    const sub_digest = try readGlobalStr(act_ctx, "__subDigest");
    defer std.heap.page_allocator.free(sub_digest);
    const perf = try readGlobalStr(act_ctx, "__perf");
    defer std.heap.page_allocator.free(perf);
    const uuid = try readGlobalStr(act_ctx, "__uuid");
    defer std.heap.page_allocator.free(uuid);
    std.debug.print("boot smoke: subDigest='{s}' perf='{s}' uuid='{s}'\n", .{sub_digest, perf, uuid});
    if (!std.mem.eql(u8, sub_digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) return error.SubtleDigestMismatch;
    if (!std.mem.startsWith(u8, perf, "ok:")) return error.PerfNowMismatch;
    if (uuid.len != 36 or uuid[14] != '4') return error.CryptoUuidMismatch;
    if (!std.mem.eql(u8, win_err, "") and !std.mem.eql(u8, win_err, "undefined")) return error.WindowWriteFailed;
    if (!std.mem.eql(u8, win_mode, "ok")) return error.WindowOffsetMismatch;
    if (try readGlobalInt(act_ctx, "__winTotal") != 4) return error.WindowTotalLines;
    const probe_read = try readGlobalStr(act_ctx, "__probeRead");
    defer std.heap.page_allocator.free(probe_read);
    if (!std.mem.startsWith(u8, probe_read, "object:[object Uint8Array]:function")) return error.ReadFileBufferShape;
    std.debug.print("boot smoke: probeRead='{s}'\n", .{probe_read});

    // —— M-7 spawn 基元：echo 往返（fork+setsid+管道+execvp+waitpid）
    {
        const pw = @cImport({ @cInclude("proc_wrap.h"); });
        const argv = [_]?[*:0]const u8{ "sh", "-c", "echo first; sleep 0.2; echo second", null };
        var stdin_fd: c_int = 0;
        var stdout_fd: c_int = 0;
        var stderr_fd: c_int = 0;
        var pid: c_int = 0;
        if (pw.dsh_proc_spawn(@ptrCast(&argv), null, &stdin_fd, &stdout_fd, &stderr_fd, &pid, "", 2) != 0) return error.SpawnPrim;
        defer _ = std.os.linux.close(@intCast(stdin_fd));
        defer _ = std.os.linux.close(@intCast(stdout_fd));
        defer _ = std.os.linux.close(@intCast(stderr_fd));
        _ = std.c.fcntl(stdout_fd, @as(c_int, 4), @as(c_int, 0x800)); // F_SETFL, O_NONBLOCK
        var sbuf: [128]u8 = undefined;
        var used: usize = 0;
        while (used < sbuf.len) {
            const n = std.c.read(stdout_fd, sbuf[used..].ptr, sbuf.len - used);
            if (n > 0) {
                used += @intCast(n);
            } else if (n < 0 and std.c._errno().* == 11) {
                // 事件化等待：等 fd 可读或超时 350ms（总等待覆盖第二块输出）
                var pfd = [_]std.os.linux.pollfd{.{ .fd = stdout_fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
                _ = std.os.linux.poll(&pfd, 1, 350);
            } else break;
        }
        var status: u32 = 0;
        _ = std.os.linux.waitpid(pid, &status, 0);
        std.debug.print("[spawn] pid={d} used={d} out='{s}'\n", .{ pid, used, sbuf[0..@min(used, sbuf.len)] });
        if (std.mem.indexOf(u8, sbuf[0..used], "first") == null) return error.SpawnEcho;
        if (std.mem.indexOf(u8, sbuf[0..used], "second") == null) return error.SpawnStream;
        if (!std.os.linux.W.IFEXITED(status) or std.os.linux.W.EXITSTATUS(status) != 0) return error.SpawnExit;
    }
    // —— M-7 终止升级链：TERM（进程组）→ KILL（SIGKILL 不可忽略）+ done 轮询
    {
        const pw = @cImport({ @cInclude("proc_wrap.h"); });
        // 忽略 TERM 的子进程（trap '' TERM——SIG_IGN 继承给 sleep）；
        // echo ready 作为就绪握手：trap 安装先于输出，读到 ready 才允许发 TERM
        // （此前盲发——子进程尚在 fork/exec/trap 设置窗口时 TERM 走默认动作被杀死，
        // strace/高负载下窗口放大，造成 ProcTermShouldNotExit 瞬态 flake）
        const argv = [_]?[*:0]const u8{ "sh", "-c", "trap '' TERM; echo ready; sleep 5", null };
        var stdin_fd: c_int = 0;
        var stdout_fd: c_int = 0;
        var stderr_fd: c_int = 0;
        var pid: c_int = 0;
        if (pw.dsh_proc_spawn(@ptrCast(&argv), null, &stdin_fd, &stdout_fd, &stderr_fd, &pid, "", 2) != 0) return error.SpawnPrim2;
        defer {
            _ = std.os.linux.close(@intCast(stdin_fd));
            _ = std.os.linux.close(@intCast(stdout_fd));
            _ = std.os.linux.close(@intCast(stderr_fd));
        }
        // 就绪握手：读到子进程 stdout 的 ready（trap 已安装）再进入终止链
        {
            _ = std.c.fcntl(stdout_fd, @as(c_int, 4), @as(c_int, 0x800)); // F_SETFL, O_NONBLOCK
            var rbuf: [64]u8 = undefined;
            var rused: usize = 0;
            var rtick: i32 = 0;
            var ready = false;
            while (rtick < 200) : (rtick += 1) { // 2s 上限
                const n = std.c.read(stdout_fd, rbuf[rused..].ptr, rbuf.len - rused);
                if (n > 0) rused += @intCast(n);
                if (std.mem.indexOf(u8, rbuf[0..rused], "ready") != null) {
                    ready = true;
                    break;
                }
                var pfd = [_]std.os.linux.pollfd{.{ .fd = stdout_fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
                _ = std.os.linux.poll(&pfd, 1, 10);
            }
            if (!ready) return error.ProcReadyTimeout;
        }
        var raw: c_int = 0;
        if (pw.dsh_proc_wait(pid, &raw) != 0) return error.ProcWaitAlive; // 应立即运行中
        // 第一级：TERM（应被忽略——进程组 kill 到 trap 的 sh 与继承 SIG_IGN 的 sleep）
        pw.dsh_proc_terminate(pid);
        var exited: bool = false;
        var tick: i32 = 0;
        while (tick < 50) : (tick += 1) { // 500ms 宽限
            var pfd = [_]std.os.linux.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = std.os.linux.poll(&pfd, 1, 10);
            if (pw.dsh_proc_wait(pid, &raw) == 1) {
                exited = true;
                break;
            }
        }
        if (exited) return error.ProcTermShouldNotExit; // TERM 被忽略 → 不应退
        // 第二级：SIGKILL（不可忽略——升级链末级）
        pw.dsh_proc_kill(pid);
        exited = false;
        tick = 0;
        while (tick < 200) : (tick += 1) { // 2s 上限
            var pfd = [_]std.os.linux.pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
            _ = std.os.linux.poll(&pfd, 1, 10);
            if (pw.dsh_proc_wait(pid, &raw) == 1) {
                exited = true;
                break;
            }
        }
        if (!exited) return error.ProcKillTimeout;
        // 原生 status：低 7 位 = 终止信号（Linux waitpid 编码）；SIGKILL=9
        const termsig: u32 = @as(u32, @bitCast(raw)) & 0x7f;
        if (termsig != 9) return error.ProcKillSig;
        std.debug.print("[spawn-kill] pid={d} raw=0x{x} termsig={d}\n", .{ pid, raw, termsig });
    }
    // —— M-7 envp 面：替换环境 spawn（scrubbed env 一致性验证）
    {
        const pw = @cImport({ @cInclude("proc_wrap.h"); });
        const ea = [_]?[*:0]const u8{ "sh", "-c", "env | sort", null };
        const envs = [_]?[*:0]const u8{ "HOME=/root", "TMPDIR=/tmp", null };
        var stdin_fd: c_int = 0;
        var stdout_fd: c_int = 0;
        var stderr_fd: c_int = 0;
        var pid: c_int = 0;
        if (pw.dsh_proc_spawn(@ptrCast(&ea), @ptrCast(&envs), &stdin_fd, &stdout_fd, &stderr_fd, &pid, "", 2) != 0) return error.SpawnPrim3;
        defer {
            _ = std.os.linux.close(@intCast(stdin_fd));
            _ = std.os.linux.close(@intCast(stdout_fd));
            _ = std.os.linux.close(@intCast(stderr_fd));
        }
        _ = std.c.fcntl(stdout_fd, @as(c_int, 4), @as(c_int, 0x800));
        var sbuf: [256]u8 = undefined;
        var sused: usize = 0;
        var swaited: i32 = 0;
        while (swaited < 30) : (swaited += 1) {
            var pfd = [_]std.os.linux.pollfd{.{ .fd = stdout_fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
            _ = std.os.linux.poll(&pfd, 1, 20);
            const n = std.c.read(stdout_fd, sbuf[sused..].ptr, sbuf.len - sused);
            if (n > 0) {
                sused += @intCast(n);
            } else if (n == 0) break;
        }
        var rstatus: u32 = 0;
        _ = std.os.linux.waitpid(pid, &rstatus, 0);
        std.debug.print("[spawn-env] out='{s}' status={d}\n", .{sbuf[0..sused], rstatus});
        if (std.mem.indexOf(u8, sbuf[0..sused], "HOME=/root") == null) return error.SpawnEnvReplace;
        if ((rstatus & 0x7f) != 0) return error.SpawnEnvExit;
    }
    // —— M-7 guest 子进程流验证：spawn→定时器泵读（流事件化）→done（entry.mjs 链；宿主导流）
    {
        var subproc_done: bool = false;
        var rt_done: bool = false;
        var env_done: bool = false;
        var shl_done: bool = false;
        var btl_done: bool = false;
        var waited: i32 = 0;
        while (waited < 120) : (waited += 1) { // ≤3s（≈900ms 双进程预期）
            loop.run(25);
            const sp = readGlobalStr(act_ctx, "__subproc") catch continue;
            if (!std.mem.eql(u8, sp, "pending") and sp.len > 0) {
                subproc_done = true;
                std.debug.print("[subproc] {s}\n", .{sp});
                if (!std.mem.startsWith(u8, sp, "ok:")) return error.SubprocGuest;
            }
            const rt_s = readGlobalStr(act_ctx, "__subprocRT") catch continue;
            if (!std.mem.eql(u8, rt_s, "pending") and rt_s.len > 0) {
                rt_done = true;
                std.debug.print("[subproc-rt] {s}\n", .{rt_s});
                if (!std.mem.startsWith(u8, rt_s, "ok:")) return error.SubprocRT;
            }
            const ev = readGlobalStr(act_ctx, "__subprocEnv") catch continue;
            if (!std.mem.eql(u8, ev, "pending") and ev.len > 0) {
                env_done = true;
                std.debug.print("[subproc-env] {s}\n", .{ev});
                if (!std.mem.eql(u8, ev, "ok") and !std.mem.startsWith(u8, ev, "ok:")) return error.SubprocEnv;
            }
            const shl = readGlobalStr(act_ctx, "__shellRun") catch continue;
            if (!std.mem.eql(u8, shl, "pending") and shl.len > 0) {
                shl_done = true;
                std.debug.print("[shell] {s}\n", .{shl});
                if (!std.mem.startsWith(u8, shl, "ok:")) return error.ShellRun;
                const sdbg = readGlobalStr(act_ctx, "__shDbg") catch "";
                if (sdbg.len > 0) std.debug.print("[shell-dbg] {s}\n", .{sdbg});
            }
            if (waited == 2) {
                const sdbg = readGlobalStr(act_ctx, "__shDbg") catch "";
                if (sdbg.len > 0) std.debug.print("[shell-dbg] {s}\n", .{sdbg});
            }
            const btl = readGlobalStr(act_ctx, "__bashTool") catch continue;
            if (!std.mem.eql(u8, btl, "pending") and btl.len > 0) {
                btl_done = true;
                std.debug.print("[bash-tool] {s}\n", .{btl});
                if (!std.mem.startsWith(u8, btl, "ok:")) return error.BashTool;
            }
            if (subproc_done and rt_done and env_done and shl_done and btl_done) break;
        }
        if (!subproc_done or !rt_done or !env_done or !shl_done or !btl_done) return error.SubprocGuestTimeout;
    }
    // —— Web 网关：宿主客户端 → 事件循环 → guest 回调真实往返
    {
        const client = sock_c.dsh_sock_connect(web_port);
        if (client < 0) return error.GatewayConnect;
        defer _ = sock_c.dsh_sock_close(client);
        const req = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n";
        _ = sock_c.dsh_sock_write(client, req.ptr, req.len);
        loop.run(25);
        var gbuf: [16 * 1024]u8 = undefined;
        var gused: usize = 0;
        while (gused < gbuf.len) {
            const n = sock_c.dsh_sock_read(client, gbuf[gused..].ptr, gbuf.len - gused);
            if (n <= 0) break;
            gused += @intCast(n);
            if (std.mem.indexOf(u8, gbuf[0..gused], "\r\n\r\n") != null) break;
        }
        const gbody_start = std.mem.indexOf(u8, gbuf[0..gused], "\r\n\r\n") orelse return error.GatewayBadResponse;
        const gbody = gbuf[gbody_start + 4 .. gused];
        std.debug.print("boot smoke: gateway body='{s}'\n", .{gbody});
        if (!std.mem.eql(u8, gbody, "pong:/ping")) return error.GatewayBodyMismatch;
        if (web_mode) {
            const wclient = sock_c.dsh_sock_connect(web_port);
            if (wclient < 0) return error.WebConnect;
            defer _ = sock_c.dsh_sock_close(wclient);
            const wre = "GET /index.html HTTP/1.1\r\nHost: localhost\r\n\r\n";
            _ = sock_c.dsh_sock_write(wclient, wre.ptr, wre.len);
            loop.run(25);
            var wbuf: [16 * 1024]u8 = undefined;
            var wused: usize = 0;
            while (wused < wbuf.len) {
                const n = sock_c.dsh_sock_read(wclient, wbuf[wused..].ptr, wbuf.len - wused);
                if (n <= 0) break;
                wused += @intCast(n);
                if (std.mem.indexOf(u8, wbuf[0..wused], "\r\n\r\n") != null) break;
            }
            const wstart = std.mem.indexOf(u8, wbuf[0..wused], "\r\n\r\n") orelse return error.WebBadResponse;
            const wbody = wbuf[wstart + 4 .. wused];
            std.debug.print("[web] static body='{s}'\n", .{wbody});
            const gw_proto = try readGlobalStr(act_ctx, "__protoSummary");
            defer std.heap.page_allocator.free(gw_proto);
            std.debug.print("[web] proto='{s}'\n", .{gw_proto});
            if (std.mem.indexOf(u8, wbody, "dsh web") == null) return error.WebStatic;
        }
        loop.run(200);
        const gw_big = try readGlobalStr(act_ctx, "__bigOk");
        defer std.heap.page_allocator.free(gw_big);
        std.debug.print("boot smoke: bigOk='{s}'\n", .{gw_big});
        if (!std.mem.startsWith(u8, gw_big, "ok:")) return error.GatewayBig;
        const gw_stream = try readGlobalStr(act_ctx, "__streamOk");
        defer std.heap.page_allocator.free(gw_stream);
        std.debug.print("boot smoke: streamOk='{s}'\n", .{gw_stream});
        if (!std.mem.startsWith(u8, gw_stream, "ok:")) return error.GatewayStream;
        const gw_sseframe = try readGlobalStr(act_ctx, "__sseFrame");
        defer std.heap.page_allocator.free(gw_sseframe);
        std.debug.print("boot smoke: sseFrame='{s}'\n", .{gw_sseframe});
        if (!std.mem.startsWith(u8, gw_sseframe, "ok:")) return error.GatewaySseFrame;
        loop.run(400);
        const gw_asyncpost = try readGlobalStr(act_ctx, "__asyncPost");
        defer std.heap.page_allocator.free(gw_asyncpost);
        std.debug.print("boot smoke: asyncPost='{s}'\n", .{gw_asyncpost});
        if (!std.mem.startsWith(u8, gw_asyncpost, "ok:")) return error.GatewayAsyncPost;
        const gw_post = try readGlobalStr(act_ctx, "__gwPost");
        defer std.heap.page_allocator.free(gw_post);
        std.debug.print("boot smoke: gwPost='{s}'\n", .{gw_post});
        if (!std.mem.startsWith(u8, gw_post, "ok:")) return error.GatewayPost;
        loop.run(250);
        const gw_fetch = try readGlobalStr(act_ctx, "__fetchOk");
        defer std.heap.page_allocator.free(gw_fetch);
        std.debug.print("boot smoke: fetchOk='{s}'\n", .{gw_fetch});
        if (!std.mem.startsWith(u8, gw_fetch, "ok:")) return error.GatewayFetch;
        loop.run(250);
        const gw_sse = try readGlobalStr(act_ctx, "__sseJoin");
        defer std.heap.page_allocator.free(gw_sse);
        std.debug.print("boot smoke: sseJoin='{s}'\n", .{gw_sse});
        if (!std.mem.startsWith(u8, gw_sse, "ok:")) return error.GatewaySse;
        loop.run(250);
        const gw_llmstep = try readGlobalStr(act_ctx, "__llmStep");
        defer std.heap.page_allocator.free(gw_llmstep);
        std.debug.print("boot smoke: llmStep='{s}'\n", .{gw_llmstep});
        const gw_llmrt = try readGlobalStr(act_ctx, "__llmRt");
        defer std.heap.page_allocator.free(gw_llmrt);
        std.debug.print("boot smoke: llmRt='{s}'\n", .{gw_llmrt});
        const gw_adon = try readGlobalStr(act_ctx, "__adOn");
        defer std.heap.page_allocator.free(gw_adon);
        std.debug.print("boot smoke: adOn='{s}'\n", .{gw_adon});
        if (!std.mem.startsWith(u8, gw_llmrt, "ok:")) return error.LlmRuntime;
        loop.run(400);
        const gw_llmloop = try readGlobalStr(act_ctx, "__llmLoop");
        defer std.heap.page_allocator.free(gw_llmloop);
        std.debug.print("boot smoke: llmLoop='{s}'\n", .{gw_llmloop});
        if (!std.mem.startsWith(u8, gw_llmloop, "ok:")) return error.LlmToolLoop;
        const gw_pdiff = try readGlobalStr(act_ctx, "__persistDiff");
        defer std.heap.page_allocator.free(gw_pdiff);
        std.debug.print("boot smoke: persistDiff='{s}'\n", .{gw_pdiff});
        if (!std.mem.startsWith(u8, gw_pdiff, "ok:")) return error.PersistDiff;
        const gw_nm = try readGlobalStr(act_ctx, "__nodeMatrix");
        defer std.heap.page_allocator.free(gw_nm);
        std.debug.print("boot smoke: nodeMatrix='{s}'\n", .{gw_nm});
        if (!std.mem.startsWith(u8, gw_nm, "ok:")) return error.NodeMatrix;
        const gw_ps = try readGlobalStr(act_ctx, "__procShim");
        defer std.heap.page_allocator.free(gw_ps);
        std.debug.print("boot smoke: procShim='{s}'\n", .{gw_ps});
        if (!std.mem.startsWith(u8, gw_ps, "ok:")) return error.ProcShim;
        const gw_als = try readGlobalStr(act_ctx, "__alsOk");
        defer std.heap.page_allocator.free(gw_als);
        std.debug.print("boot smoke: alsOk='{s}'\n", .{gw_als});
        if (!std.mem.startsWith(u8, gw_als, "ok:")) return error.AlsSync;
        const gw_life = try readGlobalStr(act_ctx, "__lifeCycle");
        defer std.heap.page_allocator.free(gw_life);
        std.debug.print("boot smoke: lifeCycle='{s}'\n", .{gw_life});
        if (!std.mem.startsWith(u8, gw_life, "ok:")) return error.SessionLifecycle;
        const gw_stress = try readGlobalStr(act_ctx, "__stressRss");
        defer std.heap.page_allocator.free(gw_stress);
        std.debug.print("boot smoke: stressRss='{s}'\n", .{gw_stress});
        if (!std.mem.startsWith(u8, gw_stress, "ok:")) return error.StressRss;
        const gw_cjs = try readGlobalStr(act_ctx, "__cjsOk");
        defer std.heap.page_allocator.free(gw_cjs);
        std.debug.print("boot smoke: cjsOk='{s}'\n", .{gw_cjs});
        if (!std.mem.startsWith(u8, gw_cjs, "ok:")) return error.CjsDefault;
        const gw_yaml = try readGlobalStr(act_ctx, "__yamlCompat");
        defer std.heap.page_allocator.free(gw_yaml);
        std.debug.print("boot smoke: yamlCompat={s}\n", .{gw_yaml});
        if (!std.mem.eql(u8, gw_yaml, "ok")) return error.YamlCompat;
        const gw_markdown = try readGlobalStr(act_ctx, "__markdownCompat");
        defer std.heap.page_allocator.free(gw_markdown);
        std.debug.print("boot smoke: markdownCompat={s}\n", .{gw_markdown});
        if (!std.mem.eql(u8, gw_markdown, "ok")) return error.MarkdownCompat;
        const gw_z = try readGlobalStr(act_ctx, "__zProbe");
        defer std.heap.page_allocator.free(gw_z);
        std.debug.print("boot smoke: zProbe='{s}'\n", .{gw_z});
        if (!std.mem.startsWith(u8, gw_z, "ok")) return error.ZProbe;
        const gw_ps2 = try readGlobalStr(act_ctx, "__permStack");
        defer std.heap.page_allocator.free(gw_ps2);
        std.debug.print("boot smoke: permStack='{s}'\n", .{gw_ps2});
        const gw_st = try readGlobalStr(act_ctx, "__settingsStack");
        defer std.heap.page_allocator.free(gw_st);
        std.debug.print("boot smoke: settingsStack='{s}'\n", .{gw_st});
        const gw_sw = try readGlobalStr(act_ctx, "__settingsWrite");
        defer std.heap.page_allocator.free(gw_sw);
        std.debug.print("boot smoke: settingsWrite='{s}'\n", .{gw_sw});
        if (!std.mem.eql(u8, gw_sw, "ok")) return error.SettingsWrite;
        const gw_cl = try readGlobalStr(act_ctx, "__credentialsLoad");
        defer std.heap.page_allocator.free(gw_cl);
        std.debug.print("boot smoke: credentialsLoad='{s}'\n", .{gw_cl});
        if (!std.mem.eql(u8, gw_cl, "ok")) return error.CredentialsLoad;
        const gw_wt = try readGlobalStr(act_ctx, "__webToolStack");
        defer std.heap.page_allocator.free(gw_wt);
        std.debug.print("boot smoke: webToolStack='{s}'\n", .{gw_wt});
        const gw_td = try readGlobalStr(act_ctx, "__tdProbe");
        defer std.heap.page_allocator.free(gw_td);
        std.debug.print("boot smoke: tdProbe='{s}'\n", .{gw_td});
        const gw_miss = try readGlobalStr(act_ctx, "__missingRead");
        defer std.heap.page_allocator.free(gw_miss);
        std.debug.print("boot smoke: missingRead='{s}'\n", .{gw_miss});
        const dp_names = [_][]const u8{ "dsh-subprocess-local", "dsh-sandbox-local", "dsh-attachment-local", "dsh-llm-pi-ai", "dsh-llm-deepseek" };
        {
            const pit = try readGlobalStr(act_ctx, "__piTs");
            defer std.heap.page_allocator.free(pit);
            std.debug.print("boot smoke: piTs='{s}'\n", .{pit});
        }
        for (dp_names) |dpn| {
            const dpvB = try std.fmt.allocPrint(std.heap.page_allocator, "__dp_{s}", .{dpn});
            defer std.heap.page_allocator.free(dpvB);
            const dpv = try readGlobalStr(act_ctx, dpvB.ptr);
            defer std.heap.page_allocator.free(dpv);
            std.debug.print("boot smoke: {s}='{s}'\n", .{ dpn, dpv });
        }
        const gw_sk = try readGlobalStr(act_ctx, "__skillStack");
        defer std.heap.page_allocator.free(gw_sk);
        std.debug.print("boot smoke: skillStack='{s}'\n", .{gw_sk});
        const gw_chk = try readGlobalStr(act_ctx, "__chkProbe");
        defer std.heap.page_allocator.free(gw_chk);
        std.debug.print("boot smoke: chkProbe='{s}'\n", .{gw_chk});
        loop.run(300);
        const gw_pf = try readGlobalStr(act_ctx, "__perfStream");
        defer std.heap.page_allocator.free(gw_pf);
        std.debug.print("boot smoke: perfStream='{s}'\n", .{gw_pf});
        if (!std.mem.startsWith(u8, gw_pf, "ok:")) return error.PerfStream;
        // —— WS 升级握手（RFC 6455 官方向量：key "dGhlIHNhbXBsZSBub25jZQ==" → accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="）
        {
            const wclient = sock_c.dsh_sock_connect(web_port);
            if (wclient < 0) return error.WsConnect;
            defer _ = sock_c.dsh_sock_close(wclient);
            const wreq = "GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";
            _ = sock_c.dsh_sock_write(wclient, wreq.ptr, wreq.len);
            loop.run(25);
            var wbuf: [16 * 1024]u8 = undefined;
            var wused: usize = 0;
            while (wused < wbuf.len) {
                const n = sock_c.dsh_sock_read(wclient, wbuf[wused..].ptr, wbuf.len - wused);
                if (n <= 0) break;
                wused += @intCast(n);
                if (std.mem.indexOf(u8, wbuf[0..wused], "\r\n\r\n") != null) break;
            }
            const wbody_start = std.mem.indexOf(u8, wbuf[0..wused], "\r\n\r\n") orelse return error.WsBadResponse;
            const wheaders = wbuf[0 .. wbody_start + 4];
            const wbody = wbuf[wbody_start + 4 .. wused];
            std.debug.print("boot smoke: ws status='{s}' body='{s}'\n", .{wheaders[0..12], wbody});
            if (std.mem.indexOf(u8, wheaders, "101 Switching Protocols") == null) return error.WsStatus;
            if (std.mem.indexOf(u8, wheaders, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") == null) return error.WsAcceptVector;
            // —— 升级后帧通道：masked text 帧 → guest 回调（第三参）→ 服务端帧回显
            const payload = "hello-frames";
            var frame: [70]u8 = undefined;
            frame[0] = 0x81;
            frame[1] = @intCast(0x80 | payload.len);
            const mask = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
            @memcpy(frame[2..6], &mask);
            for (payload, 0..) |ch, i| frame[6 + i] = ch ^ mask[i % 4];
            _ = sock_c.dsh_sock_write(wclient, &frame, 2 + 4 + payload.len);
            loop.run(25);
            var fbuf: [1024]u8 = undefined;
            var fused: usize = 0;
            while (fused < fbuf.len) {
                const n = sock_c.dsh_sock_read(wclient, fbuf[fused..].ptr, fbuf.len - fused);
                if (n <= 0) break;
                fused += @intCast(n);
                if (fused >= 2 and fbuf[0] == 0x81 and fused >= 2 + (fbuf[1] & 0x7f)) break;
            }
            const flen = fbuf[1] & 0x7f;
            const fpayload = fbuf[2 .. 2 + flen];
            std.debug.print("boot smoke: ws frame op={d} payload='{s}'\n", .{fbuf[0], fpayload});
            if (fbuf[0] != 0x81) return error.WsFrameOpcode;
            if (std.mem.indexOf(u8, fpayload, "ws-echo:hello-frames") == null) return error.WsFrameEcho;
            // —— WebUI 协议帧：JSON 消息 → 会话事件摘要帧回传
            const sendFrame = struct {
                fn send(fd: i32, msg: []const u8, maskv: [4]u8) void {
                    var fbuf2: [512]u8 = undefined;
                    fbuf2[0] = 0x81;
                    fbuf2[1] = @intCast(0x80 | msg.len);
                    @memcpy(fbuf2[2..6], &maskv);
                    for (msg, 0..) |ch, i| fbuf2[6 + i] = ch ^ maskv[i % 4];
                    _ = sock_c.dsh_sock_write(fd, &fbuf2, 6 + msg.len);
                }
                const recv = struct {
                    fn recv(fd: i32, out: []u8) usize {
                        var used: usize = 0;
                        while (used < out.len) {
                            const n = sock_c.dsh_sock_read(fd, out[used..].ptr, out.len - used);
                            if (n <= 0) break;
                            used += @intCast(n);
                            if (used >= 2 and out[0] == 0x81 and used >= 2 + (out[1] & 0x7f)) break;
                        }
                        return used;
                    }
                };
            };
            const mask2 = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
            const msg1 = "{\"op\":\"events\",\"session\":\"boot-child\"}";
            sendFrame.send(wclient, msg1, mask2);
            loop.run(25);
            var pbuf: [1024]u8 = undefined;
            const pused = sendFrame.recv.recv(wclient, &pbuf);
            _ = pused;
            const pflen = pbuf[1] & 0x7f;
            const ppayload = pbuf[2 .. 2 + pflen];
            std.debug.print("boot smoke: ws proto='{s}'\n", .{ppayload});
            if (std.mem.indexOf(u8, ppayload, "\"count\":") == null) return error.WsProtoEvents;
            if (std.mem.indexOf(u8, ppayload, "session/title") == null) return error.WsProtoTitle;
            const msg2 = "{\"op\":\"sessions\"}";
            sendFrame.send(wclient, msg2, mask2);
            loop.run(25);
            const p2used = sendFrame.recv.recv(wclient, &pbuf);
            _ = p2used;
            const p2flen = pbuf[1] & 0x7f;
            const p2payload = pbuf[2 .. 2 + p2flen];
            std.debug.print("boot smoke: ws proto2='{s}'\n", .{p2payload});
            if (std.mem.indexOf(u8, p2payload, "\"boot-child\"") == null or std.mem.indexOf(u8, p2payload, "\"boot-demo\"") == null) return error.WsProtoSessions;
            // —— WebUI 协议 schema：畸形消息（缺 session）→ ws-bad-schema
            const msgBad = "{\"op\":\"events\"}";
            sendFrame.send(wclient, msgBad, mask2);
            loop.run(25);
            const qbused = sendFrame.recv.recv(wclient, &pbuf);
            _ = qbused;
            const qbpayload = pbuf[2 .. 2 + (pbuf[1] & 0x7f)];
            std.debug.print("boot smoke: ws bad='{s}'\n", .{qbpayload});
            if (std.mem.indexOf(u8, qbpayload, "ws-bad-schema") == null) return error.WsSchemaReject;
            // —— WebUI 沙箱状态协议：sandboxStatus（读取）→ sandboxSet（切换）→ 读回
            const msgS1 = "{\"op\":\"sandboxStatus\",\"session\":\"boot-child\"}";
            sendFrame.send(wclient, msgS1, mask2);
            loop.run(25);
            const qs1used = sendFrame.recv.recv(wclient, &pbuf);
            _ = qs1used;
            const qs1payload = pbuf[2 .. 2 + (pbuf[1] & 0x7f)];
            std.debug.print("boot smoke: ws sb-status='{s}'\n", .{qs1payload});
            if (std.mem.indexOf(u8, qs1payload, "\"mode\":\"read-only\"") == null) return error.WsSandboxStatus;
            const msgS2 = "{\"op\":\"sandboxSet\",\"session\":\"boot-child\",\"mode\":\"workspace-write\"}";
            sendFrame.send(wclient, msgS2, mask2);
            loop.run(25);
            const qs2used = sendFrame.recv.recv(wclient, &pbuf);
            _ = qs2used;
            std.debug.print("boot smoke: ws sb-set='{s}'\n", .{pbuf[2 .. 2 + (pbuf[1] & 0x7f)]});
            const msgS3 = "{\"op\":\"sandboxStatus\",\"session\":\"boot-child\"}";
            sendFrame.send(wclient, msgS3, mask2);
            loop.run(25);
            const qs3used = sendFrame.recv.recv(wclient, &pbuf);
            _ = qs3used;
            const qs3payload = pbuf[2 .. 2 + (pbuf[1] & 0x7f)];
            std.debug.print("boot smoke: ws sb-status2='{s}'\n", .{qs3payload});
            if (std.mem.indexOf(u8, qs3payload, "\"mode\":\"workspace-write\"") == null) return error.WsSandboxSet;
            // —— 异步帧响应：query（promise 发起）→ poll（取回结果）
            const msg3 = "{\"op\":\"query\",\"session\":\"boot-child\"}";
            sendFrame.send(wclient, msg3, mask2);
            loop.run(25);
            const q3used = sendFrame.recv.recv(wclient, &pbuf);
            _ = q3used;
            std.debug.print("boot smoke: ws query-ack='{s}'\n", .{pbuf[2 .. 2 + (pbuf[1] & 0x7f)]});
            loop.run(25); // 排空微任务（query promise 落定 → __wsPending）
            const msg4 = "{\"op\":\"poll\"}";
            sendFrame.send(wclient, msg4, mask2);
            loop.run(25);
            const q4used = sendFrame.recv.recv(wclient, &pbuf);
            _ = q4used;
            const q4flen = pbuf[1] & 0x7f;
            const q4payload = pbuf[2 .. 2 + q4flen];
            std.debug.print("boot smoke: ws poll='{s}'\n", .{q4payload});
            if (std.mem.indexOf(u8, q4payload, "\"events\":") == null) return error.WsAsyncPoll;
            // —— 长连接推送：subscribe（session/event 订阅）→ emit（append）→ 主动 push
            const msg5 = "{\"op\":\"subscribe\"}";
            sendFrame.send(wclient, msg5, mask2);
            loop.run(25);
            const q5used = sendFrame.recv.recv(wclient, &pbuf);
            _ = q5used;
            const sub_payload = pbuf[2 .. 2 + (pbuf[1] & 0x7f)];
            std.debug.print("boot smoke: ws sub-ack='{s}'\n", .{sub_payload});
            if (std.mem.indexOf(u8, sub_payload, "ws-subscribed:") == null) return error.WsSubAckId;
            // 定向验证：whoami → 连接 id；错误 id 定向 → 无帧（后续读回检查）
            const msgW = "{\"op\":\"whoami\"}";
            sendFrame.send(wclient, msgW, mask2);
            loop.run(25);
            const qwused = sendFrame.recv.recv(wclient, &pbuf);
            _ = qwused;
            std.debug.print("boot smoke: ws whoami='{s}'\n", .{pbuf[2 .. 2 + (pbuf[1] & 0x7f)]});
            if (std.mem.indexOf(u8, pbuf[2 .. 2 + (pbuf[1] & 0x7f)], "ws-conn:") == null) return error.WsWhoami;
            const msg6 = "{\"op\":\"emit\",\"session\":\"boot-child\",\"type\":\"user/text\",\"data\":{\"content\":[{\"type\":\"text\",\"text\":\"push-test\"}]}}";
            sendFrame.send(wclient, msg6, mask2);
            loop.run(25);
            // 主动 push 帧先于 emit ack 写出（回调内 append 同步 push）
            const q6used = sendFrame.recv.recv(wclient, &pbuf);
            _ = q6used;
            const q6flen = pbuf[1] & 0x7f;
            const q6payload = pbuf[2 .. 2 + q6flen];
            std.debug.print("boot smoke: ws push='{s}'\n", .{q6payload});
            if (std.mem.indexOf(u8, q6payload, "\"op\":\"event\"") == null) return error.WsPushEvent;
            if (std.mem.indexOf(u8, q6payload, "\"type\":\"user/text\"") == null) return error.WsPushType;
        }
        // 网关资源释放（route cb dup 引用 + fd）——runtime free 前必须清；
        // serve 模式跳过：服务器继续对外服务，收尾由 serve 循环后的统一清理承担。
        if (!web_serve) _ = http_bridge.jsStop(act_ctx, undefined, 0, @constCast(&[_]c.JSValueConst{}));
    }
    if (std.mem.eql(u8, tool_exec, "pending")) return error.ToolExecNotCalled;
    if (tool_read != 1) return error.ToolReadNotRegistered;
    if (tool_applied != 1) return error.ToolFsNotApplied;
    if (sq_tried != 1) return error.NodeSqliteRealIo;
    if (done != 1) return error.BootNotDone;
    if (!std.mem.eql(u8, boot, "ok:true:object:object:object:object:object")) return error.BootFsLocalMismatch;
    if (core_mode) {
        printJsMemory(act.host.rt, "core");
        const rss_core = readVmRss(init.io);
        std.debug.print("core mode: rss={d}KB (small-closure baseline)\n", .{rss_core});
        std.process.exit(0); // 测量模式：立即退出（跳过 defer 链——进程清理交 OS）
    }
    {
        const md = try readGlobalStr(act_ctx, "__llmModelDiscovery");
        defer std.heap.page_allocator.free(md);
        std.debug.print("boot smoke: llmModelDiscovery='{s}'\n", .{md});
        if (!std.mem.eql(u8, md, "ok")) return error.LlmModelDiscovery;
        const pp = try readGlobalStr(act_ctx, "__permissionPreset");
        defer std.heap.page_allocator.free(pp);
        std.debug.print("boot smoke: permissionPreset='{s}'\n", .{pp});
        if (!std.mem.eql(u8, pp, "ok")) return error.PermissionPresetService;
        const lf = try readGlobalStr(act_ctx, "__loadFails");
        defer std.heap.page_allocator.free(lf);
        std.debug.print("boot smoke: loadFails='{s}'\n", .{lf});
        const lsk = try readGlobalStr(act_ctx, "__loadSkips");
        defer std.heap.page_allocator.free(lsk);
        std.debug.print("boot smoke: loadSkips='{s}'\n", .{lsk});
    }
    if (count < 70) return error.PatchLoadedMismatch;
    if (skipped < 2) return error.PatchDisabledNotSkipped;
    if (!std.mem.eql(u8, js_mode, "danger-full-access")) return error.JsExprEnvMismatch;
    if (!std.mem.eql(u8, mode, "overlay") and !std.mem.startsWith(u8, mode, "!!js ")) return error.PatchOverlayNotEffective;
    // —— headless 输出：模型最终答复（黄金行）+ golden 逐字节对照（llm-mock 录播——无网可复现）
    if (headless_mode) {
        const ho = try readGlobalStr(act_ctx, "__headlessOut");
        defer std.heap.page_allocator.free(ho);
        std.debug.print("[headless] model reply: '{s}'\n", .{ho});
        {
            const cwd_dir = std.Io.Dir.cwd();
            const out_file = try cwd_dir.createFile(init.io, "/tmp/dsh-headless-out.txt", .{ .truncate = true });
            defer out_file.close(init.io);
            try std.Io.File.writePositionalAll(out_file, init.io, ho, 0);
            try std.Io.File.writePositionalAll(out_file, init.io, "\n", ho.len);
        }
        const golden = try std.Io.Dir.cwd().readFileAlloc(init.io, "golden/headless.txt", std.heap.page_allocator, std.Io.Limit.limited(1 << 20));
        defer std.heap.page_allocator.free(golden);
        const out_line = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\n", .{ho});
        defer std.heap.page_allocator.free(out_line);
        if (!std.mem.eql(u8, golden, out_line)) {
            std.debug.print("[headless] golden mismatch: golden={d} bytes out={d} bytes\n", .{ golden.len, out_line.len });
            return error.HeadlessGolden;
        }
        std.debug.print("[headless] golden match ({d} bytes)\n", .{golden.len});
    }
    // —— 真渠道探针结果（真 API 一轮——宽限泵；非门禁，打印即证）
    if (llm_real) {
        _ = loop.run(12000);
        const rw = try readGlobalStr(act_ctx, "__realWire");
        defer std.heap.page_allocator.free(rw);
        std.debug.print("boot smoke: realWire='{s}'\n", .{rw});
        const ci = try readGlobalStr(act_ctx, "__chatImport");
        defer std.heap.page_allocator.free(ci);
        std.debug.print("boot smoke: chatImport='{s}'\n", .{ci});
        const rl = try readGlobalStr(act_ctx, "__realLlm");
        defer std.heap.page_allocator.free(rl);
        std.debug.print("boot smoke: realLlm='{s}'\n", .{rl});
    }
    printJsMemory(act.host.rt, "final");
    const rss_end = readVmRss(init.io);
    std.debug.print("boot smoke: rssStart={d}KB rssEnd={d}KB delta={d}KB\n", .{ rss_start, rss_end, if (rss_end > rss_start) rss_end - rss_start else 0 });
    std.debug.print("boot smoke OK: entry -> seam -> patch merge (last-write-wins) + !!js eval -> cordis plugins: PASS\n", .{});
    if (web_serve) {
        serveInstallSignals();
        std.debug.print("[web] serving http://127.0.0.1:{d}/index.html (SIGTERM/SIGINT 停止)\n", .{web_port});
        while (!serve_stop.load(.acquire)) loop.run(500);
        std.debug.print("[web] serve stop requested, shutting down\n", .{});
    }
    // http 桥收尾：routes/upgraded-conn 回调释放（引擎引用纪律——全链测试后）
    {
        const g = c.JS_GetGlobalObject(act_ctx);
        defer c.JS_FreeValue(act_ctx, g);
        const svc = c.JS_GetPropertyStr(act_ctx, g, "dshServices");
        defer c.JS_FreeValue(act_ctx, svc);
        const hsvc = c.JS_GetPropertyStr(act_ctx, svc, "http");
        defer c.JS_FreeValue(act_ctx, hsvc);
        const stopper = c.JS_GetPropertyStr(act_ctx, hsvc, "stop");
        defer c.JS_FreeValue(act_ctx, stopper);
        const undef_v = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
        const rv = c.JS_Call(act_ctx, stopper, undef_v, 0, null);
        if (!c.JS_IsException(rv)) {
            std.debug.print("boot smoke: http.stop released\n", .{});
        }
        c.JS_FreeValue(act_ctx, rv);
    }
}


// —— serve 模式信号：TERM/INT 置位，主循环下一轮观察后走正常收尾链（mock 进程组随 defer 清理）
var serve_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
fn onServeSignal(_: @TypeOf(std.os.linux.SIG.TERM)) callconv(.c) void {
    serve_stop.store(true, .release);
}
fn serveInstallSignals() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onServeSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART, // epoll_wait 自动重启——停止标志在 run 迭代边界观察
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// http 桥收尾：routes/upgraded-conn 回调释放（引擎引用纪律——defer 注册：任何路径都释放）
fn http_stop(act_ctx: ?*c.JSContext) void {
    const g = c.JS_GetGlobalObject(act_ctx);
    defer c.JS_FreeValue(act_ctx, g);
    const svc = c.JS_GetPropertyStr(act_ctx, g, "dshServices");
    defer c.JS_FreeValue(act_ctx, svc);
    const hsvc = c.JS_GetPropertyStr(act_ctx, svc, "http");
    defer c.JS_FreeValue(act_ctx, hsvc);
    const stopper = c.JS_GetPropertyStr(act_ctx, hsvc, "stop");
    defer c.JS_FreeValue(act_ctx, stopper);
    const undef_v = c.JSValue{ .u = .{ .int32 = 0 }, .tag = c.JS_TAG_UNDEFINED };
    const rv = c.JS_Call(act_ctx, stopper, undef_v, 0, null);
    if (!c.JS_IsException(rv)) {
        std.debug.print("boot smoke: http.stop released\n", .{});
    }
    c.JS_FreeValue(act_ctx, rv);
}


/// mock 清理（进程组 TERM）
fn killMockPidDo(pid: c_int) void {
    if (pid <= 0) return;
    _ = std.c.kill(-pid, std.os.linux.SIG.TERM);
    var status: u32 = 0;
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        const w = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
        if (w != 0) return; // 已退出（或已回收）
        const ts = std.os.linux.timespec{ .sec = 0, .nsec = 20_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
    // TERM 宽限未退 —— KILL 定局（153 轮升级链：TERM 宽容失败——KILL 闭环）
    _ = std.c.kill(-pid, std.os.linux.SIG.KILL);
    tries = 0;
    while (tries < 30) : (tries += 1) {
        const w = std.os.linux.waitpid(pid, &status, std.os.linux.W.NOHANG);
        if (w != 0) return;
        const ts = std.os.linux.timespec{ .sec = 0, .nsec = 20_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
