/* landlock 沙箱边界（C）—— 子进程（fork 后 execvp 前）套用。
 * v1 策略语义：
 *   read_only        —— 全盘只读（写授权空集）
 *   workspace_write  —— 全盘只读 + 写授权 { work_root, /tmp }
 *   danger(不调用)    —— 不套沙箱（部署显式选择）
 * fail-closed：规则应用失败 → 调用方决定拒绝执行（proc 桥返回 126）。
 * 参照：policy.zig Mode 三态 ↔ 本文件三态。 */
#define _GNU_SOURCE
#include <linux/landlock.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>

#define LL_HANDLED (LANDLOCK_ACCESS_FS_EXECUTE | \
    LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_READ_FILE | \
    LANDLOCK_ACCESS_FS_READ_DIR | LANDLOCK_ACCESS_FS_REMOVE_DIR | \
    LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR | \
    LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG | \
    LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO | \
    LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM | \
    LANDLOCK_ACCESS_FS_TRUNCATE)

#define LL_READ  (LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)
#define LL_WRITE (LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR | \
    LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR | \
    LANDLOCK_ACCESS_FS_MAKE_DIR | LANDLOCK_ACCESS_FS_MAKE_REG | \
    LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO | \
    LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM | \
    LANDLOCK_ACCESS_FS_TRUNCATE)

static int ll_add_path(int ruleset_fd, const char *path, __u64 access) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return -1; /* fail-closed：路径不可开 → 规则失败 */
    struct landlock_path_beneath_attr pba;
    pba.allowed_access = access;
    pba.parent_fd = fd;
    int rc = (int)syscall(SYS_landlock_add_rule, ruleset_fd,
                          LANDLOCK_RULE_PATH_BENEATH, &pba, 0);
    close(fd);
    return rc;
}

/* mode: 0=read_only（写空集） 1=workspace_write（写 work_root+/tmp） 2=danger（调用方应跳过） */
int dsh_landlock_apply(const char *work_root, int mode) {
    /* landlock 前置要求：禁止提权后再套规则（无特权进程即可设置）；
       缺失则 restrict_self 报 EPERM（纯 C 复现定案）。 */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    /* C99 指定初始化器：其余字段（含 handled_access_net）零——漏初始化则 EINVAL（strace 定案） */
    struct landlock_ruleset_attr attr = { .handled_access_fs = LL_HANDLED };
    long fd = syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
    if (fd < 0) return -1;
    /* 读授权：全盘读（v1 简化——写才是边界；读拦截属 v2） */
    if (ll_add_path((int)fd, "/", LL_READ | LANDLOCK_ACCESS_FS_EXECUTE) != 0) { close((int)fd); return -1; }
    /* 写授权：workspace_write = work_root + /tmp（read_only 不授权任何写） */
    if (mode == 1) {
        if (work_root == NULL || work_root[0] == '\0') { close((int)fd); return -1; }
        if (ll_add_path((int)fd, work_root, LL_WRITE) != 0) { close((int)fd); return -1; }
        if (ll_add_path((int)fd, "/tmp", LL_WRITE) != 0) { close((int)fd); return -1; }
    }
    if (syscall(SYS_landlock_restrict_self, fd, 0) != 0) { close((int)fd); return -1; }
    close((int)fd);
    return 0;
}
