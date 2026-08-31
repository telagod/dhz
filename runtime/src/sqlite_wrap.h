#ifndef DSH_SQLITE_WRAP_H
#define DSH_SQLITE_WRAP_H
typedef struct sqlite3_stmt sqlite3_stmt;
const unsigned char *dsh_col_text(sqlite3_stmt *stmt, int col);
const char *dsh_col_name(sqlite3_stmt *stmt, int col);
int dsh_col_bytes(sqlite3_stmt *stmt, int col);
#endif
