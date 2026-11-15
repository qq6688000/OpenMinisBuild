# SeagullPair arm64e 链接与认证重定位核查

**结论：本地 Alpine LLVM/Clang/LLD 19.1.4 不能据此交付可安装的 arm64e RootHide tweak。已证明问题超出 CPU subtype：Mach-O 对象生成会丢失静态认证指针信息，ld64.lld 又不支持真正的认证指针重定位。禁止通过改 Mach-O header、改包架构名或仅替换 linker 宣称 ABI 修复。**

本次只创建此报告和 `/tmp/pair-linker-abi/`、`/tmp/pair-linker-sources/` 等独立探针/证据；没有修改 build.py、PairTweak.m、PairPanel.m 等父工程源码，没有生成或安装 deb。以下均区分本地实测与公开源码核查。

## 1. 本地工具与原 smoke

- `/usr/bin/clang --version`：Alpine clang version 19.1.4。
- `/usr/bin/ld64.lld --version`：LLD 19.1.4。
- SDK：`/opt/theos/sdks/iPhoneOS16.5.sdk`。
- `/opt/theos/toolchain/linux/iphone/bin/` 只有 ar、c++、cc、clang、clang++、ldid、lipo、strip；没有 cctools ld64/ld。
- 该目录 clang 是调用 `/usr/bin/clang` 并传 `-fuse-ld=lld` 的 wrapper，不是独立的 Apple arm64e 工具链。

`python3 build.py --smoke` 原样复现：对象文件 subtype 为 2，最终 dylib subtype 为 0，脚本 fail closed：

```text
BUILD FAILED: abi.dylib: expected genuine arm64e Mach-O type 6; got magic=0xfeedfacf, cpu=0x100000c, subtype=0x0, type=6. No header rewriting is permitted; fix the toolchain.
```

该 smoke 中只有间接调用参数和返回地址签名。反汇编确实有 `pacibsp`、`blraaz`、`retab`，但对象只有 unwind 等普通重定位，没有静态认证函数指针，因此不能验证认证重定位或完整 Apple arm64e ABI。

## 2. 编译器能发出 PAC 指令，但静态认证指针在对象阶段丢失

独立最小源 `pointer.m`：

```c
int target(int x) { return x+1; }
int (*pointer)(int) = target;
int call(int x) { return pointer(x); }
```

使用 build.py 的目标和 PAC flags：

```sh
clang -target arm64e-apple-ios16.1 \
  -isysroot /opt/theos/sdks/iPhoneOS16.5.sdk \
  -fobjc-arc -fblocks -fptrauth-calls -fptrauth-returns \
  -fptrauth-intrinsics -c pointer.m -o pointer.o
```

分别用 `-S -emit-llvm`、`-S`、`-c` 检查，实测链路为：

| 阶段 | 关键输出 |
|---|---|
| LLVM IR | `@pointer = global ptr ptrauth (ptr @target, i32 0), align 8` |
| 汇编 | `_pointer: .quad _target@AUTH(ia,0)` |
| Mach-O 对象 | `__data` offset 0：`ARM64_RELOC_UNSIGNED` 指向 `_target` |
| 调用端 | `blraaz x8` |
| LLD 最终 dylib | `_target = 0x4000`，`_pointer = 0xc000` |
| 最终指针槽 | `__DATA,__data` 的 8 字节为 `00 40 00 00 00 00 00 00`，即裸值 `0x4000` |
| 动态修复 | 普通 rebase：`__DATA __data 0x0000C000 pointer` |

单独将生成的 `.s` 用同一个 clang 重新汇编，也得到 `ARM64_RELOC_UNSIGNED`。所以不是前端没有表达认证：认证要求已进入 IR/汇编，随后 Mach-O 对象生成没有正确保存它。普通 rebase 只表达地址重定位，没有 IA key/discriminator/address-diversity 签名信息，不能满足该 `blraaz` 调用要求。

独立 Objective-C NSObject 子类、一个 `-value` 方法也成功编译链接；其 `__objc_const` 方法实现项为普通 `ARM64_RELOC_UNSIGNED`，输出 subtype 仍是 0。这一检查说明“ObjC 编译/链接成功”也不是认证 ABI 证明。此处不将所有 ObjC 普通指针一概视为错误，因为各 metadata 字段有各自运行时处理规则；上面的全局函数指针已足以证明具体不匹配。

## 3. LLD 对真正认证重定位的直接测试失败

为隔离编译器问题，复制独立 `pointer.o` 创建输入测试夹具：保留 Mach-O header 不变，仅把 `__data` 唯一 external、8-byte、non-PC-relative relocation 的类型从 0 改为 **11 (`ARM64_RELOC_AUTHENTICATED_POINTER`)**，并把该指针槽写为 `0x8000000000000000`。

该编码含 authenticated bit63=1、IA key=0、diversity=0、address diversity=0、addend=0，符合 Apple/cctools 认证重定位输入格式。这是生成有效格式的测试输入，不是改写交付 dylib、伪造 arm64e header；未对生产文件应用。

```sh
ld64.lld -dylib -arch arm64e -platform_version ios 16.1 16.5 \
  -syslibroot /opt/theos/sdks/iPhoneOS16.5.sdk \
  -o auth.dylib auth-pointer.o -lSystem -lobjc
```

本地 exit=1，错误：

```text
ld64.lld: error: INVALID relocation has width 8 bytes, but must be 0 bytes at offset 0 of __DATA,__data in /tmp/pair-linker-abi/auth-pointer.o
```

LLVM 19.1.4 的 llvm-readobj 也把该 relocation type 显示为 `Unknown`，所以此版本检查工具的名字显示不能代替数值格式检查。

匹配版本公开源码支持此结论：

- [LLVM 19.1.4 ARM64.cpp](https://github.com/llvm/llvm-project/blob/llvmorg-19.1.4/lld/MachO/Arch/ARM64.cpp#L54)：`relocAttrsArray` 只有 11 项，即类型 0–10，以 ADDEND 结束；没有类型 11 的认证指针处理。
- 同文件第 181 行明确设置 `cpuSubtype = CPU_SUBTYPE_ARM64_ALL`。
- [LLVM 19.1.4 AArch64MachObjectWriter.cpp](https://github.com/llvm/llvm-project/blob/llvmorg-19.1.4/llvm/lib/Target/AArch64/MCTargetDesc/AArch64MachObjectWriter.cpp)：缺少认证指针 relocation 写出支持，与本地 AUTH 表达式降为普通重定位的结果一致。

**判定：不是“仅 subtype bug、ABI 全部完整”。头部改成 2 既不能补回已丢失的认证元数据，也不能给 LLD 增加认证重定位与相应 dyld fixup 生成能力。**

## 4. Linux 可行的 linker 替代源码与构建路线

可选真实实现：`tpoechtrager/cctools-port` 的 Apple ld64 port。不要仅依赖仓库旧 master README 的版本说明；本次明确检查了现代分支：

- 分支：`1035.1.102-ld64-957.1`。
- 固定 commit：`ef969083aecf77dee1814d6961a06b88af23edef`。
- [该版本 README/依赖与构建说明](https://github.com/tpoechtrager/cctools-port/blob/ef969083aecf77dee1814d6961a06b88af23edef/README.md)。
- [macho_relocatable_file.cpp](https://github.com/tpoechtrager/cctools-port/blob/ef969083aecf77dee1814d6961a06b88af23edef/cctools/ld64/src/ld/parsers/macho_relocatable_file.cpp#L8207)：实际实现 `ARM64_RELOC_AUTHENTICATED_POINTER`，提取 discriminator、address diversity、key，并生成认证 fixup。
- [OutputFile.cpp](https://github.com/tpoechtrager/cctools-port/blob/ef969083aecf77dee1814d6961a06b88af23edef/cctools/ld64/src/ld/OutputFile.cpp#L3105)：`setFixup64e`，认证 bind/rebase 和 `DYLD_CHAINED_PTR_ARM64E_USERLAND24` 写出。
- [HeaderAndLoadCommands.hpp](https://github.com/tpoechtrager/cctools-port/blob/ef969083aecf77dee1814d6961a06b88af23edef/cctools/ld64/src/ld/HeaderAndLoadCommands.hpp#L1707)：传播 arm64e ABI version flags，不能只检查 subtype 的低 24 位。

这是有源码依据的 Linux linker 候选，不是本地已经可用或实测通过的工具。此轮未构建或安装 cctools，没有宣称其产物已通过 iOS 16.1/RootHide 验证。

建议在独立 prefix 构建，保留现有工具链；以下是上游支持的路线，不是已执行通过的构建日志：

1. 准备本机 host C/C++ 构建环境（Clang 10+、支持 C++20 的 C++ 标准库、make/autotools、cmake/ninja）。在 Alpine 还需要 `musl-fts-dev`；本地 apk 仓库存在该包。不要把 Theos 的 iOS cross clang wrapper 当作 host 编译器。
2. 构建并安装 [apple-libdispatch](https://github.com/tpoechtrager/apple-libdispatch/blob/master/INSTALL.md) 到独立 prefix，包含 libdispatch 和 BlocksRuntime；该现代 cctools 分支将其列为必需依赖。
3. 构建 [apple-libtapi](https://github.com/tpoechtrager/apple-libtapi)，SDK 使用 `.tbd`，不能忽略 TAPI。
4. 构建固定版本 cctools。示例在依赖成功安装后执行：

```sh
# 示例独立安装目录；具体依赖的构建选项按各上游 INSTALL.md。
PREFIX_ABI=/opt/cctools-arm64e

git clone https://github.com/tpoechtrager/apple-libtapi.git
cd apple-libtapi
INSTALLPREFIX="$PREFIX_ABI" ./build.sh
./install.sh
cd ..

git clone https://github.com/tpoechtrager/cctools-port.git
cd cctools-port
git checkout ef969083aecf77dee1814d6961a06b88af23edef
cd cctools
CC=/usr/bin/clang CXX=/usr/bin/clang++ ./configure \
  --prefix="$PREFIX_ABI" \
  --target=arm-apple-darwin11 \
  --with-libtapi="$PREFIX_ABI" \
  --with-libdispatch="$PREFIX_ABI" \
  --with-libblocksruntime="$PREFIX_ABI"
make -j2
make install
```

预期 linker 是 `$PREFIX_ABI/bin/arm-apple-darwin11-ld`，用 `-arch arm64e` 选择目标。目标前缀不等于输出架构。安装后先验证工具实际文件和版本、再跑独立 fixture，不能直接覆盖 `/usr/bin/ld64.lld`。可选 LTO/LLVM、xar 等功能不是此非 LTO 最小验证的前置要求；如果 configure 对本机依赖或版本报错，需要解决依赖，不能据此声称安装完成。

**仅构建 cctools linker 还不够。** 本地 clang 的 Mach-O 认证 relocation 写出已经失败；需要匹配当前 Apple arm64e ABI 的 compiler/assembler，例如在 macOS/Xcode 环境用完整 Apple clang + Apple linker 构建，或在 Linux 使用经过同样认证指针与 ABI 版本测试的 Apple LLVM/Clang 工具链（[Apple llvm-project](https://github.com/apple/llvm-project)）。不能假定加三个 `-fptrauth-*` flag 已等同 Apple 的完整 ABI，也不能假定任选上游 LLVM 新版就已解决。macOS/Xcode 原生完整工具链是更直接的交付路线；Linux cctools 是可行的 linker 源码路线，完整编译器集成仍是阻塞项。

## 5. 恢复交付前的验收门槛

- 用真实 compiler/assembler 产生静态认证函数指针对象，检查 type 11 及 key/diversity/address-diversity；不能只依赖人工 fixture。
- 测试本地函数地址与外部函数地址两类，分别验证 authenticated rebase 和 authenticated bind，最终 load commands、chained-pointer format 和认证字段均应与目标 iOS ABI 相符。
- 验证真正 arm64e CPU subtype **及 capability/ABI version 高位**；当前 `build.py` 只检查低 24 位，这不足以证明 iOS 14+ ABI。
- 验证 ObjC method metadata、block invoke/function pointer、构造函数、运行时传入/返回的函数指针等工程实际使用路径；不是看到 PAC 指令就算通过。
- 再检查 RootHide install-name、substrate 依赖路径、包架构/布局、签名，最后在匹配设备和 RootHide 环境验证 dyld 加载及实际调用。签名成功或 dpkg 成功打包均不证明上述 ABI 正确。

现有 smoke 的失败应保留为阻塞。当前没有经过证实可交付的安装包，也没有证据支持 header patch。
