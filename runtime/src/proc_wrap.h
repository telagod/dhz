/* 子进程薄包装头（Zig 侧 @cInclude） */
#ifndef DSH_PROC_WRAP_H
#define DSH_PROC_WRAP_H
#include <stddef.h>
int dsh_proc_run(const char *const argv[], char *out, size_t out_cap,
                 size_t *out_len, int *code,
                 const char *work_root, int mode);
#endif

/* 异步 spawn：fork+setsid+3 管道+execvp；stdin_fd=host 写端；stdout/stderr=host 读端；
   envp：子进程环境（"K=V" 数组 NULL 结尾；NULL=继承宿主）；
   work_root+mode：landlock 沙箱（与 dsh_proc_run 同语义；2=danger 跳过） */
int dsh_proc_spawn(const char *const argv[], const char *const envp[],
                   int *stdin_fd, int *stdout_fd, int *stderr_fd, int *pid_out,
                   const char *work_root, int mode);
void dsh_proc_terminate(int pid);
/* 终止升级链：TERM（进程组）→ KILL（进程组，不可忽略） */
void dsh_proc_kill(int pid);
/* 非阻塞 waitpid：返回 0=运行中 / 1=已退出（raw_status 填原生 status）/ -1=错误 */
int dsh_proc_wait(int pid, int *raw_status);
