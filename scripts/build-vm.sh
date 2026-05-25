#!/bin/bash
# CodeWhale VM 交叉编译脚本
#
# 在 openEuler VM（x86_64）中交叉编译 codewhale-tui，
# 通过 loh 共享目录与 HarmonyOS 宿主机交换文件。
#
# 前置条件（VM 内）:
#   - Rust 工具链（rustup）
#   - aarch64-unknown-linux-musl target（rustup target add）
#   - aarch64-linux-gnu 交叉编译工具链
#   - OHOS note 对象文件（ohos_note.o）放在共享目录
#
# 使用方法（在 VM 内执行）:
#   bash /mnt/linux_share/build-vm.sh
#
# 输出:
#   共享目录中的 codewhale-tui-musl-pie（含 OHOS note 的 PIE 二进制）

set -euo pipefail

SHARE="/mnt/linux_share"
BUILD_DIR="$HOME/CodeWhale-musl-build"
OHOS_NOTE_O="$SHARE/ohos_note.o"
OUTPUT_DIR="$SHARE"

TARGET="aarch64-unknown-linux-musl"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Step 1: Prerequisites
log "Step 1: Checking prerequisites..."

if [ ! -f "$OHOS_NOTE_O" ]; then
    err "ohos_note.o not found at $OHOS_NOTE_O"
    err "Place the OHOS note object file in the shared directory first"
    exit 1
fi
log "ohos_note.o found ✓"

if ! rustup target list --installed 2>/dev/null | grep -q "$TARGET"; then
    log "Installing Rust target $TARGET..."
    rustup target add "$TARGET"
fi
log "Rust target $TARGET ✓"
log "Rust: $(rustc --version)"

# Step 2: Clone CodeWhale
log "Step 2: Setting up CodeWhale source..."

if [ -d "$BUILD_DIR" ]; then
    log "Build directory exists, updating..."
    cd "$BUILD_DIR"
    git fetch --all 2>/dev/null || warn "git fetch failed, continuing..."
else
    log "Cloning CodeWhale..."
    git clone --depth 1 https://github.com/Hmbown/CodeWhale.git "$BUILD_DIR"
    cd "$BUILD_DIR"
fi

if [ ! -f "$BUILD_DIR/Cargo.toml" ]; then
    err "CodeWhale source not found"
    exit 1
fi
log "CodeWhale source ready ✓"

# Step 3: Patch keyring dependency
log "Step 3: Patching keyring dependency..."

SECRETS_TOML="$BUILD_DIR/crates/secrets/Cargo.toml"
SECRETS_LIB="$BUILD_DIR/crates/secrets/src/lib.rs"

cp "$SECRETS_TOML" "$SECRETS_TOML.bak.$$"
cp "$SECRETS_LIB" "$SECRETS_LIB.bak.$$"

sed -i '/keyring/d' "$SECRETS_TOML"

# musl target 的 target_os 仍然是 "linux"，原始 cfg gate 无法排除 keyring 代码
sed -i 's/any(target_os = "macos", target_os = "windows", target_os = "linux")/FALSE/g' "$SECRETS_LIB"

log "Keyring dependency patched ✓"

# Step 4: Build
log "Step 4: Building codewhale-tui with $TARGET target..."

cd "$BUILD_DIR"

# HarmonyOS hmdfs 拒绝执行静态链接的二进制。
# -C target-feature=-crt-static: 关闭 musl target 默认的静态 CRT 链接
# -C link-arg=-pie: 确保输出为 PIE (ET_DYN)
# 通过 OHOS note 对象嵌入 HarmonyOS 平台标识
RUSTFLAGS="-C link-arg=$OHOS_NOTE_O -C target-feature=-crt-static -C link-arg=-pie" \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C link-arg=$OHOS_NOTE_O -C target-feature=-crt-static -C link-arg=-pie" \
cargo build --target "$TARGET" --release -p codewhale-tui 2>&1

log "Build completed ✓"

# Step 5: Verify
log "Step 5: Verifying binary..."
BINARY="$BUILD_DIR/target/$TARGET/release/codewhale-tui"

if [ ! -f "$BINARY" ]; then
    err "Binary not found at $BINARY"
    ls "$BUILD_DIR/target/$TARGET/release/" 2>/dev/null || true
    exit 1
fi

BINARY_SIZE=$(stat -c%s "$BINARY" 2>/dev/null || stat -f%z "$BINARY" 2>/dev/null)
log "Binary size: $BINARY_SIZE bytes"

ELFTYPE=$(readelf -h "$BINARY" 2>/dev/null | grep "Type:" | head -1)
log "ELF type: $ELFTYPE"

if readelf -n "$BINARY" 2>/dev/null | grep -q "ohos"; then
    log "OHOS note found ✓"
else
    warn "OHOS note NOT found"
    readelf -S "$BINARY" 2>/dev/null | grep -i note || true
fi

INTERP=$(readelf -l "$BINARY" 2>/dev/null | grep "interpreter" || echo "static")
log "Interpreter: $INTERP"

NEEDED=$(readelf -d "$BINARY" 2>/dev/null | grep "NEEDED" || echo "none (static)")
log "NEEDED libraries:"
echo "$NEEDED"

# Step 6: Copy output
log "Step 6: Copying binary to shared directory..."
cp "$BINARY" "$OUTPUT_DIR/codewhale-tui-musl-pie"
log "Binary copied to $OUTPUT_DIR/codewhale-tui-musl-pie ✓"

echo ""
log "=== BUILD COMPLETE ==="
echo "  Binary: $SHARE/codewhale-tui-musl-pie"
echo "  Size: $BINARY_SIZE bytes"
echo "  Type: $ELFTYPE"
echo ""
echo "Next step: test execution on HarmonyOS host"
