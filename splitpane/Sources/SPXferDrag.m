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

@interface SPXferDrag_DragSource : NSObject <UIDragInteractionDelegate>
@property (nonatomic, weak) UIView *container;
@property (nonatomic, copy) NSString *label;
@end

@implementation SPXferDrag_DragSource

- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction itemsForBeginningSession:(id<UIDragSession>)session {
    UIView *src = self.container;
    if (!src) return @[];
    UIImage *shot = nil;
    @try {
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:src.bounds.size];
        shot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [src drawViewHierarchyInRect:src.bounds afterScreenUpdates:NO];
        }];
    } @catch (__unused NSException *e) {}
    if (!shot) return @[];
    NSItemProvider *p = [[NSItemProvider alloc] initWithObject:shot];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:p];
    item.localObject = shot;
    SPLog(@"xfer-drag[%@]: 发起拖拽 %.0fx%.0f", self.label, shot.size.width, shot.size.height);
    return @[item];
}

- (UITargetedDragPreview *)dragInteraction:(UIDragInteraction *)interaction previewForLiftingItem:(UIDragItem *)item session:(id<UIDragSession>)session {
    UIImage *img = item.localObject;
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.frame = CGRectMake(0, 0, 200, 200);
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.layer.cornerRadius = 12;
    iv.alpha = 0.92;
    UIPreviewParameters *params = [UIPreviewParameters new];
    params.backgroundColor = [UIColor clearColor];
    return [[UITargetedDragPreview alloc] initWithView:iv parameters:params target:nil];
}

- (void)dragInteraction:(UIDragInteraction *)interaction sessionWillBegin:(id<UIDragSession>)session {
    gDragging = YES;
    SPLog(@"xfer-drag[%@]: 拖拽开始", _label);
}

- (void)dragInteraction:(UIDragInteraction *)interaction sessionDidEnd:(id<UIDragSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: 拖拽结束", _label);
}

@end

@implementation SPXferDrag

static const void *kDragInstalledKey = &kDragInstalledKey;
static const void *kDragSrcKey = &kDragSrcKey;

+ (BOOL)dragging { return gDragging; }

+ (NSInteger)countInteractionsIn:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 10) return 0;
    NSInteger n = (NSInteger)view.interactions.count;
    for (UIView *sub in view.subviews) n += [self countInteractionsIn:sub depth:depth+1];
    return n;
}

+ (void)dumpInteractionsIn:(UIView *)view label:(NSString *)label depth:(NSInteger)depth {
    if (!view || depth > 10) return;
    if (view.interactions.count > 0) {
        NSMutableArray *names = [NSMutableArray array];
        for (id in0 in view.interactions) [names addObject:NSStringFromClass([in0 class])];
        SPLog(@"xfer-drag[%@] d=%ld %@ -> %@", label, (long)depth,
              NSStringFromClass([view class]), [names componentsJoinedByString:@","]);
    }
    for (UIView *sub in view.subviews) [self dumpInteractionsIn:sub label:label depth:depth+1];
}

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
        NSInteger before = [self countInteractionsIn:container depth:0];
        [self installRecursivelyIn:container delegate:d label:label depth:0];
        NSInteger after = [self countInteractionsIn:container depth:0];
        SPLog(@"xfer-drag: 补装 %@ interactions %ld -> %ld", label, (long)before, (long)after);
        [self dumpInteractionsIn:container label:label depth:0];
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

    // App 自身没有 UIDragInteraction 时，拖拽根本发起不了。
    // 我们自己给容器装一个 UIDragInteraction：双指长按 0.5s 就把当前画面
    // 做成一张可拖拽的图片，用户拖到另一半就能放下。
    SPXferDrag_DragSource *ds = [SPXferDrag_DragSource new];
    ds.container = container;
    ds.label = label;
    UIDragInteraction *drag = [[UIDragInteraction alloc] initWithDelegate:ds];
    drag.enabled = YES;
    [container addInteraction:drag];
    objc_setAssociatedObject(container, &kDragSrcKey, ds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SPLog(@"xfer-drag: 容器 %@ 已装拖放(递归) + 自定义 drag", label);
    // 探测：这个子树里本来有没有系统的 drag interaction（App 自己是否支持长按拖动）
    [self dumpInteractionsIn:container label:label depth:0];
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
    UIView *v = self.container;
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
