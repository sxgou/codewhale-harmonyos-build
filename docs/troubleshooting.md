# 常见问题排查

## 编译错误

### "can't find crate for `core`"

**原因**: `aarch64-unknown-linux-musl` 目标的 Rust 标准库未安装。

**解决**: 从 Rust 官方发行版下载 musl 标准库并安装到 sysroot：

```bash
curl -sL "https://static.rust-lang.org/dist/rust-std-1.95.0-aarch64-unknown-linux-musl.tar.gz" \
  -o /tmp/rust-std-musl.tar.gz
cd "$(rustc --print sysroot)/lib/rustlib"
tar xzf /tmp/rust-std-musl.tar.gz --strip-components=3 \
  "rust-std-1.95.0-aarch64-unknown-linux-musl/rust-std-aarch64-unknown-linux-musl/lib/rustlib"
```

如果使用 `rustup`（VM 方案），可以直接：

```bash
rustup target add aarch64-unknown-linux-musl
```

### "SSL_get0_group_name: symbol not found"

**原因**: brew 安装的 cargo 需要 OpenSSL 运行时库，但动态链接器找不到。

**解决**: 设置 `LD_LIBRARY_PATH` 指向 OpenSSL 库目录：

```bash
export LD_LIBRARY_PATH="/storage/Users/currentUser/.harmonybrew/Cellar/openssl@3/3.6.2/lib"
```

### "sys/types.h: file not found" 或 "stdlib.h: file not found"

**原因**: OHOS SDK 的 clang 使用 `--target=aarch64-unknown-linux-musl` 时找不到系统头文件。SDK 中的头文件目录以 `aarch64-linux-ohos` 命名，与 musl 目标三元组不匹配。

**解决**: 使用 `ohos-clang-wrapper.sh` 将目标三元组从 `aarch64-unknown-linux-musl` 转换为 `aarch64-linux-ohos`，使 clang 能定位到 SDK 中的 musl 系统头文件。

### "unable to find library -lgcc_s"

**原因**: Rust 的 musl 目标在链接时传入 `-lgcc_s`，但 OHOS SDK 使用 LLVM 工具链，不包含 libgcc_s。

**解决**: clang wrapper 脚本自动将 `-lgcc_s` 替换为 `-lclang_rt.builtins`。如果手动编译，使用：

```bash
-lclang_rt.builtins
```

### "undefined reference to `_Unwind_Resume`" 或 "undefined reference to `_Unwind_*`"

**原因**: compiler-rt builtins 不提供 DWARF 异常展开符号。

**解决**: 除 `-lclang_rt.builtins` 外，还需链接 `-lunwind`（来自 OHOS SDK 的 LLVM libunwind）：

```bash
-lclang_rt.builtins -lunwind
```

clang wrapper 脚本已包含此修复。

### "undefined symbol: posix_spawn_file_actions_addchdir_np"

**原因**: OHOS SDK 的 libc.so 是基于 musl 的裁剪版，不包含此 glibc 扩展符号。Rust 标准库在编译时引用了此符号。

**解决**: 编译并链接 `libohos_stubs.a` 补齐库。该库提供空实现（返回 ENOSYS），不影响主流程。

### "undefined symbol: __xpg_strerror_r"

**原因**: 同上，OHOS SDK 的 libc.so 不包含此符号。Rust 标准库在编译时引用了它。

**解决**: 编译并链接 `libohos_stubs.a`。该库直接转发到 `strerror_r`（musl 的 strerror_r 本身就是 XSI 兼容的）。

### "undefined symbol: BACKTRACE_*" 或 backtrace 相关错误

**原因**: Rust 的 backtrace crate 使用了某些 libc 中不存在的符号。

**解决**: 在 `Cargo.toml` 中设置 backtrace 相关 feature：

```toml
[dependencies]
backtrace = { version = "0.3", features = [], default-features = false }
```

或在代码中禁用 backtrace：

```rust
std::env::set_var("RUST_BACKTRACE", "0");
```

## 运行时问题

### "Permission denied"（即使加了可执行权限）

**hmdfs 限制**: HarmonyOS 的分布式文件系统 hmdfs **只允许动态链接的 PIE 二进制执行**。静态链接的 ELF 即使权限和 SELinux 上下文正确，也会返回 "Permission denied"。

**解决**: 构建时必须使用 `-C target-feature=-crt-static` 关闭静态 CRT 链接。验证方法：

```bash
readelf -h binary | grep Type:
# 必须是: DYN (Shared object file) 而非 EXEC (Executable file)
readelf -l binary | grep interpreter
# 必须有: [Requesting program interpreter: /lib/ld-musl-aarch64.so.1]
```

### "Operation not permitted" 在访问某些文件时

**原因**: hmdfs 的安全隔离机制。某些文件系统操作（如创建硬链接、修改 security.isolate xattr）可能被限制。

**解决**: 将可执行文件放在非 hmdfs 路径（如 `/data/local/tmp`）或通过 `/sdcard/Android/data/` 路径访问。hmdfs 中的文件的 security.isolate xattr 需要设为 `\x03`。

### Binary 在 llvm-strip 后无法执行

**原因**: `llvm-strip` 在 hmdfs 上原地修改 ELF 文件时，可能会改变文件的 inode 或 xattr，导致安全隔离上下文被破坏。

**解决**: 不要对 hmdfs 上的二进制进行 strip 操作。如果必须减小体积，在构建阶段（非 hmdfs 路径）进行 strip，然后复制到 hmdfs：

```bash
# 在构建目录（非 hmdfs）strip
llvm-strip target/release/codewhale-tui
# 然后再复制到 hmdfs
cp target/release/codewhale-tui /hmdfs/path/
```

### 程序启动时报 "cannot open shared object file"

**原因**: 动态链接器找不到所需的共享库。

**解决**: 检查 `readelf -d binary | grep NEEDED` 确认所需的库，然后设置：

```bash
export LD_LIBRARY_PATH="/path/to/libs:$LD_LIBRARY_PATH"
```

对于 OpenSSL，常见路径是：

```bash
export LD_LIBRARY_PATH="/storage/Users/currentUser/.harmonybrew/Cellar/openssl@3/3.6.2/lib"
```

## OHOS SDK 问题

### clang 报告 "no such file or directory" 但文件确实存在

**原因**: OHOS SDK 26 的 clang 可能通过路径模式匹配查找头文件，与目标三元组严格绑定。使用 `--target=aarch64-unknown-linux-musl` 时，clang 搜索的路径模式是 `.../aarch64-unknown-linux-musl/...`，但 SDK 中只有 `.../aarch64-linux-ohos/...`。

**解决**: 必须将目标三元组替换为 `aarch64-linux-ohos`。这由 clang wrapper 脚本自动完成。

### 找不到 `clang_rt.builtins`

**原因**: compiler-rt 库的路径可能因 SDK 版本不同而变化。

**解决**: 查找正确的路径：

```bash
find /storage/Users/currentUser/.harmonybrew/Cellar/ohos-sdk -name "*clang_rt*" 2>/dev/null
```

然后更新 clang wrapper 脚本中的 `LLVM_LIB` 变量。

### ar 命令失败

**原因**: OHOS SDK 的 LLVM 工具链中的 `llvm-ar` 可能需要额外的参数。

**解决**: 使用系统自带的 `ar` 或指定格式：

```bash
ar rcs libohos_stubs.a ohos-libc-stubs.o
```

如果 `ar` 不支持，使用 LLVM 的 ar：

```bash
llvm-ar rcs libohos_stubs.a ohos-libc-stubs.o
```

## 网络/构建环境

### cargo 下载依赖超时

**原因**: HarmonyOS 设备上的网络可能较慢或不稳定。

**解决**: 配置 cargo 使用镜像源（在 `~/.cargo/config.toml` 中）：

```toml
[source.crates-io]
replace-with = "rsproxy"

[source.rsproxy]
registry = "https://rsproxy.cn/crates.io-index"

[registries.rsproxy]
index = "https://rsproxy.cn/crates.io-index"

[source.rustcc]
registry = "https://code.aliyun.com/rustcc/crates.io-index.git"
```

### 链接阶段内存不足

**原因**: HarmonyOS 设备可能内存有限，链接大型 Rust 项目时可能 OOM。

**解决**: 限制并行链接单元数：

```bash
export CARGO_BUILD_JOBS=1
# 或者使用薄 LTO 减少内存
export RUSTFLAGS="$RUSTFLAGS -C lto=thin"
```

## VM 交叉编译

### OHOS note 未嵌入二进制

**原因**: OHOS note 对象文件未正确链接。

**解决**: 确保 `ohos_note.o` 路径正确，并在 RUSTFLAGS 中使用 `-C link-arg=` 传递。验证：

```bash
readelf -n codewhale-tui | grep ohos
```

### VM 中无法执行生成的二进制

**正常现象**: 二进制是为 aarch64 目标编译的，无法在 x86_64 VM 中直接运行。使用 `readelf` 验证类型即可。将二进制复制到 HarmonyOS 设备后执行。
