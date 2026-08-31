/* 子进程薄包装（C）—— fork/execvp/pipe/waitpid，POSIX 阻塞语义。
 * 确定性 23 行 vs 0.16 进程 API 学习（std.Io 深水区规则）。
 * 一次性同步执行：argv[] + 捕获 stdout（上限 out_cap）+ 退出码。 */
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include "landlock_wrap.h"

/* mode: 0=read_only 1=workspace_write 2=danger（跳过沙箱） */
int dsh_proc_run(const char *const argv[], char *out, size_t out_cap,
                 size_t *out_len, int *code,
                 const char *work_root, int mode) {
    int pfd[2];
    if (pipe(pfd) < 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pfd[0]); close(pfd[1]); return -1; }
    if (pid == 0) {
        /* child */
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);
        /* stderr 不捕获（合并由调用方定；v1 只收 stdout） */
        if (mode != 2) {
            /* 沙箱应用失败 → 拒绝执行（fail-closed，126=许可错误） */
            if (dsh_landlock_apply(work_root, mode) != 0) _exit(126);
        }
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    /* parent：读至 EOF */
    close(pfd[1]);
    size_t used = 0;
    while (used < out_cap) {
        ssize_t n = read(pfd[0], out + used, out_cap - used);
        if (n <= 0) break;
        used += (size_t)n;
    }
    close(pfd[0]);
    int status = 0;
    waitpid(pid, &status, 0) ;
    int rc = -1;
    if (WIFEXITED(status)) rc = WEXITSTATUS(status);
    *out_len = used;
    *code = rc;
    return 0;
}

/* 异步 spawn（M-7 基元）：fork + setsid（进程组）+ 3 管道 + execvp。
   宿主侧：stdin_fd=写端、stdout_fd/stderr_fd=读端；pid_out=子进程 pid。
   envp：子进程环境（"K=V" 数组，NULL 结尾；NULL=继承宿主 environ）。
   沙箱：work_root+mode 与 dsh_proc_run 同语义（0=read_only 1=workspace_write 2=danger 跳过）；
   返回 0 成功；-1 spawn 失败（子进程已清理）。 */
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
extern char **environ;
int dsh_proc_spawn(const char *const argv[], const char *const envp[],
                   int *stdin_fd, int *stdout_fd, int *stderr_fd, int *pid_out,
                   const char *work_root, int mode) {
    int in_pipe[2], out_pipe[2], err_pipe[2];
    if (pipe(in_pipe) != 0) return -1;
    if (pipe(out_pipe) != 0) { close(in_pipe[0]); close(in_pipe[1]); return -1; }
    if (pipe(err_pipe) != 0) { close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]); return -1; }
    pid_t pid = fork();
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]); close(err_pipe[0]); close(err_pipe[1]);
        return -1;
    }
    if (pid == 0) {
        /* child */
        setsid();
        if (envp) environ = (char **)envp; /* 替换子进程环境（scrubbed env 面） */
        dup2(in_pipe[0], 0);
        dup2(out_pipe[1], 1);
        dup2(err_pipe[1], 2);
        close(in_pipe[0]); close(in_pipe[1]); close(out_pipe[0]); close(out_pipe[1]); close(err_pipe[0]); close(err_pipe[1]);
        /* 进程级沙箱：fork 后 exec 前套用（fail-closed——126=许可错误） */
        if (mode != 2) {
            if (dsh_landlock_apply(work_root, mode) != 0) _exit(126);
        }
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    /* parent */
    close(in_pipe[0]); close(out_pipe[1]); close(err_pipe[1]);
    *stdin_fd = in_pipe[1];
    *stdout_fd = out_pipe[0];
    *stderr_fd = err_pipe[0];
    *pid_out = (int)pid;
    return 0;
}

void dsh_proc_terminate(int pid) {
    if (pid > 0) kill(-pid, SIGTERM); /* 进程组（setsid 后 pid=组长） */
}

/* 升级链第二级：SIGKILL 进程组（不可忽略——终止顽固子进程） */
void dsh_proc_kill(int pid) {
    if (pid > 0) kill(-pid, SIGKILL);
}

/* 非阻塞 waitpid（done promise 轮询基元）：
   返回 0=仍在运行 / 1=已退出（raw_status 填原生 status——WIFSIGNALED 等语义由调用方位解析）/ -1=错误 */
int dsh_proc_wait(int pid, int *raw_status) {
    int status = 0;
    pid_t r = waitpid((pid_t)pid, &status, WNOHANG);
    if (r == 0) return 0;
    if (r < 0) return -1;
    if (raw_status) *raw_status = status;
    return 1;
}
