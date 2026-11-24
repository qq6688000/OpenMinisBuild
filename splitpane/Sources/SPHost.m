#import "SPHost.h"
#import "SPSettings.h"
#import <objc/runtime.h>
#import "SPLog.h"

// 一个 App 的画面 = 从 scene handle 新建的 SBSceneView（参考尺寸 = 容器尺寸），
// 底下永远垫一张冻结快照。系统一旦把后台 scene 收回去，活层空了就露出快照，
// 不会变黑（Duo 0.7.225 的结论：活层会掉，垫底层才是保命的）。

@interface SPHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, weak, readwrite) UIView *containerView;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIImageView *snapshotView;
@property (nonatomic, strong) id handle;
@property (nonatomic, strong) id scene;
@property (nonatomic, assign, readwrite) BOOL live;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, assign) BOOL attached;
@end

@implementation SPHost

#pragma mark - SpringBoard 入口

+ (id)mainDisplaySceneManager {
    Class coord = NSClassFromString(@"SBSceneManagerCoordinator");
    if (coord) {
        id m = SPMsg0(coord, @"mainDisplaySceneManager");
        if (!m) m = SPMsg0(coord, @"secureMainDisplaySceneManager");
        if (m) return m;
    }
    Class wsCls = NSClassFromString(@"SBWorkspace");
    if (wsCls) {
        id ws = SPMsg0(wsCls, @"mainWorkspace");
        if (ws) return SPMsg0(ws, @"mainDisplaySceneManager");
    }
    return nil;
}

+ (id)applicationProxyForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    Class ac = NSClassFromString(@"SBApplicationController");
    if (!ac) return nil;
    id ctrl = SPMsg0(ac, @"sharedInstance");
    if (!ctrl) return nil;
    id app = SPMsg1(ctrl, @"applicationWithBundleIdentifier:", bundleID);
    if (!app) app = SPMsg1(ctrl, @"applicationWithDisplayIdentifier:", bundleID);
    return app;
}

static BOOL SPHandleBelongsTo(id handle, NSString *bundleID) {
    if (!handle) return NO;
    id app = SPMsg0(handle, @"application");
    id bidObj = SPMsg0(app, @"bundleIdentifier");
    if (![bidObj isKindOfClass:[NSString class]]) return YES;   // 拿不到就信它
    NSString *bid = (NSString *)bidObj;
    if (!bid.length) return YES;
    return [bid isEqualToString:bundleID];
}

+ (id)sceneHandleForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    id mgr = [self mainDisplaySceneManager];
    // 1) 管理器直接按 bundleID 拿句柄（不同版本命名不一样，挨个试）
    if (mgr) {
        for (NSString *sel in @[@"sceneHandleForBundleID:", @"externalApplicationSceneHandleForBundleID:",
                                @"sceneHandleForApplication:", @"sceneHandleForDisplayItem:"]) {
            if (![mgr respondsToSelector:NSSelectorFromString(sel)]) continue;
            id h = nil;
            if ([sel hasSuffix:@"DisplayItem:"]) continue;
            h = SPMsg1(mgr, sel, bundleID);
            if (SPHandleBelongsTo(h, bundleID)) { SPLog(@"handle via %@", sel); return h; }
        }
        // 2) 退而求其次：枚举所有 scene，比 bundleID
        NSArray *scenes = SPMsg0(mgr, @"allScenes");
        if ([scenes isKindOfClass:[NSArray class]]) {
            id fallback = nil;
            for (id sc in scenes) {
                id h = SPMsg0(sc, @"handle");
                if (!SPHandleBelongsTo(h, bundleID)) continue;
                if (SPBool0(h, @"isMainDisplayScene")) return h;
                if (!fallback) fallback = h;
            }
            if (fallback) { SPLog(@"handle via allScenes"); return fallback; }
        }
    }
    // 3) App 自己身上的句柄
    id app = [self applicationProxyForBundleID:bundleID];
    if (!app) { SPLog(@"no app proxy for %@", bundleID); return nil; }
    id main = SPMsg0(app, @"mainSceneHandle");
    if (SPHandleBelongsTo(main, bundleID)) return main;
    NSArray *handles = SPMsg0(app, @"sceneHandles");
    if ([handles isKindOfClass:[NSArray class]]) {
        for (id h in handles) if (SPBool0(h, @"isMainDisplayScene")) return h;
        if (handles.count) return handles.firstObject;
    }
    return nil;
}

#pragma mark - 打开 / 激活

+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL))completion {
    Class wsCls = NSClassFromString(@"SBWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"mainWorkspace") : nil;
    if (!ws || !bundleID.length) return NO;
    id opts = nil;
    Class optCls = NSClassFromString(@"FBSOpenApplicationOptions");
    if (optCls) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (suspended) d[@"__Suspended"] = @(YES);
        opts = SPMsg1(optCls, @"optionsWithDictionary:", d);
    }
    SEL s1 = NSSelectorFromString(@"openApplicationWithBundleID:options:withResult:");
    SEL s2 = NSSelectorFromString(@"openApplicationWithBundleIdentifier:options:withResult:");
    SEL sel = [ws respondsToSelector:s1] ? s1 : ([ws respondsToSelector:s2] ? s2 : NULL);
    if (!sel) return NO;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, sel, bundleID, opts, ^(BOOL ok) {
        if (completion) completion(ok);
    });
    return YES;
}

+ (BOOL)activateApp:(NSString *)bundleID windowScene:(UIWindowScene *)scene completion:(void (^)(BOOL))completion {
    Class wsCls = NSClassFromString(@"SBWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"mainWorkspace") : nil;
    id app = [self applicationProxyForBundleID:bundleID];
    if (!ws || !app) return NO;
    SEL sel = NSSelectorFromString(@"activateApplication:withResult:");
    if (![ws respondsToSelector:sel]) return NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(ws, sel, app, ^(BOOL ok) {
        if (completion) completion(ok);
    });
    return YES;
}

#pragma mark - 实例

- (instancetype)initWithBundleID:(NSString *)bundleID {
    if ((self = [super init])) _bundleID = [bundleID copy];
    return self;
}

- (void)installSnapshot:(UIImage *)snapshot {
    if (!snapshot || !_containerView) return;
    if (!_snapshotView) {
        _snapshotView = [[UIImageView alloc] initWithImage:snapshot];
        _snapshotView.contentMode = UIViewContentModeScaleAspectFill;
        _snapshotView.clipsToBounds = YES;
        _snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_containerView insertSubview:_snapshotView atIndex:0];
    } else {
        _snapshotView.image = snapshot;
    }
    _snapshotView.frame = _containerView.bounds;
    _snapshotView.hidden = NO;
}

- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    if (!container) return NO;
    _containerView = container;
    if (_attached && _hostView && _hostView.superview == container) return YES;

    UIWindowScene *ws = windowScene ?: container.window.windowScene;
    if (!ws) return NO;

    id handle = [SPHost sceneHandleForBundleID:_bundleID];
    if (!handle) return NO;
    // 防串台：句柄必须属于这个 App
    id app = SPMsg0(handle, @"application");
    id bid = SPMsg0(app, @"bundleIdentifier");
    if ([bid isKindOfClass:[NSString class]] && ![bid isEqualToString:_bundleID]) return NO;

    id scene = SPMsg0(handle, @"scene");
    if (!scene) scene = SPMsg0(handle, @"sceneIfExists");
    if (!scene) return NO;

    _handle = handle;
    _scene = scene;

    CGRect b = container.bounds;
    CGSize ref = b.size;
    if (ref.width < 2 || ref.height < 2) ref = ws.coordinateSpace.bounds.size;
    _lastSize = ref;

    UIView *host = nil;
    Class sceneViewCls = NSClassFromString(@"SBSceneView");

    // A) 场景句柄直接出视图（系统切换器用的同一个工厂）
    SEL mk = NSSelectorFromString(@"newSceneViewWithReferenceSize:");
    if ([handle respondsToSelector:mk])
        host = ((id (*)(id, SEL, CGSize))objc_msgSend)(handle, mk, ref);

    // B) 带配置的版本（iOS 16 上更常见）
    if (!host) {
        SEL mk2 = NSSelectorFromString(@"createSceneViewWithReferenceSize:withContentOrientation:andContainerOrientation:configuration:");
        if ([handle respondsToSelector:mk2] && sceneViewCls) {
            Class cfgCls = NSClassFromString(@"FBSceneViewConfiguration");
            id cfg = cfgCls ? [[cfgCls alloc] init] : nil;
            host = ((id (*)(id, SEL, CGSize, NSInteger, NSInteger, id))objc_msgSend)(handle, mk2, ref, 1, 1, cfg);
        }
    }
    // C) scene 自己出视图
    if (!host) {
        SEL mk3 = NSSelectorFromString(@"viewWithReferenceSize:configuration:");
        if ([scene respondsToSelector:mk3])
            host = ((id (*)(id, SEL, CGSize, id))objc_msgSend)(scene, mk3, ref, nil);
    }
    // D) SBSceneView 通用构造
    if (!host && sceneViewCls && [sceneViewCls instancesRespondToSelector:NSSelectorFromString(@"initWithScene:")])
        host = ((id (*)(id, SEL, id))objc_msgSend)([sceneViewCls alloc], NSSelectorFromString(@"initWithScene:"), scene);

    if (![host isKindOfClass:[UIView class]]) return NO;

    host.frame = container.bounds;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:host];
    _hostView = host;
    _attached = YES;
    _live = YES;
    _snapshotActive = NO;

    SEL refSel = NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:");
    if ([host respondsToSelector:refSel])
        ((void (*)(id, SEL, CGSize, NSInteger, NSInteger))objc_msgSend)(host, refSel, ref, 1, 1);
    // 防冻结：让 scene 自认还在「被展示」
    SPVoid1B(handle, @"setSuspended:", NO);
    return YES;
}

- (void)attachWhenReady:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                attempts:(NSInteger)attempts interval:(NSTimeInterval)interval {
    if ([self attachToContainer:container inWindowScene:windowScene]) return;
    if (attempts <= 0) { SPLog(@"attach gave up %@", self.bundleID); return; }
    __weak typeof(self) wself = self;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || self->_attached) return;
        [self attachWhenReady:wc inWindowScene:ws attempts:attempts - 1 interval:interval];
    });
}

- (void)setFrameSize:(CGSize)size {
    if (!_containerView) return;
    CGSize r = CGSizeMake(round(size.width), round(size.height));
    if (r.width < 2 || r.height < 2) return;
    if (CGSizeEqualToSize(r, _lastSize)) return;
    _lastSize = r;
    _hostView.frame = (CGRect){CGPointZero, r};
    _snapshotView.frame = (CGRect){CGPointZero, r};
    SEL refSel = NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:");
    if ([_hostView respondsToSelector:refSel])
        ((void (*)(id, SEL, CGSize, NSInteger, NSInteger))objc_msgSend)(_hostView, refSel, r, 1, 1);
}

- (BOOL)refreshLiveness {
    if (!_attached) return NO;
    BOOL alive = YES;
    if (_scene) {
        if ([_scene respondsToSelector:NSSelectorFromString(@"isValid")] && !SPBool0(_scene, @"isValid")) alive = NO;
    }
    // 活层里什么都没有 = 画面已经被系统收走
    if (alive && _hostView) {
        CALayer *layer = _hostView.layer;
        if (layer.sublayers.count == 0 && _hostView.subviews.count == 0) alive = NO;
    }
    if (!alive && !_snapshotActive) {
        _snapshotActive = YES;
        _hostView.hidden = YES;
        _snapshotView.hidden = NO;
    }
    _live = alive;
    return alive;
}

- (void)detach {
    [_hostView removeFromSuperview];
    [_snapshotView removeFromSuperview];
    _hostView = nil;
    _snapshotView = nil;
    _attached = NO;
    _live = NO;
    _handle = nil;
    _scene = nil;
}

- (void)dealloc {
    [_hostView removeFromSuperview];
    [_snapshotView removeFromSuperview];
}

@end