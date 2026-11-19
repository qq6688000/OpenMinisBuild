# InteractivePiP Duo 0.2.2

实验性 iOS 16.1–16.x / RootHide / 原生 arm64e 插件。必须具备 SpringBoard 注入能力；仅有 Bootstrap 应用注入并不够。

## 本次修复

- 原先宽高分别缩放导致文字和整个画面被挤压。现在固定原始手机画布，用 MIN(widthRatio,heightRatio) 等比居中；允许黑边，不声称应用已重排成半屏布局。
- Duo 两个面板在可用区域保持固定 50/50（奇数点最多差 1pt），竖屏上下、横屏左右。顶部保留 44pt 控制栏，底部避开 Home 安全区。可点「退出分屏」恢复浮窗，或「关闭全部」结束会话；仍保留双击铰链。
- 用户按 Home 或锁屏结束会话。内部首次启动后的返回桌面与用户 Home 区分；过期启动回调由会话代数失效，后台补救只在目标仍为前台时执行，避免反复回桌面。锁屏立即隐藏并释放；解锁不自动重新拉起应用。
- 删除全局 UIResponder/UIApplication 焦点猜测以及每个宿主抢键盘的设置。仅由实际触摸的浮窗获得 prepareForInput；UIKit prepareForHostedWindow/finishWithHostedWindow 配对使用，不把整个 overlay 设为 key，不改全局 suppressing/currentKeyboard/windowEnabled。
- 私有远程键盘接口不是可靠的每 PID 焦点 API。当前提供可达「键盘帮助」显示焦点应用和接口是否存在，并可结束会话全屏输入。不保证所有 iOS/第三方输入法能在小窗弹键盘；未做设备实测。
- 设置标签、说明和缺失的滑块标题改为中文，不改变偏好键。
- 释放或重新连接时恢复修改前的 scene settings，取消保活和重连；失效宿主拒绝被延迟任务重新连接。

## 构建

在完整 Xcode 的 macOS 上运行 `python3 build-apple.py`，需 `dpkg-deb`。使用真实 Apple clang、Apple ld `-fixup_chains`、arm64e 和 codesign。禁止 LLD 或改 Mach-O header 冒充 arm64e。产物 `dist-apple/InteractivePiP_Duo_0.2.2_iphoneos-arm64e.deb`。

对应工作流 `.github/workflows/interactive-pip.yml` 使用 macos-15；源码归档包含该文件及所有本工程 vendored 声明/Logos 源文件，不包含 Apple SDK（由 Xcode 提供）或系统运行库二进制。

## 验收边界

本地使用 iOS SDK 做全部 Objective-C/Logos 语法检查；静态几何测试验证均分、等比缩放、44pt 控件区域。云构建验证真实 Apple 工具链、Mach-O 和签名；下载后另行解析两个 Mach-O 与 deb 版本。

必须真机确认：两应用点击/滚动；系统及第三方键盘逐窗切换；旋转后的触控映射；退出分屏/关闭全部/Home/锁屏时应用状态和键盘恢复；解锁不重开；被系统终止后重连；SpringBoard 稳定性。接口存在或编译成功不算输入/生命周期实测通过。

## 安装与恢复

RootHide 包管理器安装，注销 SpringBoard。卸载 `com.seagull.interactivepip` 并注销可移除 hooks；若异常在安全模式禁用。设置关闭开关会关闭窗口。

## 许可证

保留仓库 GPL-3.0 LICENSE；DualPane 上游 MIT（f1afebe）和 RootHide MIT、Logos GPL-3.0 及其 vendored Perl 模块条款都在 LICENSES 和 THIRD_PARTY_NOTICES.md 中。没有把外部链接当作唯一许可证副本。
