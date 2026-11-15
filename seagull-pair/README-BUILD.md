# SeagullPair 离线构建

本目录只提供构建基础设施：`build.py`、`control`、`vendor/` 和本说明。`PairTweak.m` 由父工程维护，脚本不会创建、覆盖或修改它，也不会安装到设备。

## 构建

```sh
cd /var/minis/workspace/seagull-pair
python3 build.py
```

脚本要求本机已经提供：

- `/usr/bin/clang` 为 clang 19；
- `/usr/bin/ld64.lld`；
- `/usr/local/bin/ldid`；
- `/usr/bin/dpkg-deb`；
- `/opt/theos/sdks/iPhoneOS16.5.sdk`；
- 父工程放入的 `PairTweak.m`。

编译参数固定包含 `-target arm64e-apple-ios16.1`、`-fobjc-arc`、`-fblocks` 以及 pointer-authentication 编译选项。链接使用 `ld64.lld`，传入 UIKit、Foundation、QuartzCore 和本地 `vendor/libsubstrate.tbd`。输出安装名为：

```text
@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SeagullPair.dylib
```

substrate 桩的 install-name 为：

```text
@loader_path/.jbroot/usr/lib/libsubstrate.dylib
```

签名步骤固定执行 `ldid -Cadhoc -S`。构建在 `/tmp` 中完成，最后用临时文件原子复制到 `dist/`，以保留权限并避免半成品被发布。任何编译、链接、签名、Mach-O 检查或打包失败都会以非零状态退出，且不会发布 deb。

## ABI 检查边界

`build.py --smoke` 使用独立的临时最小 C 源验证 clang 是否真的生成 pointer-authentication 指令，并检查目标文件和链接产物的 Mach-O CPU subtype。它不会创建生产源或 deb。

脚本拒绝通过改写 Mach-O 头部来伪造 arm64e。目标名、`__arm64e__` 宏或头文件改写本身不能证明 arm64e ABI 支持；最终链接器产物仍需通过实际 subtype 检查。smoke 还会验证两个 install-name 和 ad-hoc 签名 load command。由于当前环境的 `ld64.lld` 可能把 `-arch arm64e` 产物写成 `ARM64 ALL`，这种情况会按设计失败，表示需要能保留 arm64e subtype 的 linker/toolchain；不会生成可安装包。

## 包元数据和布局

包版本为 `0.1.0`，标识为 `com.minis.seagullpair`，名称为 `SeagullPair experimental`。控制文件声明：

- `Architecture: iphoneos-arm64e`
- `Depends: firmware (>= 16.1), mobilesubstrate`
- `Conflicts: com.82flex.panoramicview`

动态库和过滤 plist 进入 `Library/MobileSubstrate/DynamicLibraries/`，过滤器只匹配 `com.apple.springboard`。包路径使用 RootHide 形式，不包含 `/var/jb` 前缀。未在此工程中执行设备安装或修改原工程文件。
