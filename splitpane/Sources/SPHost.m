#import "SPHost.h"
#import "SPSettings.h"
#import "SPLog.h"
#import <objc/runtime.h>

// ════════════════════════════════════════════════════════════════════════════
// 一个 App 的画面。真实链路（抄 Duo 在 16.4.1 上跑通的实证，不是猜）：
//
//   1) FBSceneManager enumerateScenesWithBlock → 按 clientProcess.bundleIdentifier
//      找到真 FBScene（SBApplication.mainScene 不是 FBScene）
//   2) SBMainWorkspace.mainWindowScene.sceneManager existingSceneHandleForScene:
//      → 拿到真正拥有工厂的句柄
//   3) 句柄上唯一存在的工厂：
//      newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:
//      （本机没有 newSceneViewWithReferenceSize: 单参版，日志实证 0.2.2 三个都 n）
//   4) 必须推 FBScene.updateSettings:，否则画面仍按全屏渲染，host 是空的
//
// 日志实证（0.2.2）：newSceneViewWithReferenceSize=n / createSceneView=n /
// initWithScene=n，allScenes=0 —— 全是我猜错了名字。
// ════════════════════════════════════════════════════════════════════════════

@implementation SPHostRequester
- (instancetype)init {
    if ((self = [super init]))
        _presentationIdentifier = [@"com.seagull.splitpane.host."
                                   stringByAppendingString:NSUUID.UUID.UUIDString];
    return self;
}
- (NSString *)sceneViewPresentationIdentifier:(id)view { (void)view; return self.presentationIdentifier; }
- (long long)sceneViewPresentationPriority:(id)view { (void)view; return 1; }
@end

@interface SPHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, weak, readwrite) UIView *containerView;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIImageView *snapshotView;
@property (nonatomic, strong) id scene;
@property (nonatomic, strong) id handle;
@property (nonatomic, strong) SPHostRequester *requester;
@property (nonatomic, strong) id controller;
@property (nonatomic, assign, readwrite) BOOL live;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) CGSize lastSize;
@end

@implementation SPHost

#pragma mark - 场景入口

+ (id)mainDisplaySceneManager {
    Class coord = NSClassFromString(@"SBSceneManagerCoordinator");
    if (coord) {
        id m = SPMsg0(coord, @"mainDisplaySceneManager");
        if (!m) m = SPMsg0(coord, @"secureMainDisplaySceneManager");
        if (m) return m;
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

static BOOL SPObjectMatchesBundleID(id obj, NSString *bundleID) {
    if (!obj) return NO;
    @try {
        id proc = SPMsg0(obj, @"clientProcess");
        if (proc) {
            id ca = SPMsg0(proc, @"bundleIdentifier");
            if ([ca isKindOfClass:[NSString class]] && [(NSString *)ca isEqualToString:bundleID]) return YES;
        }
        id app = SPMsg0(obj, @"application");
        if (app) {
            id a = SPMsg0(app, @"bundleIdentifier");
            if ([a isKindOfClass:[NSString class]] && [(NSString *)a isEqualToString:bundleID]) return YES;
        }
        id ident = SPMsg0(obj, @"identifier");
        if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident containsString:bundleID]) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

// 真的 FBScene：靠 FBSceneManager 枚举 + clientProcess.bundleIdentifier 比对。
// allScenes / mainScene 都不是 FBScene，这是 Duo 0.7.91 的定案。
+ (id)fbSceneForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    id mgr = mgrCls ? SPMsg0(mgrCls, @"sharedInstance") : nil;
    if (mgr) {
        SEL enumSel = NSSelectorFromString(@"enumerateScenesWithBlock:");
        if ([mgr respondsToSelector:enumSel]) {
            __block id found = nil;
            void (^block)(id, BOOL *) = ^(id scene, BOOL *stop) {
                if (SPObjectMatchesBundleID(scene, bundleID)) { found = scene; if (stop) *stop = YES; }
            };
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(mgr, enumSel, block);
            } @catch (NSException *e) { SPLog(@"fbScene enum ex %@", e.reason); }
            if (found) return found;
        }
        // 降级：workspace 的 scene 字典
        @try {
            id workspace = SPMsg0(mgr, @"_workspace");
            for (NSString *key in @[@"_allScenesByID", @"_scenesByIdentifier", @"_scenesByID"]) {
                NSDictionary *map = SPMsg0(workspace, key);
                if (![map isKindOfClass:[NSDictionary class]]) continue;
                for (id ident in map) {
                    if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident containsString:bundleID])
                        return map[ident];
                }
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// 从 FBScene 反查真正拥有工厂的句柄（Duo 0.7.87 的 ZNS 口径）
+ (id)sceneHandleForScene:(id)scene {
    if (!scene) return nil;
    @try {
        Class wsCls = NSClassFromString(@"SBMainWorkspace");
        id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
        id mainScene = SPMsg0(ws, @"mainWindowScene");
        id mgr = SPMsg0(mainScene, @"sceneManager");
        SEL look = NSSelectorFromString(@"existingSceneHandleForScene:");
        if (mgr && [mgr respondsToSelector:look]) {
            id h = ((id (*)(id, SEL, id))objc_msgSend)(mgr, look, scene);
            if (h) return h;
        }
    } @catch (NSException *e) { SPLog(@"handleForScene ex %@", e.reason); }

    id mgr = [self mainDisplaySceneManager];
    for (NSString *name in @[@"externalForegroundApplicationSceneHandles",
                             @"externalApplicationSceneHandles",
                             @"applicationSceneHandles", @"sceneHandles"]) {
        @try {
            id set = SPMsg0(mgr, name);
            if (!set) continue;
            NSArray *arr = nil;
            if ([set isKindOfClass:[NSArray class]]) arr = set;
            else if ([set respondsToSelector:@selector(allObjects)]) arr = [(NSSet *)set allObjects];
            for (id h in arr) {
                id s = SPMsg0(h, @"scene");
                if (s == scene) return h;
                if (SPObjectMatchesBundleID(h, self.class ? @"" : @"")) {}
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// 回桌面。SBUIController 在这台机器上没有那两个方法（日志 homePress=n），
// 所以多路探测：SBUIController / SBMainWorkspace / SBScreenFlash 之类的菜单键入口。
static NSMutableSet *gHomeTried = nil;

+ (NSString *)homePressDiag {
    return gHomeTried.count ? [[gHomeTried allObjects] componentsJoinedByString:@","] : @"none";
}

+ (BOOL)homePress {
    static NSArray *classes = nil;
    static NSArray *sels = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes = @[@"SBUIController", @"SBMainWorkspace", @"SBHomeHardwareButton",
                    @"SBHomeButtonController", @"SBMainDisplayPolicyAggregator"];
        sels = @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton",
                 @"_handleMenuButtonDown", @"handleMenuButtonSinglePress",
                 @"handleMenuButtonDownAndUp", @"pressHomeButton"];
    });
    gHomeTried = [NSMutableSet set];
    for (NSString *cn in classes) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        id inst = nil;
        if ([c respondsToSelector:NSSelectorFromString(@"sharedInstance")])
            inst = SPMsg0(c, @"sharedInstance");
        if (!inst && [c respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")])
            inst = SPMsg0(c, @"sharedInstanceIfExists");
        id target = inst ?: (id)c;
        for (NSString *sn in sels) {
            SEL sel = NSSelectorFromString(sn);
            if (![target respondsToSelector:sel]) continue;
            @try {
                ((void (*)(id, SEL))objc_msgSend)(target, sel);
                [gHomeTried addObject:[NSString stringWithFormat:@"%@.%@", cn, sn]];
                SPLog(@"homePress via %@.%@", cn, sn);
                return YES;
            } @catch (NSException *e) {
                [gHomeTried addObject:[NSString stringWithFormat:@"%@.%@(ex)", cn, sn]];
            }
        }
    }
    // 最后一招：把 springboard 托管的「回桌面」请求交给 workspace
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    SEL req = NSSelectorFromString(@"requestForTransitionToHomeScreen");
    if (ws && [ws respondsToSelector:req]) {
        @try {
            id r = ((id (*)(id, SEL))objc_msgSend)(ws, req);
            SPLog(@"homePress via workspace request=%@", r);
            return YES;
        } @catch (__unused NSException *e) {}
    }
    SPLog(@"homePress: none available");
    return NO;
}

+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL))completion {
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
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
    id app = [self applicationProxyForBundleID:bundleID];
    if (!app) return NO;
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    SEL sel = NSSelectorFromString(@"activateApplication:withResult:");
    if (ws && [ws respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(ws, sel, app, ^(BOOL ok) {
            if (completion) completion(ok);
        });
        return YES;
    }
    return NO;
}

#pragma mark - 规范 IFBSceneSettings

static id SPGet(id o, NSString *name) {
    if (!o) return nil;
    @try {
        SEL s = NSSelectorFromString(name);
        if ([o respondsToSelector:s]) return ((id (*)(id, SEL))objc_msgSend)(o, s);
        return [o valueForKey:name];
    } @catch (__unused NSException *e) { return nil; }
}

static BOOL SPSetI(id o, NSString *name, NSInteger v) {
    @try {
        SEL s = NSSelectorFromString(name);
        if (![o respondsToSelector:s]) return NO;
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(o, s, v);
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

// 把面板尺寸写进 scene settings。不推这一下，画面仍按全屏渲染，host 是空的。
static BOOL SPSubmitSceneSettings(id scene, CGSize pane, NSInteger orient, NSString **diag) {
    if (diag) *diag = nil;
    if (!scene) { if (diag) *diag = @"no-scene"; return NO; }
    @try {
        id settings = SPGet(scene, @"settings");
        if (!settings) { if (diag) *diag = @"no-settings"; return NO; }
        id desired = SPMsg0(settings, @"mutableCopy");
        if (!desired) { if (diag) *diag = @"copy-nil"; return NO; }
        SEL setFrameSel = NSSelectorFromString(@"setFrame:");
        if (![desired respondsToSelector:setFrameSel]) { if (diag) *diag = @"no-setFrame"; return NO; }
        ((void (*)(id, SEL, CGRect))objc_msgSend)(desired, setFrameSel,
            CGRectMake(0, 0, pane.width, pane.height));
        SPSetI(desired, @"setInterfaceOrientation:", orient);
        NSInteger dev = SPInt0(settings, @"deviceOrientation");
        SPSetI(desired, @"setDeviceOrientation:", dev);
        // 前台化，否则后台 scene 停渲染
        SEL fgGet = NSSelectorFromString(@"isForeground");
        if ([desired respondsToSelector:fgGet]) {
            SEL setFg = NSSelectorFromString(@"setForeground:");
            if ([desired respondsToSelector:setFg]) ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, setFg, YES);
        } else {
            SEL bgGet = NSSelectorFromString(@"isBackgrounded");
            if ([desired respondsToSelector:bgGet]) {
                SEL setBg = NSSelectorFromString(@"setBackgrounded:");
                if ([desired respondsToSelector:setBg]) ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, setBg, NO);
            }
        }
        id immutable = SPMsg0(desired, @"copy");
        if (!immutable) { if (diag) *diag = @"immutable-nil"; return NO; }
        SEL upd = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:upd]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd, immutable, nil, nil);
            if (diag) *diag = @"sent3";
            return YES;
        }
        SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:upd2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, upd2, immutable, nil);
            if (diag) *diag = @"sent2";
            return YES;
        }
        if (diag) *diag = @"no-updateSettings";
    } @catch (NSException *e) {
        if (diag) *diag = [NSString stringWithFormat:@"ex %@", e.reason];
    }
    return NO;
}

#pragma mark - 实例

- (instancetype)initWithBundleID:(NSString *)bundleID {
    if ((self = [super init])) {
        _bundleID = [bundleID copy];
        _requester = [SPHostRequester new];
    }
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



// 工厂可能直接返回 UIView，也可能返回 view controller；后者必须被强引用住，
// 否则 VC 一释放就把 view 一起带走（Duo 0.7.x 踩过）。
- (UIView *)viewFromResultRetaining:(id)result {
    if ([result isKindOfClass:[UIView class]]) return (UIView *)result;
    if (result && [result respondsToSelector:@selector(view)]) {
        self.controller = result;
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(result, @selector(view));
        if ([v isKindOfClass:[UIView class]]) return v;
    }
    return nil;
}

- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    if (!container) return NO;
    _containerView = container;
    if (_attached && _hostView && _hostView.superview == container) return YES;

    CGSize ref = container.bounds.size;
    if (ref.width < 2 || ref.height < 2) ref = [UIScreen mainScreen].bounds.size;
    _lastSize = ref;
    NSInteger orient = (ref.width > ref.height) ? 4 : 1;

    // 1) 真 FBScene
    id scene = [SPHost fbSceneForBundleID:_bundleID];
    if (!scene) {
        // 降级：App 未运行时先拉起来
        _lastDiag = @"no-scene";
        return NO;
    }
    _scene = scene;

    // 2) 拥有工厂的句柄
    id handle = [SPHost sceneHandleForScene:scene];
    if (!handle) handle = scene;      // 有些机型 scene 自己就暴露工厂

    // 3) 唯一存在的工厂（本机只有这个）
    UIView *host = nil;
    SEL viewSel = NSSelectorFromString(
        @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:");
    if ([handle respondsToSelector:viewSel]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:viewSel];
        if (sig) {
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle;
                inv.selector = viewSel;
                [inv setArgument:&ref atIndex:2];
                [inv setArgument:&orient atIndex:3];
                [inv setArgument:&orient atIndex:4];
                SPHostRequester *req = _requester;
                [inv setArgument:&req atIndex:5];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                host = [self viewFromResultRetaining:result];
            } @catch (NSException *e) {
                SPLog(@"factory ex %@", e.reason);
            }
        }
    }
    if (host) _lastDiag = @"factory-sep";

    // 降级：另外两个变体（本机没有，留着给别的系统版本）
    if (!host) {
        SEL v2 = NSSelectorFromString(@"newSceneViewWithReferenceSize:orientation:hostRequester:");
        if ([handle respondsToSelector:v2]) {
            NSMethodSignature *sig = [handle methodSignatureForSelector:v2];
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle; inv.selector = v2;
                [inv setArgument:&ref atIndex:2];
                [inv setArgument:&orient atIndex:3];
                SPHostRequester *req = _requester;
                [inv setArgument:&req atIndex:4];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                host = [self viewFromResultRetaining:result];
            } @catch (__unused NSException *e) {}
            if (host) _lastDiag = @"factory-orient";
        }
    }
    if (!host) {
        // 最后兜底：已经存在的 sceneView（切换器里那个）
        id sv = SPMsg0(scene, @"sceneView");
        if ([sv isKindOfClass:[UIView class]]) { host = sv; _lastDiag = @"sceneView-prop"; }
    }
    _handle = handle;
    if (!host) {
        _lastDiag = _lastDiag ?: @"no-factory";
        SPLog(@"attach FAIL %@ diag=%@ handle=%@", _bundleID, _lastDiag,
              handle ? NSStringFromClass([handle class]) : @"nil");
        return NO;
    }

    // 4) 推 scene settings：不推的话画面还是全屏，host 是空的
    NSString *sub = nil;
    BOOL sent = SPSubmitSceneSettings(scene, ref, orient, &sub);
    _lastDiag = [NSString stringWithFormat:@"%@/%@", _lastDiag, sub ?: @"-"];

    host.frame = container.bounds;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.userInteractionEnabled = YES;
    [container addSubview:host];
    _hostView = host;
    _attached = YES;
    _live = YES;
    _snapshotActive = NO;
    SPLog(@"attach OK %@ diag=%@ sent=%d view=%@ bounds=%@", _bundleID, _lastDiag, sent,
          NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));
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
    NSInteger orient = (r.width > r.height) ? 4 : 1;
    NSString *sub = nil;
    SPSubmitSceneSettings(_scene, r, orient, &sub);
}

- (BOOL)refreshLiveness {
    if (!_attached) return NO;
    BOOL alive = YES;
    if (_scene && [_scene respondsToSelector:NSSelectorFromString(@"isValid")] && !SPBool0(_scene, @"isValid"))
        alive = NO;
    if (alive && _hostView && _hostView.subviews.count == 0 && _hostView.layer.sublayers.count == 0)
        alive = NO;
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
    _scene = nil;
    _handle = nil;
    _controller = nil;
}

- (void)dealloc {
    [_hostView removeFromSuperview];
    [_snapshotView removeFromSuperview];
}

@end