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
@property (nonatomic, assign) CGSize referenceSize;
- (void)detach;   // 前向声明：attach 内部要先拆旧宿主
@property (nonatomic, strong) id handle;
@property (nonatomic, strong) SPHostRequester *requester;
@property (nonatomic, strong) id controller;
@property (nonatomic, assign, readwrite) BOOL live;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, strong) NSDictionary *originalSettings;   // frame/orientation 原值
@property (nonatomic, assign) BOOL touchedSettings;
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
    if (!mgr) { SPLog(@"fbScene %@: no FBSceneManager", bundleID); return nil; }

    SEL enumSel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if ([mgr respondsToSelector:enumSel]) {
        // ⚠️ 这个 block 是单参数 ^(id scene)。写成 ^(id, BOOL*) 会参数不匹配抛异常，
        // 被 @catch 吞掉后看起来「一个 scene 都没有」—— 0.3.2 的 no-scene 就是这么来的。
        __block id match = nil;
        __block NSUInteger scanned = 0;
        void (^block)(id) = ^(id candidate) {
            @try {
                scanned++;
                id proc = SPMsg0(candidate, @"clientProcess");
                NSString *bundle = SPMsg0(proc, @"bundleIdentifier");
                if (![bundle isKindOfClass:[NSString class]]) {
                    id info = SPMsg0(proc, @"applicationInfo");
                    bundle = SPMsg0(info, @"bundleIdentifier");
                }
                BOOL same = [bundle isKindOfClass:[NSString class]] &&
                            [(NSString *)bundle isEqualToString:bundleID];
                if (!same) {
                    NSString *ident = SPMsg0(candidate, @"identifier");
                    if ([ident isKindOfClass:[NSString class]]) {
                        same = [(NSString *)ident isEqualToString:bundleID] ||
                               [(NSString *)ident hasPrefix:[@"sceneID:" stringByAppendingString:bundleID]];
                    }
                }
                if (same && !match) match = candidate;
            } @catch (__unused NSException *e) {}
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, enumSel, block);
            SPLog(@"fbScene scan %@: scanned=%lu match=%@", bundleID, (unsigned long)scanned,
                  match ? NSStringFromClass([match class]) : @"nil");
        } @catch (NSException *e) {
            SPLog(@"fbScene enum ex %@", e.reason);
        }
        if (match) return match;
    } else {
        SPLog(@"fbScene: no enumerateScenesWithBlock: on %@", NSStringFromClass([mgr class]));
    }

    // 降级 A：从 App 自己的窗口树反查（刚激活的 App 常常在这里先有）
    @try {
        id app = [self applicationProxyForBundleID:bundleID];
        id scenes = SPMsg0(app, @"scenes");
        if ([scenes isKindOfClass:[NSSet class]]) scenes = [(NSSet *)scenes allObjects];
        if ([scenes isKindOfClass:[NSArray class]] && [(NSArray *)scenes count]) {
            SPLog(@"fbScene via app.scenes count=%lu", (unsigned long)[(NSArray *)scenes count]);
            return [(NSArray *)scenes firstObject];
        }
        id hs = SPMsg0(app, @"sceneHandles");
        if ([hs isKindOfClass:[NSArray class]] && [(NSArray *)hs count]) {
            for (id h in hs) {
                id sc = SPMsg0(h, @"scene");
                if (!sc) sc = SPMsg0(h, @"sceneIfExists");
                if (sc) { SPLog(@"fbScene via %@", NSStringFromClass([h class])); return sc; }
            }
        }
    } @catch (__unused NSException *e) {}

    // 降级 B：workspace 的 scene 字典
    @try {
        id workspace = SPMsg0(mgr, @"_workspace");
        for (NSString *key in @[@"_allScenesByID", @"_scenesByIdentifier", @"_scenesByID"]) {
            NSDictionary *map = SPMsg0(workspace, key);
            if (![map isKindOfClass:[NSDictionary class]]) continue;
            for (id ident in map) {
                if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident containsString:bundleID]) {
                    SPLog(@"fbScene via %@", key);
                    return map[ident];
                }
            }
        }
    } @catch (__unused NSException *e) {}
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

// ⚠️⚠️ 两件事都别做：
//   1) 别调 SBMainWorkspace 的 open*（实测同步阻塞 10 秒）
//   2) 也别在调用线程里直接调 LSApplicationWorkspace.openApplicationWithBundleID:
//      日志实证它同样阻塞 10007ms（0.4.2：`-> 0 (10007ms)`）
// 唯一安全的做法：扔到后台队列，立刻返回。UI 不等人。
+ (BOOL)openAppAsync:(NSString *)bundleID completion:(void (^)(BOOL))completion {
    if (!bundleID.length) return NO;
    if ([self fbSceneForBundleID:bundleID]) {
        SPLog(@"open %@ skipped (already has scene)", bundleID);
        if (completion) completion(YES);
        return YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Class lsw = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = lsw ? SPMsg0(lsw, @"defaultWorkspace") : nil;
        BOOL ok = NO;
        for (NSString *sn in @[@"openApplicationWithBundleID:", @"openApplicationWithBundleIdentifier:"]) {
            SEL sel = NSSelectorFromString(sn);
            if (![workspace respondsToSelector:sel]) continue;
            @try {
                CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
                ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, sel, bundleID);
                SPLog(@"open %@ async via LS.%@ -> %d (%.0fms off-main)", bundleID, sn, (int)ok,
                      (CFAbsoluteTimeGetCurrent() - t0) * 1000);
                break;
            } @catch (NSException *e) { SPLog(@"LS open ex %@", e.reason); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ok); });
    });
    return YES;
}

+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL))completion {
    return [self openAppAsync:bundleID completion:completion];
}

+ (void)reactivateApp:(NSString *)bundleID {
    if (!bundleID.length) return;
    // activateApplication: 只切前台身份，不启动进程，不会卡
    Class wsCls = NSClassFromString(@"SBWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"mainWorkspace") : nil;
    if (!ws) wsCls = NSClassFromString(@"SBMainWorkspace"), ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    id app = [self applicationProxyForBundleID:bundleID];
    SEL sel = NSSelectorFromString(@"activateApplication:withResult:");
    if (!ws || !app || ![ws respondsToSelector:sel]) return;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(ws, sel, app, ^(BOOL ok) {
            SPLog(@"reactivate %@ -> %d", bundleID, (int)ok);
        });
    } @catch (NSException *e) { SPLog(@"reactivate ex %@", e.reason); }
}

// 把 App 退到后台：让它自己的 scene「收起」，SpringBoard 自然回桌面。
// 不杀进程 —— SIGKILL 会让 SpringBoard 认为 App 崩溃，可能触发重启。
+ (BOOL)suspendAppToBackground:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    // 优先：SBMainWorkspace 的 home 请求
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    for (NSString *sn in @[@"requestForTransitionToHomeScreen", @"_handleHomeButtonSinglePress"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ws && [ws respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ws, sel); SPLog(@"suspend via %@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    // 次选：SBUIController 的菜单键
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    for (NSString *sn in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ui && [ui respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ui, sel); SPLog(@"suspend via SBUIController.%@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    SPLog(@"suspend: no API available");
    return NO;
}

// 让一个「有 scene 但不出画面」的 App 重新渲染：
// 切到后台再切回前台。contentState=0 说明它释放了渲染，只有重新激活才会重建。
+ (void)forceRecycleApp:(NSString *)bundleID {
    if (!bundleID.length) return;
    SPLog(@"recycle %@ (scene contentState stuck)", bundleID);
    @try {
        // 1) 先让它退到后台
        Class uic = NSClassFromString(@"SBUIController");
        id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
        for (NSString *sn in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
            SEL sel = NSSelectorFromString(sn);
            if (ui && [ui respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(ui, sel);
                break;
            }
        }
        // 2) 隔 0.35s 再拉回前台，触发 scene 重建
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reactivateApp:bundleID];
            SPLog(@"recycle %@ reactivated", bundleID);
        });
    } @catch (NSException *e) { SPLog(@"recycle ex %@", e.reason); }
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

static BOOL SPSubmitSceneSettings(id scene, CGSize pane, NSInteger orient, NSString **diag) {
    return SPSubmitSceneSettingsEx(scene, pane, orient, YES, diag);
}

// 把面板尺寸写进 scene settings。不推这一下，画面仍按全屏渲染，host 是空的。
// 工厂出来的 SBDeviceApplicationSceneView 默认不渲染：必须关掉占位内容、
// 关掉「宿主缩放上下文」、并把 displayMode 设成 4（活画面）。
// 少任何一步，视图就是一块黑（0.3.1 的黑屏就是这么来的）。
static void SPPrepareSceneHost(UIView *v, NSMutableString *diag) {
    if (!v) return;
    @try {
        SEL ph = NSSelectorFromString(@"setPlaceholderContentEnabled:");
        BOOL hasPh = [v respondsToSelector:ph];
        if (hasPh) ((void (*)(id, SEL, BOOL))objc_msgSend)(v, ph, NO);
        SEL rz = NSSelectorFromString(@"setResizesHostedContext:");
        BOOL hasRz = [v respondsToSelector:rz];
        if (hasRz) ((void (*)(id, SEL, BOOL))objc_msgSend)(v, rz, NO);
        SEL dm = NSSelectorFromString(@"setDisplayMode:animationFactory:completion:");
        BOOL hasDm = [v respondsToSelector:dm];
        if (hasDm) ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(v, dm, 4, nil, nil);
        v.userInteractionEnabled = YES;
        if (diag) [diag appendFormat:@" prep=ph%d rz%d dm%d", hasPh, hasRz, hasDm];
    } @catch (NSException *e) {
        if (diag) [diag appendString:[NSString stringWithFormat:@" prep!(%@)", e.reason]];
    }
}

static BOOL SPSubmitSceneSettingsEx(id scene, CGSize pane, NSInteger orient, BOOL touchForeground, NSString **diag) {
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
        // 前台化，否则后台 scene 停渲染。恢复时绝不做 ——
        // 退出后把 App 推进前台会把桌面挡在后面，表现就是「桌面点不了」。
        SEL fgGet = NSSelectorFromString(@"isForeground");
        if (!touchForeground) { /* 不动前台状态 */ }
        else if ([desired respondsToSelector:fgGet]) {
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


// 把按 referenceSize 渲染的 host 铺满 container（cover）：取 MAX(sx,sy)，
// 画面覆盖整个容器，超出的部分由容器 clipsToBounds 裁掉。
// 之前用 MIN（contain）导致画面只占 60% 宽、四周大片留白 —— 用户明确要求铺满。
static void SPFitHostView(UIView *host, UIView *container, CGSize reference) {
    if (!host || !container || reference.width < 2 || reference.height < 2) return;
    CGSize c = container.bounds.size;
    if (c.width < 2 || c.height < 2) {
        // 容器还没 layout（bounds 为 0）时不要裸 return，否则画面不显示 = 整块黑。
        // 退回按参考尺寸原样放置，等 layout 完成后再由 setFrameSize 纠正。
        c = reference;
    }
    CGFloat sx = c.width / reference.width;
    CGFloat sy = c.height / reference.height;
    // 参考尺寸就是容器尺寸时 s≈1.0（精确铺满）；有微小偏差时用 MAX 补齐，避免露边
    CGFloat s = MAX(sx, sy);
    host.transform = CGAffineTransformIdentity;
    host.frame = CGRectMake(0, 0, reference.width, reference.height);
    host.transform = CGAffineTransformMakeScale(s, s);
    // 居中：超出容器的部分两边对称裁掉
    host.center = CGPointMake(c.width / 2.0, c.height / 2.0);
}

- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    if (!container) return NO;
    _containerView = container;
    if (_attached && _hostView && _hostView.superview == container) return YES;

    // 每次重新 attach 前把旧宿主彻底摘掉。
    // 不拆就叠多个 SBDeviceApplicationSceneView 渲染同一个 FBScene：既卡顿，
    // 又会在容器被替换时留下挂在死容器上的宿主（日志里的 "container gone"）。
    [self detach];

    // 按容器真实尺寸推 scene：App 会按「半屏正方形」重新排版，内容自然铺满，不裁剪不失真。
    // （用户选定方案。之前固定全屏 + MIN 缩放会留下大片留白，MAX 缩放会裁掉左右。）
    CGSize ref = container.bounds.size;
    if (ref.width < 2 || ref.height < 2) ref = [UIScreen mainScreen].bounds.size;
    _referenceSize = ref;
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
        [self detach];   // 失败也要清干净，否则下次重试会叠一个新的宿主
        return NO;
    }

    // 4) 推 scene settings：不推的话画面还是全屏，host 是空的
    // 在改任何东西之前，先把原始 frame / orientation 记下来
    [self captureOriginalSettings];

    NSMutableString *prepDiag = [NSMutableString string];
    SPPrepareSceneHost(host, prepDiag);

    NSString *sub = nil;
    BOOL sent = SPSubmitSceneSettings(scene, ref, orient, &sub);
    _lastDiag = [NSString stringWithFormat:@"%@%@/%@", _lastDiag, prepDiag, sub ?: @"-"];

    // 等比缩放：scene 按 ref 全屏渲染，容器只有半屏，取 MIN(sx,sy) 并居中
    // 容器底色给个深灰：等比缩放后两侧留白是「设计如此」，不是渲染失败的黑屏
    if (!container.backgroundColor || CGColorGetAlpha(container.backgroundColor.CGColor) < 0.01) {
        container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    }
    // 顺序必须：先 addSubview 再定位。
    // 先设 center 时 host 还没有父视图，center 没有参照系 → 画面飘到容器外 = 整块黑。
    host.autoresizingMask = UIViewAutoresizingNone;
    host.userInteractionEnabled = YES;
    [container addSubview:host];
    [container layoutIfNeeded];
    SPFitHostView(host, container, _referenceSize);
    _hostView = host;
    _attached = YES;
    _live = YES;
    _snapshotActive = NO;
    SPLog(@"attach OK %@ diag=%@ sent=%d view=%@ bounds=%@", _bundleID, _lastDiag, sent,
          NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));

    // 画面自检：1.2s 后如果宿主里依然没有渲染内容，就露出快照（宁可显示旧画面也不给灰屏）
    __weak typeof(self) wself = self;
    __weak UIView *whost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || !whost || whost.superview == nil) return;
        // ⚠️ 不能用 subviews/layers 数量判断：建出来的空 sceneView 也有 1 个图层，
        // 日志里「subviews=1 layers=1 -> live」但屏幕是黑的，就是这个原因。
        // 真正的依据是 scene 的内容状态：contentState == 2 且 scene 有效。
        BOOL hasContent = NO;
        @try {
            id sc = self->_scene;
            NSInteger cs = -1;
            SEL csSel = NSSelectorFromString(@"contentState");
            if (sc && [sc respondsToSelector:csSel])
                cs = ((NSInteger (*)(id, SEL))objc_msgSend)(sc, csSel);
            BOOL valid = sc ? SPBool0(sc, @"isValid") : NO;
            hasContent = valid && (cs == 2 || cs == 1);
            SPLog(@"content check %@: contentState=%ld valid=%d subviews=%lu -> %@", self->_bundleID,
                  (long)cs, (int)valid, (unsigned long)whost.subviews.count,
                  hasContent ? @"live" : @"not-ready");
        } @catch (NSException *e) { SPLog(@"content check ex %@", e.reason); }
        if (!hasContent && self->_snapshotView) {
            // 没就绪：先用快照垫住，别露黑；同时轮询等它真正出画面
            whost.hidden = YES;
            self->_snapshotView.hidden = NO;
            self->_snapshotActive = YES;
            [self waitForContentReady:8];
        }
    });
    return YES;
}

- (void)attachWhenReady:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                attempts:(NSInteger)attempts interval:(NSTimeInterval)interval {
    if ([self attachToContainer:container inWindowScene:windowScene]) return;
    if (attempts <= 0) { SPLog(@"attach gave up %@", self.bundleID); return; }
    __weak typeof(self) wself = self;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    // 容器已经不在屏幕上（用户退出了分屏）就停手，别在后台一直扫
    if (!container.window) { SPLog(@"attach abandon %@ (container gone)", self.bundleID); return; }
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
    _referenceSize = r;
    // 不能用 _hostView.frame = r 硬拉：那会把画面拉伸变形。
    // 统一走 SPFitHostView 等比处理（先按新尺寸排版，再 cover 铺进容器）。
    if (_hostView && _containerView) {
        SPFitHostView(_hostView, _containerView, r);
    } else {
        _hostView.frame = (CGRect){CGPointZero, r};
    }
    _snapshotView.frame = (CGRect){CGPointZero, r};
    NSInteger orient = (r.width > r.height) ? 4 : 1;
    NSString *sub = nil;
    // 调尺寸时绝不改前台状态：把 App 反复推前台会导致画面闪黑
    SPSubmitSceneSettingsEx(_scene, r, orient, NO, &sub);
}

// 等 scene 真正渲染出内容再换上活画面（首次分屏时下面那个 App 常还在启动）
- (void)waitForContentReady:(int)tries {
    if (tries <= 0) { SPLog(@"content never ready: %@", _bundleID); return; }
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || !self->_hostView) return;
        BOOL ready = NO;
        @try {
            id sc = self->_scene;
            NSInteger cs = -1;
            SEL csSel = NSSelectorFromString(@"contentState");
            if (sc && [sc respondsToSelector:csSel])
                cs = ((NSInteger (*)(id, SEL))objc_msgSend)(sc, csSel);
            ready = sc && SPBool0(sc, @"isValid") && (cs == 2 || cs == 1);
        } @catch (__unused NSException *e) {}
        if (ready) {
            self->_hostView.hidden = NO;
            self->_snapshotView.hidden = YES;
            self->_snapshotActive = NO;
            SPLog(@"content ready: %@", self->_bundleID);
        } else {
            [self waitForContentReady:tries - 1];
        }
    });
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

- (void)captureOriginalSettings {
    if (_touchedSettings) return;
    @try {
        id settings = SPGet(_scene, @"settings");
        if (!settings) return;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        SEL fGet = NSSelectorFromString(@"frame");
        if ([settings respondsToSelector:fGet]) {
            CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(settings, fGet);
            d[@"frame"] = [NSValue valueWithCGRect:f];
        }
        SEL ioGet = NSSelectorFromString(@"interfaceOrientation");
        if ([settings respondsToSelector:ioGet])
            d[@"orientation"] = @(((NSInteger (*)(id, SEL))objc_msgSend)(settings, ioGet));
        _originalSettings = d;
        _touchedSettings = YES;
        SPLog(@"scene %@ original frame=%@", _bundleID,
              d[@"frame"] ? NSStringFromCGRect([d[@"frame"] CGRectValue]) : @"?");
    } @catch (NSException *e) { SPLog(@"capture settings ex %@", e.reason); }
}

- (void)restoreOriginalSceneSettings {
    if (!_touchedSettings || !_scene || !_originalSettings) return;
    NSValue *frameVal = _originalSettings[@"frame"];
    NSNumber *oriVal = _originalSettings[@"orientation"];
    if (!frameVal) return;
    // 退出时恢复成全屏尺寸：App 回到系统正常布局，否则它一直按半屏渲染 → 黑/灰
    // 1) 先原样写回接管前的 frame（最保守）
    CGRect orig = [frameVal CGRectValue];
    CGRect screen = [UIScreen mainScreen].bounds;
    CGSize target = orig.size;
    // 原值是半屏尺寸（我们接管后才记录的）就改用屏幕尺寸
    if (target.width < 2 || target.height < screen.size.height * 0.9) target = screen.size;
    NSString *sub = nil;
    SPSubmitSceneSettingsEx(_scene, target, oriVal ? oriVal.integerValue : 1, NO, &sub);
    SPLog(@"scene %@ restore target=%.0fx%.0f (orig=%.0fx%.0f)", _bundleID,
          target.width, target.height, orig.size.width, orig.size.height);
    SPLog(@"scene %@ restored to %.0fx%.0f (%@)", _bundleID, screen.size.width, screen.size.height, sub ?: @"-");
    // 回读确认：没生效就说明推错了地方，必须写日志（否则用户看到的就是「App 坏了」）
    @try {
        id settings = SPGet(_scene, @"settings");
        SEL fGet = NSSelectorFromString(@"frame");
        if (settings && [settings respondsToSelector:fGet]) {
            CGRect now = ((CGRect (*)(id, SEL))objc_msgSend)(settings, fGet);
            SPLog(@"scene %@ now reads %.0fx%.0f", _bundleID, now.size.width, now.size.height);
            if (now.size.height < screen.size.height * 0.9) {
                // 没生效：再推一次，用 2 参数版本
                SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
                id settings2 = SPGet(_scene, @"settings");
                id desired = SPMsg0(settings2, @"mutableCopy");
                SEL setF = NSSelectorFromString(@"setFrame:");
                if (desired && [desired respondsToSelector:setF]) {
                    ((void (*)(id, SEL, CGRect))objc_msgSend)(desired, setF,
                        CGRectMake(0, 0, screen.size.width, screen.size.height));
                    SPSetI(desired, @"setInterfaceOrientation:", oriVal ? oriVal.integerValue : 1);
                    id imm = SPMsg0(desired, @"copy");
                    if (imm && [_scene respondsToSelector:upd2])
                        ((void (*)(id, SEL, id, id))objc_msgSend)(_scene, upd2, imm, nil);
                    SPLog(@"scene %@ retried restore", _bundleID);
                }
            }
        }
    } @catch (NSException *e) { SPLog(@"verify ex %@", e.reason); }
    _touchedSettings = NO;
}

- (void)detach {
    // ⚠️ 顺序很重要：先主动放弃 scene 的呈现权，再把视图摘下来。
    // 只 removeFromSuperview 的话，scene 仍认为我们在渲染它 →
    // 拆窗后它没有别的 present，画面不再刷新 → 再次打开就是灰屏/黑屏。
    @try {
        if (_hostView) {
            // ⚠️ 这里不再推全屏参考尺寸。
            // 改尺寸要等 hostView 摘掉之后由 restoreOriginalSceneSettings 统一做，
            // 否则「半屏视图 + 全屏 settings」同时存在，那一帧就是黑的。
            // 有些版本提供 invalidate / 释放接口，存在就调
            for (NSString *selName in @[@"invalidate", @"detachScene"]) {
                SEL sel = NSSelectorFromString(selName);
                if (![_hostView respondsToSelector:sel]) continue;
                @try { ((void (*)(id, SEL))objc_msgSend)(_hostView, sel); }
                @catch (__unused NSException *e) {}
            }
        }
    } @catch (NSException *e) { SPLog(@"detach prep ex %@", e.reason); }

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