/* SHA-256 薄包装头（Zig 侧 @cInclude） */
#ifndef DSH_HASH_WRAP_H
#define DSH_HASH_WRAP_H
#include <stddef.h>
#include <stdint.h>
void dsh_sha256(const uint8_t *in, size_t len, uint8_t out[32]);
#endif
void dsh_sha1(const uint8_t *in, size_t len, uint8_t out[20]);
