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

+ (BOOL)dragging { return gDragging; }

+ (void)attachToContainer:(UIView *)container label:(NSString *)label {
    if (!container) return;
    // 同一个容器只装一次
    for (UIGestureRecognizer *g in container.gestureRecognizers) {
        if ([g isKindOfClass:NSClassFromString(@"UIInteraction")]) return;
    }
    static const void *kKey = &kKey;
    if (objc_getAssociatedObject(container, kKey)) return;

    SPXferDrag *d = [SPXferDrag new];
    d.container = container;
    d.label = label;
    d.sessions = [NSMutableArray array];
    objc_setAssociatedObject(container, kKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIDropInteraction *drop = [[UIDropInteraction alloc] initWithDelegate:d];
    [container addInteraction:drop];

    SPLog(@"xfer-drag: 容器 %@ 已装拖放", label);
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
