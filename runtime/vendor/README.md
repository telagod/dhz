# vendor 出处

- `quickjs-ng/`：https://github.com/quickjs-ng/quickjs @ `2c620e4`（Fix UB in String.prototype.normalize()），已吸收为普通文件（非 submodule）。
  本地补丁：`docs/archive/patches/quickjs-ng-stderr-leak-dump.patch`（leak dump 走 stderr + fflush，避免污染 stdout golden 流；已随文件本体生效）。
- `sqlite/`：sqlite-amalgamation-3530400（SQLite 3.53.4 官方合并源）。

升级方式：下载新版本覆盖后，复核上述补丁是否仍需应用。
