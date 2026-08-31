const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dsh-zig-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the runtime stub");
    run_step.dependOn(&run_cmd.step);

    // Zig-side contract test: seam.zig type-checks and its stub-host import
    // helper behaves. Run with `zig build test`.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the runtime contract tests");
    test_step.dependOn(&run_unit_tests.step);

    // M-2 工具链 spike：Zig ↔ quickjs-ng 集成验证。
    // 运行: `zig build spike && zig build spike-run`
    const quickjs_include = b.path("vendor/quickjs-ng");
    const spike = b.addExecutable(.{
        .name = "quickjs-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_quickjs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    spike.root_module.link_libc = true;
    spike.root_module.addIncludePath(quickjs_include);
    spike.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const spike_step = b.step("spike", "Build the quickjs-ng integration spike");
    spike_step.dependOn(&spike.step);
    const spike_run = b.addRunArtifact(spike);
    const spike_run_step = b.step("spike-run", "Build and run the quickjs-ng integration spike");
    spike_run_step.dependOn(&spike_run.step);

    // invalid UTF-8 根因对照 probe（模块系统活动 × UTF-8 eval）。
    const utf8_probe = b.addExecutable(.{
        .name = "utf8-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utf8_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    utf8_probe.root_module.link_libc = true;
    utf8_probe.root_module.addIncludePath(quickjs_include);
    utf8_probe.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const utf8_probe_run = b.addRunArtifact(utf8_probe);
    const utf8_probe_step = b.step("utf8-probe-run", "Run the UTF-8 × module-system probe");
    utf8_probe_step.dependOn(&utf8_probe_run.step);

    // ESM 模块链接器 spike：builtin 表 + 相对模块 + ESM 图。
    const esm_spike = b.addExecutable(.{
        .name = "quickjs-esm-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_esm.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    esm_spike.root_module.link_libc = true;
    esm_spike.root_module.addIncludePath(quickjs_include);
    esm_spike.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const esm_spike_run = b.addRunArtifact(esm_spike);
    const esm_spike_step = b.step("esm-spike-run", "Build and run the ESM module-linker spike");
    esm_spike_step.dependOn(&esm_spike_run.step);

    // HostModuleLoader v0 spike：builtin + ESM + CJS 包装 + import.meta.
    const loader_spike = b.addExecutable(.{
        .name = "quickjs-loader-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_loader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    loader_spike.root_module.link_libc = true;
    loader_spike.root_module.addIncludePath(quickjs_include);
    loader_spike.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const loader_spike_run = b.addRunArtifact(loader_spike);
    const loader_spike_step = b.step("loader-spike-run", "Build and run the HostModuleLoader v0 spike");
    loader_spike_step.dependOn(&loader_spike_run.step);

    // cordis 真实插件互操作 spike：@embedFile 内嵌闭包。
    const cordis_spike = b.addExecutable(.{
        .name = "quickjs-cordis-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_cordis.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cordis_spike.root_module.link_libc = true;
    cordis_spike.root_module.addIncludePath(quickjs_include);
    cordis_spike.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const cordis_spike_run = b.addRunArtifact(cordis_spike);
    const cordis_spike_step = b.step("cordis-spike-run", "Build and run the cordis interop spike");
    cordis_spike_step.dependOn(&cordis_spike_run.step);

    // CJS require() 重入 spike。
    const require_spike = b.addExecutable(.{
        .name = "quickjs-require-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spike_require.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    require_spike.root_module.link_libc = true;
    require_spike.root_module.addIncludePath(quickjs_include);
    require_spike.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2" },
    });
    const require_spike_run = b.addRunArtifact(require_spike);
    const require_spike_step = b.step("require-spike-run", "Build and run the CJS require re-entry spike");
    require_spike_step.dependOn(&require_spike_run.step);

    // 契约测试：QuickjsHost（HostModuleLoader 的 quickjs 后端），经 test 体系验证。
    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    host_tests.root_module.link_libc = true;
    host_tests.root_module.addIncludePath(quickjs_include);
    host_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-g" },
    });
    const host_tests_run = b.addRunArtifact(host_tests);
    const host_test_step = b.step("test-quickjs", "Run the QuickjsHost contract tests");
    host_test_step.dependOn(&host_tests_run.step);

    // YAML shim 契约测试（js-yaml/yaml 双根——重写解析器回归锁）。
    const yaml_shim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/yaml_shim_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    yaml_shim_tests.root_module.link_libc = true;
    yaml_shim_tests.root_module.addIncludePath(quickjs_include);
    yaml_shim_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-g" },
    });
    const yaml_shim_tests_run = b.addRunArtifact(yaml_shim_tests);
    const yaml_shim_test_step = b.step("test-yaml-shim", "Run the YAML shim contract tests (js-yaml/yaml roots)");
    yaml_shim_test_step.dependOn(&yaml_shim_tests_run.step);

    // Turndown/GFM shim 契约测试（web 工具 HTML→Markdown 契约锁）。
    const turndown_shim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/turndown_shim_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    turndown_shim_tests.root_module.link_libc = true;
    turndown_shim_tests.root_module.addIncludePath(quickjs_include);
    turndown_shim_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-g" },
    });
    const turndown_shim_tests_run = b.addRunArtifact(turndown_shim_tests);
    const turndown_shim_test_step = b.step("test-turndown-shim", "Run the Turndown/GFM shim contract tests (web tool)");
    turndown_shim_test_step.dependOn(&turndown_shim_tests_run.step);

    // OTEL shim 契约测试（api/sdk-logs/resources/exporter 四根——telemetry 面锁）。
    const otel_shim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/otel_shim_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    otel_shim_tests.root_module.link_libc = true;
    otel_shim_tests.root_module.addIncludePath(quickjs_include);
    otel_shim_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-g" },
    });
    const otel_shim_tests_run = b.addRunArtifact(otel_shim_tests);
    const otel_shim_test_step = b.step("test-otel-shim", "Run the OTEL shim contract tests (telemetry)");
    otel_shim_test_step.dependOn(&otel_shim_tests_run.step);

    // M-3：sqlite DatabaseSync shim 测试（vendored amalgamation）。
    const sqlite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlite_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_tests.root_module.link_libc = true;
    sqlite_tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    sqlite_tests.root_module.addIncludePath(b.path("src"));
    sqlite_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/sqlite/sqlite3.c",
            "src/sqlite_wrap.c",
        },
        .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_GET_TABLE", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_JSON", "-DSQLITE_ENABLE_FTS5", "-O2", "-g" },
    });
    const sqlite_tests_run = b.addRunArtifact(sqlite_tests);
    const sqlite_test_step = b.step("test-sqlite", "Run the sqlite DatabaseSync shim tests");
    sqlite_test_step.dependOn(&sqlite_tests_run.step);

    // smoke 二进制（直接模式，无 listen 协议）：`zig build sqlite-smoke-run`
    const sqlite_smoke = b.addExecutable(.{
        .name = "sqlite-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlite_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_smoke.root_module.link_libc = true;
    sqlite_smoke.root_module.addIncludePath(b.path("vendor/sqlite"));
    sqlite_smoke.root_module.addIncludePath(b.path("src"));
    sqlite_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/sqlite/sqlite3.c",
            "src/sqlite_wrap.c",
        },
        .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_GET_TABLE", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_JSON", "-DSQLITE_ENABLE_FTS5", "-O2", "-g" },
    });
    const sqlite_smoke_run = b.addRunArtifact(sqlite_smoke);
    const sqlite_smoke_step = b.step("sqlite-smoke-run", "Run the sqlite shim smoke suite (direct mode)");
    sqlite_smoke_step.dependOn(&sqlite_smoke_run.step);

    // fs 服务 smoke（std-only，无引擎无 sqlite）
    const fs_smoke = b.addExecutable(.{
        .name = "fs-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fs_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fs_smoke.root_module.link_libc = true;
    const fs_smoke_run = b.addRunArtifact(fs_smoke);
    const fs_smoke_step = b.step("fs-smoke-run", "Run the fs service smoke suite");
    fs_smoke_step.dependOn(&fs_smoke_run.step);

    // HTTP 服务 smoke
    const http_smoke = b.addExecutable(.{
        .name = "http-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    http_smoke.root_module.link_libc = true;
    http_smoke.root_module.addIncludePath(b.path("src"));
    http_smoke.root_module.addCSourceFile(.{ .file = b.path("src/socket_wrap.c"), .flags = &.{"-O2", "-g"} });
    const http_smoke_run = b.addRunArtifact(http_smoke);
    const http_smoke_step = b.step("http-smoke-run", "Run the HTTP server smoke suite");
    http_smoke_step.dependOn(&http_smoke_run.step);

    // event loop 合流点 smoke
    const el_smoke = b.addExecutable(.{
        .name = "event-loop-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/event_loop_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    el_smoke.root_module.link_libc = true;
    el_smoke.root_module.addIncludePath(quickjs_include);
    el_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const el_smoke_run = b.addRunArtifact(el_smoke);
    const el_smoke_step = b.step("event-loop-smoke-run", "Run the event loop integration smoke");
    el_smoke_step.dependOn(&el_smoke_run.step);

    // fs 服务桥 smoke（guest JS -> C 函数 -> Zig fs 服务）
    const fsb_smoke = b.addExecutable(.{
        .name = "fs-bridge-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fs_bridge_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fsb_smoke.root_module.link_libc = true;
    fsb_smoke.root_module.addIncludePath(quickjs_include);
    fsb_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const fsb_smoke_run = b.addRunArtifact(fsb_smoke);
    const fsb_smoke_step = b.step("fs-bridge-smoke-run", "Run the fs bridge smoke (guest JS -> Zig fs)");
    fsb_smoke_step.dependOn(&fsb_smoke_run.step);

    // cordis timer 插件级 smoke（plugin -> ctx.timeout -> host event loop）
    const ct_smoke = b.addExecutable(.{
        .name = "cordis-timer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cordis_timer_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ct_smoke.root_module.link_libc = true;
    ct_smoke.root_module.addIncludePath(quickjs_include);
    ct_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const ct_smoke_run = b.addRunArtifact(ct_smoke);
    const ct_smoke_step = b.step("cordis-timer-smoke-run", "Run the cordis timer plugin smoke");
    ct_smoke_step.dependOn(&ct_smoke_run.step);

    // 宿主服务注册表 smoke（dshServices 对象树 + 零泄漏哨兵）
    const hs_smoke = b.addExecutable(.{
        .name = "host-services-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_services_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hs_smoke.root_module.link_libc = true;
    hs_smoke.root_module.addIncludePath(quickjs_include);
    hs_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const hs_smoke_run = b.addRunArtifact(hs_smoke);
    const hs_smoke_step = b.step("host-services-smoke-run", "Run the host service registry smoke");
    hs_smoke_step.dependOn(&hs_smoke_run.step);

    // cordis 服务注入面 smoke（provide/inject -> c.fs/c.timer -> 宿主）
    const cs_smoke = b.addExecutable(.{
        .name = "cordis-services-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cordis_services_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cs_smoke.root_module.link_libc = true;
    cs_smoke.root_module.addIncludePath(quickjs_include);
    cs_smoke.root_module.addIncludePath(b.path("src"));
    cs_smoke.root_module.addIncludePath(b.path("vendor/sqlite"));
    cs_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "src/socket_wrap.c",
            "src/proc_wrap.c",
            "src/landlock_wrap.c",
            "vendor/sqlite/sqlite3.c",
            "src/sqlite_wrap.c",
            "src/hash_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_GET_TABLE", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_JSON", "-DSQLITE_ENABLE_FTS5", "-O2", "-g" },
    });
    const cs_smoke_run = b.addRunArtifact(cs_smoke);
    const cs_smoke_step = b.step("cordis-services-smoke-run", "Run the cordis service injection smoke");
    cs_smoke_step.dependOn(&cs_smoke_run.step);

    // http 桥 smoke（guest 路由回调 + 同步自往返）
    const hb_smoke = b.addExecutable(.{
        .name = "http-bridge-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_bridge_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hb_smoke.root_module.link_libc = true;
    hb_smoke.root_module.addIncludePath(quickjs_include);
    hb_smoke.root_module.addIncludePath(b.path("src"));
    hb_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "src/socket_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const hb_smoke_run = b.addRunArtifact(hb_smoke);
    const hb_smoke_step = b.step("http-bridge-smoke-run", "Run the http service bridge smoke");
    hb_smoke_step.dependOn(&hb_smoke_run.step);

    // http 网关形态 smoke（listen fd 入 epoll，事件循环驱动 guest 回调）
    const hg_smoke = b.addExecutable(.{
        .name = "http-gateway-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http_gateway_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hg_smoke.root_module.link_libc = true;
    hg_smoke.root_module.addIncludePath(quickjs_include);
    hg_smoke.root_module.addIncludePath(b.path("src"));
    hg_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "src/socket_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const hg_smoke_run = b.addRunArtifact(hg_smoke);
    const hg_smoke_step = b.step("http-gateway-smoke-run", "Run the http gateway smoke (epoll-driven accept)");
    hg_smoke_step.dependOn(&hg_smoke_run.step);

    // 信任栅栏 smoke（纯 Zig；api-request-trust.host.spec.ts 用例移植）
    const tf_smoke = b.addExecutable(.{
        .name = "trust-fence-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/trust_fence_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tf_smoke.root_module.link_libc = true;
    const tf_smoke_run = b.addRunArtifact(tf_smoke);
    const tf_smoke_step = b.step("trust-fence-smoke-run", "Run the trust fence smoke (host.spec.ts cases)");
    tf_smoke_step.dependOn(&tf_smoke_run.step);

    // HostModuleLoader 适配器契约测试（seam.ModuleHost ↔ QuickjsHost）
    const adapter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adapter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    adapter_tests.root_module.link_libc = true;
    adapter_tests.root_module.addIncludePath(quickjs_include);
    adapter_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const adapter_tests_run = b.addRunArtifact(adapter_tests);
    const adapter_test_step = b.step("test-adapter", "Run the HostModuleLoader adapter contract tests");
    adapter_test_step.dependOn(&adapter_tests_run.step);

    // 插件树启动链 smoke（entry -> seam -> cordis bootstrap）
    const boot_smoke = b.addExecutable(.{
        .name = "boot-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // M-4 泄漏纪律值守：-Dasan=true → C 源 ASAN（quickjs/sqlite/wrap）
    const asan_c = b.option(bool, "asan", "compile C sources with ASAN") orelse false;
    boot_smoke.root_module.sanitize_c = if (asan_c) .full else .off;
    boot_smoke.root_module.link_libc = true;
    boot_smoke.root_module.addIncludePath(quickjs_include);
    boot_smoke.root_module.addIncludePath(b.path("vendor/sqlite"));
    boot_smoke.root_module.addIncludePath(b.path("src"));
    boot_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "vendor/sqlite/sqlite3.c",
            "src/sqlite_wrap.c",
            "src/hash_wrap.c",
            "src/socket_wrap.c",
            "src/proc_wrap.c",
            "src/landlock_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_GET_TABLE", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_JSON", "-DSQLITE_ENABLE_FTS5", "-O2", "-g" },
    });
    const boot_smoke_run = b.addRunArtifact(boot_smoke);
    const boot_smoke_step = b.step("boot-smoke-run", "Run the plugin tree boot chain smoke");
    boot_smoke_step.dependOn(&boot_smoke_run.step);

    // headless 模式（M-2 CLI 合约雏形）：dsh headless --profile <json> → 链 → golden 对照
    const headless_run = b.addRunArtifact(boot_smoke);
    headless_run.addArg("headless");
    headless_run.addArg("--profile");
    headless_run.addArg("tools/headless-profile.json");
    const headless_step = b.step("headless-smoke-run", "Run the headless agent chain (CLI->profile->loader->llm->tool->exit) with golden compare");
    headless_step.dependOn(&headless_run.step);

    // web 模式（M-3 服务面骨架）：dsh web → 网关 + 静态根路由 → WS 面（全链复用）
    const web_run = b.addRunArtifact(boot_smoke);
    web_run.addArg("web");
    const web_step = b.step("web-smoke-run", "Run the web mode (gateway + static root + ws + services)");
    web_step.dependOn(&web_run.step);

    // core 模式（性能基线：patch 行集——bundle 不并入——小闭包 RSS）
    const core_run = b.addRunArtifact(boot_smoke);
    core_run.addArg("core");
    const core_step = b.step("core-smoke-run", "Run the core mode (boot subset rows — small-closure RSS baseline)");
    core_step.dependOn(&core_run.step);

    // crypto 桥 smoke（SHA-256 自实现 + 已知向量）
    const crypto_smoke = b.addExecutable(.{
        .name = "crypto-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crypto_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    crypto_smoke.root_module.link_libc = true;
    crypto_smoke.root_module.addIncludePath(quickjs_include);
    crypto_smoke.root_module.addIncludePath(b.path("src"));
    crypto_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "src/hash_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const crypto_smoke_run = b.addRunArtifact(crypto_smoke);
    const crypto_smoke_step = b.step("crypto-smoke-run", "Run the crypto (SHA-256) smoke");
    crypto_smoke_step.dependOn(&crypto_smoke_run.step);

    // 子进程桥 smoke（fork/exec 薄包装）
    const proc_smoke = b.addExecutable(.{
        .name = "proc-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proc_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    proc_smoke.root_module.link_libc = true;
    proc_smoke.root_module.addIncludePath(quickjs_include);
    proc_smoke.root_module.addIncludePath(b.path("src"));
    proc_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "src/proc_wrap.c",
            "src/landlock_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-O2", "-g" },
    });
    const proc_smoke_run = b.addRunArtifact(proc_smoke);
    const proc_smoke_step = b.step("proc-smoke-run", "Run the subprocess bridge smoke");
    proc_smoke_step.dependOn(&proc_smoke_run.step);

    // sqlite 服务桥 smoke（open/exec/run/all/close）
    const sqb_smoke = b.addExecutable(.{
        .name = "sqlite-bridge-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlite_bridge_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqb_smoke.root_module.link_libc = true;
    sqb_smoke.root_module.addIncludePath(quickjs_include);
    sqb_smoke.root_module.addIncludePath(b.path("vendor/sqlite"));
    sqb_smoke.root_module.addIncludePath(b.path("src"));
    sqb_smoke.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/quickjs-ng/dtoa.c",
            "vendor/quickjs-ng/libregexp.c",
            "vendor/quickjs-ng/libunicode.c",
            "vendor/quickjs-ng/quickjs.c",
            "vendor/sqlite/sqlite3.c",
            "src/sqlite_wrap.c",
            "src/hash_wrap.c",
        },
        .flags = &.{ "-DCONFIG_VERSION=\"ng\"", "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_DEPRECATED", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_OMIT_PROGRESS_CALLBACK", "-DSQLITE_OMIT_GET_TABLE", "-DSQLITE_OMIT_DECLTYPE", "-DSQLITE_OMIT_UTF16", "-DSQLITE_OMIT_JSON", "-DSQLITE_ENABLE_FTS5", "-O2", "-g" },
    });
    const sqb_smoke_run = b.addRunArtifact(sqb_smoke);
    const sqb_smoke_step = b.step("sqlite-bridge-smoke-run", "Run the sqlite service bridge smoke");
    sqb_smoke_step.dependOn(&sqb_smoke_run.step);
}
