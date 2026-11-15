# SeagullPair 开发状态

目标：独立实现 PanoramicView 类似的双应用组合，RootHide / iOS16，支持比例调节、交换和恢复。

当前工程已包含自有控制面板、场景捕获、几何调整与恢复代码，非原库补丁。首版源码语法检查通过，已实际生成 arm64e Mach-O 对象；补齐 CoreGraphics 后 ld64.lld 可完成链接，但输出 subtype 为 ARM64 ALL。构建脚本主动拒绝发布此输出；没有生成可安装 deb。

已核实系统激活链：SBSwitcherTransitionRequest.requestForActivatingAppLayout: → SBMainSwitcherControllerCoordinator.switcherContentController:performTransitionWithRequest:gestureInitiated:。只能证明提交单个焦点应用激活，不保证两个应用同时保持前台。原版还有额外展示与生命周期管理；当前实现缺少这一环，不能宣称完整复刻。

原生工具链替代方案实测：minis-native-build doctor --probe 中 clang、ld、ldid 均 posix_spawn EPERM，未执行成功。证据 native-toolchain-probe.json。

链接器 ABI 核查已完成：本机 clang19 将静态认证指针写为普通 relocation，LLD19 拒绝 type11 认证 relocation，问题不止 subtype；不能改头修复。证据 LINKER-ABI.md。场景 adapter 已修复条件回滚、context、安全区、reference size、独立 host、重入及 ABI 检查，并完成 -Werror 对象编译。

正在改造单焦点+冻结画面会话，并准备 Apple Xcode 独立构建入口。另行核实原版系统 transition 完成回调，避免用固定延迟冒充切换完成。新源码仍须重新编译、核验，再在目标设备安装验证。当前禁止将对象文件/未通过门禁的 dylib 当作安装成品。

回滚：未安装设备，未修改原包；源码初版快照在 snapshots/。
