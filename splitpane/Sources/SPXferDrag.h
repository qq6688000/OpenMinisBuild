#import <UIKit/UIKit.h>
#import "SPLog.h"

// ============================================================================
// 分屏跨窗口拖拽（照 PanoramicView 的做法）
//
// PV 的实证结构（METHOD_INDEX.h）：
//   PVPairContentDrag  : UIDropInteractionDelegate
//       dropInteraction:canHandleSession: / sessionDidEnter / sessionDidUpdate
//       sessionDidExit / sessionDidEnd
//   PVPairDrag         : 发起端 begin/panned/updateSeamAtPosition/settleAtIndex:
//   PVPairDragInputWindow : 拖拽期间单开的输入窗口
//
// 关键结论：PV 自己不做任何「跨 App 传数据」——
// 数据完全由 iOS 的 UIDragSession 承载，PV 只负责让两个窗口处于同一拖拽空间。
//
// 我们的实现方式：
//   1) 给两个 pane 容器各挂一个 UIDropInteraction（接住别处拖来的东西）
//   2) 把 drop 转发给容器里的 sceneView（App 自己处理，它本来就有 UIDropInteraction）
//   3) 拖拽期间不拦截触摸，让系统拖拽会话正常进行
// ============================================================================

@interface SPXferDrag : NSObject <UIDropInteractionDelegate, UIDragInteractionDelegate>

// 给一个 pane 容器装上拖放能力
+ (void)attachToContainer:(UIView *)container label:(NSString *)label;

// 我们当前是不是正在拖拽（分屏逻辑据此放行触摸）
@property (class, readonly) BOOL dragging;

@end
