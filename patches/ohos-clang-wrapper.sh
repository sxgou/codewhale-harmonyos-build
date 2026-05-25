#!/bin/sh
# OHOS SDK Clang Wrapper
#
# 用于 HarmonyOS 原生构建 Rust musl 目标二进制。
# 解决以下问题:
#   1. 目标三元组转换: aarch64-unknown-linux-musl -> aarch64-linux-ohos
#      使得 SDK 的 sysroot 能提供正确的 musl 系统头文件
#   2. libgcc_s 替代: 将 -lgcc_s 映射为 -lclang_rt.builtins -lunwind
#      (OHOS 使用 LLVM 工具链，没有 libgcc_s)
#   3. 静态链接 libc 补齐库: 为 OHOS SDK 裁剪版 libc 补充缺失符号
#
# 使用方法:
#   CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="/path/to/ohos-clang-wrapper.sh" \
#   CC_aarch64_unknown_linux_musl="/path/to/ohos-clang-wrapper.sh" \
#   cargo build --target aarch64-unknown-linux-musl

CLANG="/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18/bin/clang"
LLVM_LIB="/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18/native/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos"
STUBS_LIB="/storage/Users/currentUser"
ARGS=""
HAS_LINK_OUTPUT=0

for arg in "$@"; do
    case "$arg" in
        --target=aarch64-unknown-linux-musl)
            ARGS="$ARGS --target=aarch64-linux-ohos"
            ;;
        -lgcc_s)
            ARGS="$ARGS -L$LLVM_LIB -lclang_rt.builtins -lunwind"
            ;;
        -o)
            ARGS="$ARGS $arg"
            HAS_LINK_OUTPUT=1
            ;;
        *)
            ARGS="$ARGS $arg"
            ;;
    esac
done

# 链接阶段静态链接 libc 补齐库
if [ "$HAS_LINK_OUTPUT" = "1" ]; then
    ARGS="$ARGS $STUBS_LIB/libohos_stubs.a"
fi

exec $CLANG $ARGS
