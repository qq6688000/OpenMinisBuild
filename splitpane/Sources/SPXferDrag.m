#import "SPXferDrag.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL gDragging = NO;

@interface SPXferDrag ()
@property (nonatomic, weak) UIView *container;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, strong) NSMutableArray *sessions;
@end

@implementation SPXferDrag

static const void *kDragInstalledKey = &kDragInstalledKey;

+ (BOOL)dragging { return gDragging; }

// 递归给整棵子树装 drop：容器 → split → pane → sceneView → 内部视图
+ (void)installRecursivelyIn:(UIView *)view delegate:(id)del label:(NSString *)label depth:(NSInteger)depth {
    if (!view || depth > 8) return;
    if (!objc_getAssociatedObject(view, kDragInstalledKey)) {
        UIDropInteraction *drop = [[UIDropInteraction alloc] initWithDelegate:del];
        [view addInteraction:drop];
        objc_setAssociatedObject(view, kDragInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *sub in view.subviews) {
        [self installRecursivelyIn:sub delegate:del label:label depth:depth + 1];
    }
}

+ (void)attachToContainer:(UIView *)container label:(NSString *)label {
    if (!container) return;
    // 每个容器实例一个 delegate；已装过的视图由 kDragInstalledKey 去重，
    // 所以这里可以重复调用（sceneView 建出来之后再补装时要用到）
    static const void *kKey = &kKey;
    SPXferDrag *d = objc_getAssociatedObject(container, kKey);
    if (d) {
        // 已经建过 delegate：只补装新出现的子视图（比如后建的 sceneView）
        [self installRecursivelyIn:container delegate:d label:label depth:0];
        return;
    }
    d = [SPXferDrag new];
    d.container = container;
    d.label = label;
    d.sessions = [NSMutableArray array];
    objc_setAssociatedObject(container, kKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // PV 的 _interactions 是 NSHashTable（多个），说明它不只是给顶层容器装，
    // 而是递归装到内部每一层 —— 否则触摸命中的是 sceneView 内部视图，
    // 系统根本不会把 drop 送到我们的容器上。
    [self installRecursivelyIn:container delegate:d label:label depth:0];
    SPLog(@"xfer-drag: 容器 %@ 已装拖放(递归)", label);
}

#pragma mark - UIDropInteractionDelegate

- (BOOL)dropInteraction:(UIDropInteraction *)interaction canHandleSession:(id<UIDropSession>)session {
    // 任何能提供 item 的会话都接，具体能不能用由内部 App 判断
    BOOL ok = (session.items.count > 0);
    SPLog(@"xfer-drag[%@]: canHandle=%d items=%lu", _label, (int)ok,
          (unsigned long)session.items.count);
    return ok;
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnter:(id<UIDropSession>)session {
    gDragging = YES;
    SPLog(@"xfer-drag[%@]: 拖入", _label);
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
    // 关键：把落点转给容器里的 App（sceneView），让 App 自己决定接不接、怎么接。
    // 我们不消费数据，只做转发 —— 数据本身由系统 UIDragSession 承载。
    UIDropProposal *p = [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
    p.precise = YES;
    return p;
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidExit:(id<UIDropSession>)session {
    SPLog(@"xfer-drag[%@]: 拖出", _label);
}

- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: 落下 items=%lu", _label, (unsigned long)session.items.count);

    // 把落点坐标交给容器里的 App，让它按自己的方式接收
    UIView *target = [self deepestViewInContainerAtPoint:[session locationInView:_container]];
    SPLog(@"xfer-drag[%@]: 目标视图=%@", _label, target ? NSStringFromClass([target class]) : @"nil");

    if (target) {
        // 转发给系统：让 sceneView 内部的 UIDropInteraction 处理
        [self forwardDropToView:target session:session];
    }
}

- (void)dropInteraction:(UIDropInteraction *)interaction concludeDrop:(id<UIDropSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: conclude", _label);
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnd:(id<UIDropSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: 会话结束", _label);
}

#pragma mark - 转发

- (UIView *)deepestViewInContainerAtPoint:(CGPoint)p {
    UIView *v = _container;
    while (v) {
        UIView *next = nil;
        for (UIView *sub in v.subviews.reverseObjectEnumerator) {
            if (!sub.hidden && sub.alpha > 0.01 && CGRectContainsPoint(sub.frame, [sub convertPoint:p fromView:v])) {
                next = sub; break;
            }
        }
        if (!next) break;
        v = next;
    }
    return v;
}

- (void)forwardDropToView:(UIView *)view session:(id<UIDropSession>)session {
    // sceneView（SBDeviceApplicationSceneView）内部有系统的 drop 处理，
    // 我们把它自己的 UIDropInteraction 找出来，直接调 dropInteraction:performDrop:
    @try {
        for (id inter in view.interactions) {
            if (![inter isKindOfClass:[UIDropInteraction class]]) continue;
            id del = ((UIDropInteraction *)inter).delegate;
            SEL sel = NSSelectorFromString(@"dropInteraction:performDrop:");
            if (del && [del respondsToSelector:sel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(del, sel, inter, session);
                SPLog(@"xfer-drag: 已转发给 %@", NSStringFromClass([del class]));
                return;
            }
        }
    } @catch (NSException *e) { SPLog(@"xfer-drag 转发异常 %@", e.reason); }
    SPLog(@"xfer-drag: 目标视图没有 drop 处理，忽略");
}

@end
