# Apple Xcode 独立构建入口

`build-apple.py` 是独立的 macOS Python 3 入口，不调用或修改 `build.py`，不修改源码、control 或 vendor。默认产物目录为 `dist-apple/`，不替代现有 pipeline。未创建或执行外部 CI，没有上传、下载、安装或付费操作。

## 环境与命令

使用已合法安装、完成首次启动配置的完整 Xcode，且它自带 **iPhoneOS SDK >= 16.1**。部署最低系统固定为 **iOS 16.1**，不要求 SDK 恰好为 16.1；较新 Xcode 可以使用，但必须通过下述真实 ABI 探针。仅 Command Line Tools 不够。在 macOS runner 上可直接使用其已选定的完整 Xcode；如需覆盖，设置 `DEVELOPER_DIR`，例如：

```sh
cd /path/to/seagull-pair
# 可选：覆盖 runner 默认选择，路径以本机实际安装为准
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun --sdk iphoneos --show-sdk-version
python3 build-apple.py --smoke
python3 build-apple.py
```

`--smoke` 不需要 dpkg-deb，也不编译生产源码或生成 deb。完整构建还需要 PATH 中的 `dpkg-deb`，其版本必须支持 `--root-owner-group`；如未安装，由操作者自行安装 dpkg（例如通过其已配置的 Homebrew）。脚本不会自动安装工具。

默认使用 `/usr/bin/codesign --force --sign - --timestamp=none`，并执行 `codesign --verify --strict`。也可以使用已安装的 ldid：

```sh
python3 build-apple.py --signer ldid
python3 build-apple.py --output /path/to/local-artifacts
```

ldid 路线使用 `ldid -Cadhoc -S`，仍要求 macOS codesign 验证通过；不接受只存在签名 load command 的结果。不使用开发者证书或 provisioning profile。

## 拒绝条件与 ABI 检查

- 首先要求 macOS。工具从所选 Xcode 的 `xcrun --sdk iphoneos` 解析，检查 SDK 和工具实际路径在该 Xcode 内、编译器输出包含 `Apple clang version`、链接器输出包含 `PROJECT:ld-`。不接受 LLD。
- 编译实际调用 `xcrun --sdk iphoneos clang -arch arm64e -miphoneos-version-min=16.1 -isysroot <SDK>`，由 Apple 编译器/汇编器产生对象；直接调用同一 Xcode 的真实 Apple ld，使用 `-arch arm64e -platform_version ios 16.1 <实际SDK版本> -fixup_chains`。SDK 版本按数值解析并检查 >= 16.1，不使用字符串比较，也不伪造为 16.1。
- 对象和最终 dylib 均必须是 thin 64-bit ARM Mach-O。分别检查 subtype 低 24 位为 arm64e（2），高 8 位为已支持的版本化 userland ABI version 0（`0x80000000`）；目前组合值仍为 `0x80000002`。这是 ABI 策略，与 SDK 发布版本无关。未版本化 subtype 2、kernel 或未知 ABI/capability 位均拒绝；不能仅为兼容新 Xcode 而放开高位。依据为 Apple `mach/machine.h` 的 ARM64E/PTRAUTH_ABI 定义及链接器的 ABI flags 传播约定；新编码需有格式依据及实际探针证据才可扩展。
- 认证探针使用真实 C 全局函数指针初始化：本地 `local_target` 和外部 `getpid`，显式要求 IA key、零 discriminator、无 address diversity。对象中两个槽都必须有真实 type 11 `ARM64_RELOC_AUTHENTICATED_POINTER`、正确符号和槽内认证信息。任何普通 UNSIGNED 降级都会失败。
- 汇编需包含认证调用与返回指令。链接结果解析 LC_DYLD_CHAINED_FIXUPS，要求 iOS userland arm64e pointer format 9 或 12，沿实际链查找两指针槽，验证 authenticated local rebase 的目标，以及 authenticated external bind 的 import 名称和认证字段。仅有 PAC 指令不算通过。
- 本解析器有意只接受探针所需的有限格式：未压缩符号、import format 1/2、单起点页。未知编码或 multi-start 页会拒绝，不会降级忽略。
- 链接后及签名后再次检查 LC_BUILD_VERSION 的结构长度/tool count、平台 iOS、最低系统恰为 16.1、SDK 恰为本次所选 SDK（且 >= 16.1），以及 dylib 类型、架构与 ABI flags、依赖路径。不是只检查 SDK >= 16.1 就接受任意产物。探针签名后还重复检查认证 chains。
- 显式链接 CoreGraphics、UIKit、Foundation、QuartzCore、libSystem、libobjc 和 vendor substrate stub，并要求四个 framework 都出现在最终 load commands。
- dylib install-name 必须是 `@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SeagullPair.dylib`；substrate 必须是 `@loader_path/.jbroot/usr/lib/libsubstrate.dylib`。vendor 仅为链接接口，不打包 substrate 实现。不允许其他非系统依赖路径。
- 不改写 Mach-O header、重定位或认证指针字段；所有二进制检查均只读。

## 源码、包布局与发布

只编译 `PairTweak.m`，因为它已经导入 `PairPanel.m`。若源码组织改变，应先审查此约定，避免重复编译。生产文件用 `-O2 -fobjc-arc -fblocks`，探针用 `-O0` 保留间接调用。

临时 staging 内容：

```text
DEBIAN/control
Library/MobileSubstrate/DynamicLibraries/SeagullPair.dylib
Library/MobileSubstrate/DynamicLibraries/SeagullPair.plist
```

plist 仅过滤 `com.apple.springboard`。目录与 dylib 权限为 0755，control/plist 为 0644。control 原样复制，架构必须是 `iphoneos-arm64e`；文件名由 Package、Version、Architecture 得到。`dpkg-deb --root-owner-group -Zgzip --build` 将归档中的 UID/GID 设为 0，不要求以 root 运行，也不 chown 工作区。包架构再次读回核对。

全部检查成功后才将临时 deb 原子发布到 `dist-apple/`（或 `--output`）。已有旧文件不会自动删除，也不能作为本次成功证据。当前 control 对应文件名为 `com.minis.seagullpair_0.1.0_iphoneos-arm64e.deb`；这只是预期名称，不表示文件已经生成。

## 本次验证与边界

在当前 Linux 环境验证 Python 语法和缺少 Apple 工具链的预期失败路径。没有执行 macOS 编译、签名或打包，没有生成 deb，也没有设备验证。需要在上述 macOS/Xcode 环境运行 smoke 和完整构建，才能取得实际构建证据。

本探针验证认证函数指针对象和链接器路径，不穷尽生产源码的 ObjC metadata、block invoke、构造函数及回调 ABI。构建成功和签名验证成功均不等于 RootHide 设备上可加载或功能正确。交付安装前仍须在匹配的 iOS 16.1 / RootHide 环境验证 dyld 加载及实际调用；参见 `LINKER-ABI.md` 的验收门槛。
