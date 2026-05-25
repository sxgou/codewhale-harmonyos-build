# CodeWhale HarmonyOS 原生构建指南

将 [CodeWhale](https://github.com/Hmbown/CodeWhale)（终端原生 TUI/CLI DeepSeek 客户端）在 HarmonyOS 上原生编译运行的完整教程。

## 背景

HarmonyOS 使用 **musl libc**，但其 SDK 中的 libc.so 是经过裁剪的版本，缺少部分 musl 标准 API（如 `posix_spawn_file_actions_addchdir_np`、`__xpg_strerror_r`）。同时 HarmonyOS 的 **hmdfs** 分布式文件系统**只允许动态链接的 PIE 二进制执行**，静态链接的二进制会返回 "Permission denied"。

本教程采用 **`aarch64-unknown-linux-musl` Rust 目标** + **OHOS SDK clang 链接器** 的方案，解决了上述所有问题。

## 快速开始

### 前置条件

- HarmonyOS 设备（ARM64）
- [harmonybrew](https://github.com/Harmonybrew/homebrew-harmony)（Homebrew for HarmonyOS）
- Rust 1.95+（通过 brew 安装）
- OHOS SDK 26+

### 步骤 1：安装依赖

```bash
# 安装 Rust
brew install rust

# 安装 OHOS SDK（包含 clang 链接器、系统头文件、libc）
brew install ohos-sdk

# 安装 LLVM GCC 兼容层
brew install llvm-gcc-compat

# 安装 musl target 标准库（从 Rust 官方下载）
curl -sL "https://static.rust-lang.org/dist/rust-std-1.95.0-aarch64-unknown-linux-musl.tar.gz" \
  -o /tmp/rust-std-musl.tar.gz
cd "$(rustc --print sysroot)/lib/rustlib"
tar xzf /tmp/rust-std-musl.tar.gz --strip-components=3 \
  "rust-std-1.95.0-aarch64-unknown-linux-musl/rust-std-aarch64-unknown-linux-musl/lib/rustlib"
```

### 步骤 2：配置构建工具链

```bash
# 克隆 CodeWhale
git clone --depth 1 https://github.com/Hmbown/CodeWhale.git
cd CodeWhale

# 复制本项目的工具链文件
cp /path/to/codewhale-harmonyos-build/patches/ohos-clang-wrapper.sh .
cp /path/to/codewhale-harmonyos-build/patches/ohos-libc-stubs.c .

# 编译 libc 补齐库（静态库）
CLANG="/storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk/26.0.0.18/bin/clang"
$CLANG --target=aarch64-linux-ohos -c ohos-libc-stubs.c -o ohos-libc-stubs.o
ar rcs libohos_stubs.a ohos-libc-stubs.o
```

### 步骤 3：构建

```bash
# 设置环境变量并构建
LD_LIBRARY_PATH="/storage/Users/currentUser/.harmonybrew/Cellar/openssl@3/3.6.2/lib" \
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="./ohos-clang-wrapper.sh" \
CC_aarch64_unknown_linux_musl="./ohos-clang-wrapper.sh" \
RUSTFLAGS="-C target-feature=-crt-static" \
cargo build --target aarch64-unknown-linux-musl --release -p codewhale-tui
```

### 步骤 4：验证并运行

```bash
# 验证二进制属性
readelf -h target/aarch64-unknown-linux-musl/release/codewhale-tui | grep Type:
# 应输出: DYN (Shared object file) — 即 PIE

readelf -l target/aarch64-unknown-linux-musl/release/codewhale-tui | grep interpreter
# 应输出: [Requesting program interpreter: /lib/ld-musl-aarch64.so.1]

# 运行
./target/aarch64-unknown-linux-musl/release/codewhale-tui --help
```

## 方案详解

### 为什么选择 `aarch64-unknown-linux-musl` 而非 `aarch64-unknown-linux-ohos`？

| 目标 | 优点 | 缺点 |
|---|---|---|
| `aarch64-unknown-linux-musl` | libc crate 定义完整，nix/mio 等依赖可编译 | Rust std lib 期望的 glibc 扩展符号需补齐 |
| `aarch64-unknown-linux-ohos` | 原生 OHOS 支持 | libc crate 定义不完整，nix 0.25.1 等旧版库无法编译 |

### 核心组件

#### 1. Clang 包装脚本 (`patches/ohos-clang-wrapper.sh`)

解决三个关键问题：

- **目标三元组转换**: Rust 传给链接器的 `--target=aarch64-unknown-linux-musl` 在 OHOS SDK 的 clang 中找不到系统头文件，转换为 `--target=aarch64-linux-ohos` 即可使用 SDK 中的 musl 头文件。
- **libgcc_s 替代**: Rust 的 musl 目标会在链接时传入 `-lgcc_s`，但 OHOS SDK 使用 LLVM 工具链，没有 libgcc_s。脚本将其映射为 `-lclang_rt.builtins -lunwind`。
- **libc 符号补齐**: 静态链接 `libohos_stubs.a` 提供 Rust std lib 所需的缺失符号。

#### 2. Libc 补齐库 (`patches/ohos-libc-stubs.c`)

Rust 的 `aarch64-unknown-linux-musl` 标准库在编译时引用了两个在 OHOS SDK libc 中不存在的符号：

| 符号 | 用途 | 补齐方案 |
|---|---|---|
| `posix_spawn_file_actions_addchdir_np` | 子进程设置工作目录（glibc 扩展） | 返回 ENOSYS（不影响主流程） |
| `__xpg_strerror_r` | XSI 兼容的错误信息函数 | 直接转发到 `strerror_r` |

### 关于 hmdfs

HarmonyOS 的分布式文件系统 hmdfs 有以下限制：
- **静态链接的 ELF 无法执行**（Permission denied），即使权限和 SELinux 上下文正确
- **必须有 INTERP 段**（动态链接器路径），如 `/lib/ld-musl-aarch64.so.1`
- **security.isolate xattr** 需要为 `\x03`（已存在于 `.harmonybrew/bin/` 中的文件）

因此 `-C target-feature=-crt-static`（关闭 musl 目标的静态 CRT 链接）是必选项。

## 目录结构

```
codewhale-harmonyos-build/
├── README.md                    # 本教程
├── scripts/
│   ├── build-native.sh          # 原生 OHOS 构建脚本（自动化）
│   └── build-vm.sh              # 备选：在 openEuler VM 中交叉编译
├── patches/
│   ├── ohos-clang-wrapper.sh    # Clang 目标转换 + 链接修复包装脚本
│   └── ohos-libc-stubs.c        # Libc 缺失符号静态补齐库源码
└── docs/
    └── troubleshooting.md       # 常见问题排查
```

## 备选方案：VM 交叉编译

如果你更倾向于在 x86_64 Linux 虚拟机中交叉编译，参见 `scripts/build-vm.sh`。该方案通过 openEuler VM + `loh` 工具与宿主机共享文件。

关键区别：
- VM 方案需要手动嵌入 OHOS note（`ohos_note.o`）
- VM 方案的 musl target 标准库通过 rustup 安装
- VM 方案同样需要 `-C target-feature=-crt-static`

## 相关资源

- [CodeWhale](https://github.com/Hmbown/CodeWhale) - 终端原生 TUI/CLI DeepSeek 客户端
- [harmonybrew](https://github.com/Harmonybrew/homebrew-harmony) - HarmonyOS Homebrew 移植
- [Rust musl targets](https://doc.rust-lang.org/rustc/platform-support.html)

## License

MIT
