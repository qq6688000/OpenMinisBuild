#import "SPXferDrag.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static BOOL gDragging = NO;
// 整个进程共用；仅主队列递增/读取，跨容器的新 drop 同样淘汰旧结果。
static NSUInteger gDropGeneration = 0;

typedef NS_ENUM(NSUInteger, SPXferDragContentKind) {
    SPXferDragContentNone,
    SPXferDragContentFileURL,
    SPXferDragContentImageObject,
    SPXferDragContentImageData,
    SPXferDragContentPlainText,
};

static SPXferDragContentKind SPXferDragKindForProvider(NSItemProvider *provider) {
    if ([provider hasItemConformingToTypeIdentifier:@"public.file-url"]) return SPXferDragContentFileURL;
    if ([provider canLoadObjectOfClass:UIImage.class]) return SPXferDragContentImageObject;
    if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) return SPXferDragContentImageData;
    if ([provider hasItemConformingToTypeIdentifier:UTTypePlainText.identifier]) return SPXferDragContentPlainText;
    return SPXferDragContentNone;
}

static BOOL SPXferDragSessionIsSupported(id<UIDropSession> session) {
    if (!session.items.count) return NO;
    // 不吞掉只有其它能力的会话，也不悄悄丢掉混合会话中的不支持项。
    for (UIDragItem *item in session.items) {
        if (SPXferDragKindForProvider(item.itemProvider) == SPXferDragContentNone) return NO;
    }
    return YES;
}

static void SPXferDragLoadImageData(NSItemProvider *provider, void (^completion)(id)) {
    [provider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier
                                  completionHandler:^(NSData *data, NSError *error) {
        UIImage *image = (!error && [data isKindOfClass:NSData.class]) ? [UIImage imageWithData:data] : nil;
        completion(image);
    }];
}

static void SPXferDragLoadProvider(NSItemProvider *provider, void (^completion)(id)) {
    switch (SPXferDragKindForProvider(provider)) {
        case SPXferDragContentFileURL: {
            // 参数必须显式 NSURL，不能让 Foundation 按 id 猜测/强制转换类型。
            // 仅转交 URL；跨进程文件访问权限及 URL 有效期仍需真机验证。
            [provider loadItemForTypeIdentifier:@"public.file-url" options:nil
                             completionHandler:^(NSURL *url, NSError *error) {
                completion(!error && [url isKindOfClass:NSURL.class] && url.isFileURL ? url : nil);
            }];
            break;
        }
        case SPXferDragContentImageObject: {
            [provider loadObjectOfClass:UIImage.class
                      completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                if (!error && [object isKindOfClass:UIImage.class]) {
                    completion(object);
                } else if ([provider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
                    SPXferDragLoadImageData(provider, completion);
                } else {
                    completion(nil);
                }
            }];
            break;
        }
        case SPXferDragContentImageData: {
            SPXferDragLoadImageData(provider, completion);
            break;
        }
        case SPXferDragContentPlainText: {
            [provider loadItemForTypeIdentifier:UTTypePlainText.identifier options:nil
                             completionHandler:^(NSString *text, NSError *error) {
                completion(!error && [text isKindOfClass:NSString.class] ? text : nil);
            }];
            break;
        }
        default: {
            completion(nil);
            break;
        }
    }
}

@interface SPXferDrag_DragSource : NSObject <UIDragInteractionDelegate>
@property (nonatomic, weak) UIView *container;
@property (nonatomic, weak) UIView *snapshotFrom;
@property (nonatomic, copy) NSString *label;
@end

@interface SPXferDrag ()
@property (nonatomic, weak) UIView *container;
@property (nonatomic, copy) NSString *label;
- (BOOL)canAcceptSession:(id<UIDropSession>)session;
@end


@implementation SPXferDrag_DragSource

- (NSArray<UIDragItem *> *)dragInteraction:(UIDragInteraction *)interaction itemsForBeginningSession:(id<UIDragSession>)session {
    // 剪贴板里如果有文件 URL，优先拖文件而不是截图
    NSArray *pbURLs = [UIPasteboard generalPasteboard].URLs;
    if (pbURLs.count) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSURL *u in pbURLs) {
            NSItemProvider *p = [[NSItemProvider alloc] initWithContentsOfURL:u];
            if (p) {
                [items addObject:[[UIDragItem alloc] initWithItemProvider:p]];
                SPLog(@"xfer-drag[%@]: 拖出文件 %@", self.label, u);
            }
        }
        if (items.count) return items;
    }
    UIView *src = self.snapshotFrom ?: self.container;
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

// ⚠️ 绝对不要实现 previewForLiftingItem:（两次安全模式换来的教训）：
//   第一次：自建 UIImageView 不在窗口层级 → initWithView: 抛异常
//   第二次：即使传真实视图，系统在 lift 效果阶段还会再访问这个 view，
//           那时它可能已被释放（doesNotRecognizeSelector → SIGABRT）
// 不实现 = 系统用默认预览，绝对安全。

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
+ (void)attachDragToView:(UIView *)view label:(NSString *)label snapshotFrom:(UIView *)snapshotFrom {
    if (!view) return;
    SPXferDrag_DragSource *ds = [SPXferDrag_DragSource new];
    ds.container = view;
    ds.snapshotFrom = snapshotFrom ?: view;
    ds.label = label;
    UIDragInteraction *drag = [[UIDragInteraction alloc] initWithDelegate:ds];
    drag.enabled = YES;
    [view addInteraction:drag];
    objc_setAssociatedObject(view, &kDragSrcKey, ds, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SPLog(@"xfer-drag: %@ 已装 drag 源（截图自 %@）", label, NSStringFromClass([ds.snapshotFrom class]));
}

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

- (BOOL)canAcceptSession:(id<UIDropSession>)session {
    UIWindow *window = self.container.window;
    return window && !window.isHidden && window.windowScene && SPXferDragSessionIsSupported(session);
}

- (BOOL)dropInteraction:(UIDropInteraction *)interaction canHandleSession:(id<UIDropSession>)session {
    BOOL ok = [self canAcceptSession:session];
    SPLog(@"xfer-drag[%@]: canHandle=%d items=%lu", _label, (int)ok,
          (unsigned long)session.items.count);
    return ok;
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnter:(id<UIDropSession>)session {
    gDragging = YES;
    SPLog(@"xfer-drag[%@]: 拖入", _label);
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
    BOOL supported = [self canAcceptSession:session];
    UIDropProposal *proposal = [[UIDropProposal alloc] initWithDropOperation:
                               supported ? UIDropOperationCopy : UIDropOperationCancel];
    proposal.precise = supported;
    return proposal;
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidExit:(id<UIDropSession>)session {
    SPLog(@"xfer-drag[%@]: 拖出", _label);
}

- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dropInteraction:interaction performDrop:session]; });
        return;
    }
    gDragging = NO;
    NSUInteger generation = ++gDropGeneration;
    if (![self canAcceptSession:session]) return;
    SPLog(@"xfer-drag[%@]: 落下 items=%lu generation=%lu", _label,
          (unsigned long)session.items.count, (unsigned long)generation);

    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSInteger changeCount = pasteboard.changeCount;
    __weak UIView *dropContainer = self.container;
    __weak UIWindow *dropWindow = self.container.window;
    NSString *label = [self.label copy];
    NSArray<UIDragItem *> *sourceItems = [session.items copy];
    dispatch_group_t group = dispatch_group_create();
    // 每个源 item 占一个固定位置，异步完成顺序不影响粘贴顺序。
    // slots 和最终 items 的创建/修改均只在主队列。
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:sourceItems.count];
    for (NSUInteger index = 0; index < sourceItems.count; index++) [slots addObject:NSNull.null];
    [sourceItems enumerateObjectsUsingBlock:^(UIDragItem *item, NSUInteger index, BOOL *stop) {
        dispatch_group_enter(group);
        __block BOOL completed = NO;
        SPXferDragLoadProvider(item.itemProvider, ^(id value) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completed) return;
                completed = YES;
                if (value) slots[index] = @{ UIPasteboardTypeAutomatic: value };
                else SPLog(@"xfer-drag[%@]: item %lu 解析失败", label, (unsigned long)index);
                // 必须先写槽位再 leave，notify 才能看到完整结果。
                dispatch_group_leave(group);
            });
        });
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        UIView *container = dropContainer;
        UIWindow *window = dropWindow;
        if (generation != gDropGeneration || pasteboard.changeCount != changeCount ||
            !container || !window || container.window != window || window.isHidden || !window.windowScene) {
            SPLog(@"xfer-drag[%@]: 丢弃过期结果 generation=%lu", label, (unsigned long)generation);
            return;
        }
        NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
        for (id value in slots) {
            if ([value isKindOfClass:NSDictionary.class]) [items addObject:value];
        }
        if (!items.count) {
            SPLog(@"xfer-drag[%@]: 没解析出可落地内容", label);
            return;
        }
        // SDK 16.5: Automatic 支持 UIImage/NSString/NSURL，混合内容逐项写入，不三选一。
        pasteboard.items = items;
        SPLog(@"xfer-drag[%@]: 已写剪贴板 items=%lu，需用户在目标 App 粘贴", label,
              (unsigned long)items.count);
    });
}

- (void)dropInteraction:(UIDropInteraction *)interaction concludeDrop:(id<UIDropSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: conclude", _label);
}

- (void)dropInteraction:(UIDropInteraction *)interaction sessionDidEnd:(id<UIDropSession>)session {
    gDragging = NO;
    SPLog(@"xfer-drag[%@]: 会话结束", _label);
}

@end
