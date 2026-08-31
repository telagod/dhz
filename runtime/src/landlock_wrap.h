/* landlock 薄包装头（Zig 侧 @cInclude） */
#ifndef DSH_LANDLOCK_WRAP_H
#define DSH_LANDLOCK_WRAP_H
/* mode: 0=read_only 1=workspace_write 2=danger（不调用） */
int dsh_landlock_apply(const char *work_root, int mode);
#endif
