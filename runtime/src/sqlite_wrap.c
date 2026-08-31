/* sqlite3_column_text 的 plain-C 包装：隔离 zig cimport 对该指针传递的干扰。 */
#include <stddef.h>
#include "sqlite3.h"

const unsigned char *dsh_col_text(sqlite3_stmt *stmt, int col) {
    return sqlite3_column_text(stmt, col);
}
const char *dsh_col_name(sqlite3_stmt *stmt, int col) {
    const char *name = sqlite3_column_name(stmt, col);
    return name ? name : "";
}
int dsh_col_bytes(sqlite3_stmt *stmt, int col) {
    return sqlite3_column_bytes(stmt, col);
}
