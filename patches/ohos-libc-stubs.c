/* OHOS libc 缺失符号补齐库
 *
 * Rust 的 aarch64-unknown-linux-musl 标准库在编译时引用了
 * 以下符号，但 OHOS SDK 的 libc.so（基于 musl 的裁剪版）
 * 中不包含这些符号。本补齐库以静态库形式链接。
 *
 * 编译:
 *   CLANG=/path/to/ohos-sdk/26.0.0.18/bin/clang
 *   $CLANG --target=aarch64-linux-ohos -c ohos-libc-stubs.c -o ohos-libc-stubs.o
 *   ar rcs libohos_stubs.a ohos-libc-stubs.o
 */

#define _GNU_SOURCE
#include <spawn.h>
#include <string.h>
#include <errno.h>

/**
 * posix_spawn_file_actions_addchdir_np - 设置子进程工作目录
 *
 * glibc 扩展（2.29+），也被较新版本的 musl 支持。
 * OHOS 的 musl 版本不包含此函数。
 *
 * 在 CodeWhale 的流程中，此函数仅用于 spawn 子进程时设置 cwd，
 * 返回 ENOSYS 会使调用方回退到默认行为，不影响主功能。
 */
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *actions,
                                         const char *path) {
    (void)actions;
    (void)path;
    return ENOSYS;
}

/**
 * __xpg_strerror_r - XSI 兼容的错误信息函数
 *
 * glibc 中 strerror_r 有两个版本（GNU 和 XSI），
 * 通过 __xpg_strerror_r 符号提供 XSI 兼容版本。
 * musl 的 strerror_r 始终是 XSI 兼容的，直接转发即可。
 */
int __xpg_strerror_r(int errnum, char *buf, size_t buflen) {
    return strerror_r(errnum, buf, buflen);
}
