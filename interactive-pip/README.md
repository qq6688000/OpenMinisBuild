# InteractivePiP 0.1.0 — 原生交互分屏（实验构建）

目标：iOS 16.x / arm64e / RootHide，需能够向 SpringBoard 注入插件的越狱环境。仅有 Bootstrap/App 注入而没有 SpringBoard 注入能力不能运行本插件。

本工程通过 SpringBoard 的 FrontBoard scene hosting 托管真实应用场景，采用 UIKit 原生窗口、手势、分屏分隔条。不是 Apple AVKit 视频 PiP，也不会把截图当作可交互应用。Apple 的 AVKit PiP 内容视图不接收触控，不能直接用于此目标。

## 实现功能（Duo 分屏模式）

当前分屏按 iPhone Duo 形态呈现：两个应用各占固定 50% 屏幕区域，横屏左右双屏、竖屏上下双屏，中间留一条不可拖动的铰链缝；分屏时移除浮窗圆角、阴影、边框、标题栏和缩放把手，内容铺满各自半屏。双击铰链退出并恢复浮窗。单应用悬浮窗仍保留拖拽、缩放和标题栏。

- 主屏幕应用图标上滑：打开应用悬浮窗。
- 图标长按菜单：悬浮窗打开 / 交互式分屏。
- 浮窗标题栏：关闭、分屏、最大化/还原；拖动标题栏移动，右下角调整大小。
- 点击分屏按钮后选择第二个不同的应用：竖屏上下布局，横屏左右布局。
- 拖动中间 24pt 分隔条：调整为 30%—70%；双击分隔条退出分屏、恢复浮窗。
- 输入焦点只交给当前触摸的应用，不再同时请求两个应用的键盘。
- 设置 App → 交互分屏 PiP：开关、图标手势、大小、黑名单等。

## 安装

1. 在匹配的 RootHide 环境用 Sileo 安装 deb。安装器使用 RootHide 标准根目录转换，不硬编码随机 jbroot，不复制到猜测的路径。
2. 确认具备 SpringBoard 插件注入功能，注销 SpringBoard 后生效。
3. 先用两个已启动过的普通应用验证，例如备忘录与 Safari，再测试目标应用。

## 必须真机验收

当前交付只代表编译、Mach-O 架构、签名和 deb 结构验证；尚未在目标设备安装运行。

- 小窗切到其他 App 后是否保持可见；滚动、点击按钮是否真正作用于目标 App。
- 两个窗口分别输入文字，切换焦点，检查系统键盘及第三方键盘。
- 分隔条拖动、旋转、退出分屏和关闭窗口后，检查原 App 全屏与键盘是否恢复。
- 锁屏/解锁、目标 App 被系统终止后是否能重连。
- 场景托管失败时显示连接状态或静态预览并提供重试；静态预览不计为交互成功。

私有接口和宿主环境存在差异，不能从编译成功推断触控、输入、保活和旋转全部通过。

## 卸载与恢复

在 Sileo 卸载 `com.seagull.interactivepip`，注销 SpringBoard。若 SpringBoard 启动失败，在越狱安全模式禁用或卸载此包。设置页关闭开关可以关闭窗口；已注册的运行时 hooks 到下一次注销才完全移除。

## 来源和构建

基于 MIT 项目 blueskycrb/DualPane，commit f1afebe，保留 LICENSE。新增双应用分屏、比例分隔条、焦点路由与独立包标识。RootHide API 声明取自 roothide/libroothide，许可证见 vendor/libroothide/LICENSE。

运行 `python3 build.py`。需要 /opt/theos、iPhoneOS16.2.sdk、支持 arm64e 的 clang/ld64.lld、ldid、dpkg-deb。使用真实 `-target arm64e-apple-ios16.0` 输出，禁止通过篡改 Mach-O subtype 冒充 arm64e。

构建产物在 dist/。源码归档包含修改后源码、构建脚本和许可证。
