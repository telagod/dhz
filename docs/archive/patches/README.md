# patches/ — 迁移补丁集（apply 到 deepseek-harness 仓库）

| 补丁 | 里程碑 | 内容 | 状态 |
|---|---|---|---|
| [m0-host-module-loader.patch](m0-host-module-loader.patch) | M-0 | 插件加载 seam 解耦：`HostModuleLoader` 接口 + Node 适配器（NodeHostModuleLoader），tree.import 只走 `loader.host`；`internal.import` 降级为适配器内部路径；新增单测 host-loader.spec.ts | ✅ 已验证可干净应用（base b150a55） |

## 验证手段

```bash
git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git /tmp/dsh-repo
cd /tmp/dsh-repo && git apply --check <此目录>/m0-host-module-loader.patch   # 应输出 CHECK OK 级别的空输出（零错误）
git apply <此目录>/m0-host-module-loader.patch
pnpm install && pnpm --filter @deepseek-ai/cordis-plugin-loader test   # 全量套件回归
```

## M-0 语义（防误解）

- `tree.ts` 只依赖 `loader.host`（接口）；Node 版行为 100% 不变（适配器内部仍走 `internal.import`）。
- 未来 Zig 宿主：提供 `HostModuleLoader`（quickjs-ng module linker），**无需再改 tree.ts / entry.ts**。
- `loader.internal` 字段保留（诊断与适配器使用），但不再是插件树的直接依赖。
