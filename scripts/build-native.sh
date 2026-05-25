#!/bin/sh
# CodeWhale HarmonyOS 原生构建脚本
#
# 在 HarmonyOS 设备上直接构建 codewhale-tui。
# 使用 aarch64-unknown-linux-musl Rust 目标 + OHOS SDK clang 链接器。
#
# 前置条件:
#   - harmonybrew (https://github.com/Harmonybrew/homebrew-harmony)
#   - brew install rust ohos-sdk llvm-gcc-compat
#   - aarch64-unknown-linux-musl Rust std lib 已安装
#   - 本仓库的 patches/ 已复制到 CodeWhale 项目根目录
#
# 使用方法:
#   cd CodeWhale
#   bash /path/to/codewhale-harmonyos-build/scripts/build-native.sh
#
# 环境变量:
#   CODEPATH  - CodeWhale 项目路径（默认: 当前目录）
#   WRAPPER   - clang wrapper 脚本路径（默认: ./ohos-clang-wrapper.sh）
#   OPENSSL   - OpenSSL 库路径

set -euo pipefail

CODEPATH="${CODEPATH:-$(pwd)}"
WRAPPER="${WRAPPER:-$CODEPATH/ohos-clang-wrapper.sh}"
B_REW="/storage/Users/currentUser/.harmonybrew"
OPENSSL_LIB="${OPENSSL_LIB:-$B_REW/Cellar/openssl@3/3.6.2/lib}"

TARGET="aarch64-unknown-linux-musl"
CLANG="$B_REW/Cellar/ohos-sdk/26.0.0.18/bin/clang"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Step 1: Prerequisites
log "Step 1: Checking prerequisites..."

if [ ! -d "$CODEPATH" ] || [ ! -f "$CODEPATH/Cargo.toml" ]; then
    err "CodeWhale project not found at $CODEPATH"
    err "Set CODEPATH or run this script from the CodeWhale project root"
    exit 1
fi
log "CodeWhale source: $CODEPATH ✓"

if [ ! -f "$WRAPPER" ]; then
    err "Clang wrapper not found at $WRAPPER"
    err "Copy patches/ohos-clang-wrapper.sh to the CodeWhale project root first"
    exit 1
fi
log "Clang wrapper: $WRAPPER ✓"

if [ ! -f "$CLANG" ]; then
    err "OHOS SDK clang not found at $CLANG"
    err "Install: brew install ohos-sdk"
    exit 1
fi
log "OHOS SDK clang: $CLANG ✓"

if [ ! -d "$OPENSSL_LIB" ]; then
    warn "OpenSSL library path not found: $OPENSSL_LIB"
    warn "Set OPENSSL_LIB or run: brew install openssl@3"
fi

# Step 2: Check/stub keyring dependency
log "Step 2: Patching keyring dependency..."

SECRETS_TOML="$CODEPATH/crates/secrets/Cargo.toml"
SECRETS_LIB="$CODEPATH/crates/secrets/src/lib.rs"

if grep -q "keyring" "$SECRETS_TOML" 2>/dev/null; then
    log "Removing keyring dependency from Cargo.toml..."
    cp "$SECRETS_TOML" "$SECRETS_TOML.bak"
    sed -i '/keyring/d' "$SECRETS_TOML"
    log "Keyring dependency removed ✓"
else
    log "Keyring dependency already removed ✓"
fi

if grep -q 'target_os.*linux' "$SECRETS_LIB" 2>/dev/null; then
    log "Patching cfg gates in lib.rs..."
    cp "$SECRETS_LIB" "$SECRETS_LIB.bak"
    sed -i 's/any(target_os = "macos", target_os = "windows", target_os = "linux")/FALSE/g' "$SECRETS_LIB"
    log "cfg gates patched ✓"
else
    log "cfg gates already patched ✓"
fi

# Step 3: Compile libc stubs
log "Step 3: Compiling libc stubs..."
STUBS_DIR="$CODEPATH"
STUBS_SRC="$STUBS_DIR/ohos-libc-stubs.c"
STUBS_O="$STUBS_DIR/ohos-libc-stubs.o"
STUBS_A="$STUBS_DIR/libohos_stubs.a"

if [ ! -f "$STUBS_SRC" ]; then
    err "libc stubs source not found at $STUBS_SRC"
    err "Copy patches/ohos-libc-stubs.c to the CodeWhale project root first"
    exit 1
fi

if [ ! -f "$STUBS_A" ]; then
    "$CLANG" --target=aarch64-linux-ohos -c "$STUBS_SRC" -o "$STUBS_O"
    ar rcs "$STUBS_A" "$STUBS_O"
    log "libc stubs compiled and archived ✓"
else
    log "libc stubs already compiled ✓"
fi

# Step 4: Build
log "Step 4: Building codewhale-tui..."

cd "$CODEPATH"

export LD_LIBRARY_PATH="$OPENSSL_LIB"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$WRAPPER"
export CC_aarch64_unknown_linux_musl="$WRAPPER"

RUSTFLAGS="-C target-feature=-crt-static" \
cargo build --target "$TARGET" --release -p codewhale-tui 2>&1

log "Build completed ✓"

# Step 5: Verify
log "Step 5: Verifying binary..."
BINARY="$CODEPATH/target/$TARGET/release/codewhale-tui"

if [ ! -f "$BINARY" ]; then
    err "Binary not found at $BINARY"
    exit 1
fi

BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null)
log "Binary size: $BINARY_SIZE bytes"

ELFTYPE=$(readelf -h "$BINARY" 2>/dev/null | grep "Type:" | head -1)
log "ELF type: $ELFTYPE"

INTERP=$(readelf -l "$BINARY" 2>/dev/null | grep "interpreter" || echo "static")
log "Interpreter: $INTERP"

NEEDED=$(readelf -d "$BINARY" 2>/dev/null | grep "NEEDED" || echo "none (static)")
log "NEEDED libraries:"
echo "$NEEDED"

# Verify it's dynamically linked (PIE)
if echo "$ELFTYPE" | grep -q "DYN"; then
    log "Binary is PIE (dynamically linked) ✓"
else
    warn "Binary is NOT PIE - may not execute on hmdfs!"
fi

echo ""
log "=== BUILD COMPLETE ==="
echo "  Binary: $BINARY"
echo "  Run: LD_LIBRARY_PATH=$OPENSSL_LIB $BINARY --help"
