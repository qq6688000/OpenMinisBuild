#import <UIKit/UIKit.h>
#import "SPLog.h"
#import "SPCompat.h"

// ============================================================================
// 分屏跨窗口传文件
//
// 需求：分屏下把一个窗口里的文件传到另一个窗口。
//
// iOS 上跨 App 传文件只有两条合法路径：
//   1) 系统剪贴板（UIPasteboard）—— 通用、稳、所有 App 都认
//   2) 系统「共享」面板（UIActivityViewController）—— 走目标 App 的 Share Extension
//
// 真正做「拖拽文件到另一半」需要接管 UIDragInteraction 的跨进程会话
// （NSItemProvider + com.apple.UIKit.drag），在 SpringBoard 注入环境里风险很高，
// 而且目标 App 不一定实现了 drop，所以先用剪贴板 + 共享面板把闭环走通：
//   长按接缝上的传送按钮 → 选当前窗口里可传的东西（剪贴板/最近截图/文件）
//                        → 切到另一半容器执行粘贴/打开
// ============================================================================

@interface SPXfer : NSObject

// 把剪贴板内容送到「另一个」窗口：把目标 App 提到前台并触发粘贴。
// 返回 YES 表示已投递。
+ (BOOL)sendPasteboardToBundleID:(NSString *)bundleID;

// 弹出「发送到另一半」面板
+ (void)presentSenderForBundleID:(NSString *)targetBundleID
                      fromWindow:(UIWindow *)window
                        inScene:(UIWindowScene *)scene;

@end
