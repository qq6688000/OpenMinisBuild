#import "SPHost.h"
#import "SPXferDrag.h"
#import <CoreMotion/CoreMotion.h>
#import <math.h>
#import "SPSettings.h"
#import "SPLog.h"
#import <objc/runtime.h>

static id SPGet(id o, NSString *name);
static BOOL SPSubmitSceneSettingsEx(id scene, CGSize pane, NSInteger orient,
                                    BOOL touchForeground, NSString **diag);

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
@end

void SPHostRegisterHostedBundleID(NSString *bundleID);
void SPHostUnregisterHostedBundleID(NSString *bundleID);
void SPHostClearHostedBundleIDs(void);

@interface SPHost ()
- (void)detach;   // 前向声明：attach 内部要先拆旧宿主
@property (nonatomic, strong) id handle;
@property (nonatomic, strong) SPHostRequester *requester;
@property (nonatomic, strong) id controller;
@property (nonatomic, assign, readwrite) BOOL live;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, assign) NSUInteger attachGeneration;
@property (nonatomic, weak) UIWindow *attachmentWindow;
@property (nonatomic, weak) UIWindowScene *attachmentWindowScene;
@property (nonatomic, strong) NSDictionary *originalSettings;   // 原始完整 frame（含 origin）
@property (nonatomic, strong) id originalScene;                // detach 后仍可重试恢复
@property (nonatomic, assign) BOOL touchedSettings;
- (BOOL)captureOriginalSettings;
- (BOOL)isCurrentAttachTarget:(NSUInteger)generation container:(UIView *)container
               inWindowScene:(UIWindowScene *)windowScene;
- (BOOL)isCurrentAttachment:(NSUInteger)generation host:(UIView *)host
                 container:(UIView *)container inWindowScene:(UIWindowScene *)windowScene;
- (BOOL)tryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                 generation:(NSUInteger)generation;
- (void)retryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                   generation:(NSUInteger)generation attempts:(NSInteger)attempts
                     interval:(NSTimeInterval)interval;
- (void)waitForContentReady:(int)tries generation:(NSUInteger)generation host:(UIView *)host
                 container:(UIView *)container inWindowScene:(UIWindowScene *)windowScene;
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


// 一次性把 SBUIController / SBMainWorkspace 上所有含 home/menu/返回 的方法打出来，
// 用于定名（不再猜）。
+ (void)dumpHomeAPIs {
    NSArray *classes = @[@"SBUIController", @"SBMainWorkspace", @"SBHomeScreenController",
                         @"SBMainSwitcherControllerCoordinator", @"SBWorkspace"];
    for (NSString *cn in classes) {
        Class c = NSClassFromString(cn);
        if (!c) { SPLog(@"homeAPI %@ = nil", cn); continue; }
        NSMutableArray *hits = [NSMutableArray array];
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!nm) continue;
            NSString *s = @(nm);
            if ([s rangeOfString:@"ome" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"enu" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"xpose" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"witch" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:s];
            }
        }
        free(ms);
        SPLog(@"homeAPI %@(%lu): %@", cn, (unsigned long)hits.count,
              [hits componentsJoinedByString:@" | "]);
    }
}


// 回桌面的第 3 条路：直接命令切换器回桌面。
// homePress 调用不抛异常（=1）但 SpringBoard 不一定真的转场（0.5.29 日志实证）。
// SBUIController 另有 handleHomeButtonDoublePressDown / 而 coordinator 上有
// dismissMainSwitcherNoninteractivelyAnimated: 和 activateMainSwitcherNoninteractivelyWithSource:animated:
+ (BOOL)forceHomeScreen {
    // 1) SBUIController 的双击 Down/Up 序列（等效连按两次 home）
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    for (NSString *sn in @[@"handleHomeButtonDoublePressDown", @"handleHomeButtonDoublePressUp"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ui && [ui respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ui, sel); SPLog(@"forceHome via %@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    // 2) coordinator：先让切换器显示桌面（activated 状态为 home）
    Class cc = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    id coord = cc ? SPMsg0(cc, @"sharedInstance") : nil;
    if (coord) {
        SEL d = NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:");
        if ([coord respondsToSelector:d]) {
            @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(coord, d, NO);
                    SPLog(@"forceHome via dismissMainSwitcher"); return YES; }
            @catch (__unused NSException *e) {}
        }
        SEL a = NSSelectorFromString(@"activateMainSwitcherNoninteractivelyWithSource:animated:");
        if ([coord respondsToSelector:a]) {
            @try { ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(coord, a, 0, NO);
                    SPLog(@"forceHome via activateMainSwitcher"); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    SPLog(@"forceHome: none available");
    return NO;
}


// 一次性探测所有可能的方向来源，把真实值打出来定名。
+ (void)dumpOrientationAPIs {
    NSArray *classes = @[@"SBInterfaceOrientationController", @"SBScreenRotationController",
                         @"SBDeviceOrientationController", @"SBOrientationController",
                         @"SBSceneManager", @"SBMainDisplaySceneManager"];
    for (NSString *cn in classes) {
        Class c = NSClassFromString(cn);
        if (!c) { SPLog(@"orientAPI %@ = nil", cn); continue; }
        NSMutableArray *hits = [NSMutableArray array];
        unsigned n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!nm) continue;
            NSString *s = @(nm);
            if ([s rangeOfString:@"rient" options:NSCaseInsensitiveSearch].location != NSNotFound)
                [hits addObject:s];
        }
        free(ms);
        SPLog(@"orientAPI %@(%lu): %@", cn, (unsigned long)hits.count,
              [hits componentsJoinedByString:@" | "]);
    }
    // UIApplication 的 statusBarOrientation 实际值
    SPLog(@"orientAPI statusBarOrientation=%ld device=%ld",
          (long)[UIApplication sharedApplication].statusBarOrientation,
          (long)[[UIDevice currentDevice] orientation]);
    // 每个 scene 的 interfaceOrientation
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *w = (UIWindowScene *)sc;
        SPLog(@"orientAPI scene %@ io=%ld sz=%@", NSStringFromClass([w class]),
              (long)w.interfaceOrientation, NSStringFromCGSize(w.coordinateSpace.bounds.size));
    }
}

+ (BOOL)homePressInWindowScene:(UIWindowScene *)ws {
    if (!ws) return NO;
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    if (!ui) return NO;
    SEL s = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
    if (![ui respondsToSelector:s]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(ui, s, ws);
        SPLog(@"homePress via own scene (%@)", NSStringFromClass([ws class]));
        return YES;
    } @catch (NSException *e) { SPLog(@"homePress(own) ex %@", e.reason); }
    return NO;
}

+ (BOOL)homePress {
    // 名字来自 0.5.23 的实测 dump（日志 "homeAPI SBUIController(18)"）：
    //   真正存在的是 handleHomeButtonSinglePressUpForWindowScene: 及带 sourceType 的变体，
    //   之前一直调的 handleHomeButtonSinglePressUp（无参）在这台机器上根本不存在。
    gHomeTried = [NSMutableSet set];

    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    if (!ui) { SPLog(@"homePress: SBUIController 无实例"); return NO; }

    // 取一个「正式显示」的 UIWindowScene。
    // ⚠️ 必须跳过 SBSystemApertureWindowScene（灵动岛）：
    // 它缺少 isExternalDisplayWindowScene 等方法，传给 SBUIController 会抛
    // unrecognized selector（0.5.25 日志实证：homePress ex1/ex2 都是这个异常）。
    UIWindowScene *ws = nil;
    NSMutableArray *dump = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        NSString *cn = NSStringFromClass([sc class]);
        [dump addObject:[NSString stringWithFormat:@"%@(%ld)", cn, (long)sc.activationState]];
        if ([cn containsString:@"Aperture"]) continue;          // 灵动岛，跳过
        if ([cn containsString:@"TouchVisualizer"]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            if (!ws) ws = (UIWindowScene *)sc;
        }
    }
    if (!ws) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            NSString *cn = NSStringFromClass([sc class]);
            if ([cn containsString:@"Aperture"] || [cn containsString:@"TouchVisualizer"]) continue;
            if (!ws) ws = (UIWindowScene *)sc;
        }
    }
    SPLog(@"homePress scenes: %@ -> picked=%@", [dump componentsJoinedByString:@","],
          ws ? NSStringFromClass([ws class]) : @"nil");

    // 1) handleHomeButtonSinglePressUpForWindowScene:
    SEL s1 = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
    if (ws && [ui respondsToSelector:s1]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(ui, s1, ws);
            [gHomeTried addObject:@"SBUIController.handleHomeButtonSinglePressUpForWindowScene:"];
            SPLog(@"homePress via SPressUpForWindowScene");
            return YES;
        } @catch (NSException *e) { SPLog(@"homePress ex1 %@", e.reason); }
    }

    // 2) handleHomeButtonSinglePressUpForWindowScene:withSourceType:
    SEL s2 = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
    if (ws && [ui respondsToSelector:s2]) {
        @try {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(ui, s2, ws, 0);
            [gHomeTried addObject:@"SBUIController.handleHomeButtonSinglePressUpForWindowScene:withSourceType:"];
            SPLog(@"homePress via SPressUpForWindowScene:withSourceType:");
            return YES;
        } @catch (NSException *e) { SPLog(@"homePress ex2 %@", e.reason); }
    }

    SPLog(@"homePress: none available (ws=%@)", ws ? @"Y" : @"n");
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

// 真正把 App 退到后台（回桌面）。
// 这台机器 SBUIController / SBMainWorkspace 的 home 入口全部不可用（日志 homePress=n），
// 唯一可靠的做法是直接把它的 FBScene 推成 backgrounded=YES / foreground=NO，
// SpringBoard 看到前台 scene 全部退场，自然显示桌面。
+ (BOOL)pushSceneToBackground:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    id scene = [self fbSceneForBundleID:bundleID];
    if (!scene) { SPLog(@"bg: %@ no scene", bundleID); return NO; }
    @try {
        id settings = SPGet(scene, @"settings");
        if (!settings) return NO;
        id desired = SPCopy0(settings, YES);
        if (!desired) return NO;

        BOOL did = NO;
        SEL bgSet = NSSelectorFromString(@"setBackgrounded:");
        if ([desired respondsToSelector:bgSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, bgSet, YES);
            did = YES;
        }
        SEL fgSet = NSSelectorFromString(@"setForeground:");
        if ([desired respondsToSelector:fgSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, fgSet, NO);
            did = YES;
        }
        SEL rsSet = NSSelectorFromString(@"setDeactivationReasons:");
        if ([desired respondsToSelector:rsSet]) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(desired, rsSet, 1ULL);
        }
        if (!did) { SPLog(@"bg: %@ no setter", bundleID); return NO; }

        id immutable = SPCopy0(desired, NO);
        if (!immutable) return NO;
        SEL upd = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:upd]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd, immutable, nil, nil);
            SPLog(@"bg: %@ sent3", bundleID);
            return YES;
        }
        SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:upd2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, upd2, immutable, nil);
            SPLog(@"bg: %@ sent2", bundleID);
            return YES;
        }
    } @catch (NSException *e) { SPLog(@"bg ex %@", e.reason); }
    return NO;
}

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


// 取设备真实方向：横屏时根视图宽 > 高，用它推给 scene 才对得上。
// 之前固定竖屏 → 横屏下画面被压扁；按容器宽高比 → 竖屏下被误判横屏。
// 唯一可靠的是「整个窗口场景的坐标空间尺寸」。
static NSInteger SPMotionOrientation(void);

static NSInteger SPDeviceOrientation(void) {
    // 实测结论（0.8.0-0.8.3 日志）：这台机器的 SpringBoard 里
    //   SBInterfaceOrientationController = nil
    //   SBScreenRotationController = nil
    //   statusBarOrientation = 0
    //   UIDevice.orientation = 1
    //   UIWindowScene.interfaceOrientation = 1，尺寸恒为 {430,932}
    // 即使把手机横过来，系统层仍然认为竖屏 —— 系统方向 API 全部失效。
    // 所以改用加速计（CoreMotion）直接读物理姿态，这是唯一不依赖系统的办法。
    return SPMotionOrientation();
}

// 用加速计判断物理方向：x 主导 = 横屏，y 主导 = 竖屏。
static NSInteger SPMotionOrientation(void) {
    static NSInteger cached = 1;
    static CFTimeInterval cachedAt = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - cachedAt < 0.2) return cached;   // 200ms 缓存，别每次都查
    cachedAt = now;
    @try {
        Class mgr = NSClassFromString(@"CMMotionManager");
        if (!mgr) return cached;
        static id m = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            m = [[mgr alloc] init];
            ((void (*)(id, SEL, double))objc_msgSend)(m, NSSelectorFromString(@"setAccelerometerUpdateInterval:"), 0.1);
            ((void (*)(id, SEL))objc_msgSend)(m, NSSelectorFromString(@"startAccelerometerUpdates"));
        });
        id data = SPMsg0(m, @"accelerometerData");
        if (!data) return cached;
        typedef struct { double x, y, z; } Vec3;
        SEL accSel = NSSelectorFromString(@"acceleration");
        if (![data respondsToSelector:accSel]) return cached;
        NSMethodSignature *sig = [data methodSignatureForSelector:accSel];
        if (!sig || [sig methodReturnLength] < sizeof(Vec3)) return cached;
        Vec3 v;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:data]; [inv setSelector:accSel];
        [inv invoke];
        [inv getReturnValue:&v];
        double ax = fabs(v.x), ay = fabs(v.y);
        if (ax > ay * 1.6 && ax > 0.5) {
            // x 明显主导 → 横屏。左右判断：x>0 = 左横（home 在右）
            cached = (v.x > 0) ? 4 : 3;
        } else {
            cached = 1;
        }
        SPLog(@"motion ax=%.2f ay=%.2f az=%.2f -> orient=%ld", v.x, v.y, v.z, (long)cached);
    } @catch (NSException *e) { SPLog(@"motion ex %@", e.reason); }
    return cached;
}

static NSInteger SPDeviceOrientationOld(void) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *w = (UIWindowScene *)sc;
        NSInteger v = (NSInteger)w.interfaceOrientation;
        if (v >= 1 && v <= 4) { return v; }
    }

    // 1) SpringBoard 的接口方向控制器
    Class oc = NSClassFromString(@"SBInterfaceOrientationController");
    id ctrl = nil;
    if (oc) {
        if ([oc respondsToSelector:NSSelectorFromString(@"sharedInstance")])
            ctrl = ((id (*)(id, SEL))objc_msgSend)(oc, NSSelectorFromString(@"sharedInstance"));
        if (!ctrl && [oc respondsToSelector:NSSelectorFromString(@"sharedInstanceIfExists")])
            ctrl = ((id (*)(id, SEL))objc_msgSend)(oc, NSSelectorFromString(@"sharedInstanceIfExists"));
    }
    if (ctrl) {
        for (NSString *sn in @[@"interfaceOrientation", @"currentInterfaceOrientation"]) {
            SEL sel = NSSelectorFromString(sn);
            if ([ctrl respondsToSelector:sel]) {
                @try {
                    NSInteger v = ((NSInteger (*)(id, SEL))objc_msgSend)(ctrl, sel);
                    if (v >= 1 && v <= 4) { SPLog(@"orient via SBInterfaceOrientationController.%@ = %ld", sn, (long)v); return v; }
                } @catch (__unused NSException *e) {}
            }
        }
    }

    // 2) statusBarOrientation
    @try {
        NSInteger v = [UIApplication sharedApplication].statusBarOrientation;
        if (v >= 1 && v <= 4) return v;
    } @catch (__unused NSException *e) {}

    // 3) 兜底：设备方向
    UIDeviceOrientation o = [[UIDevice currentDevice] orientation];
    if (o == UIDeviceOrientationLandscapeLeft)  return 4;
    if (o == UIDeviceOrientationLandscapeRight) return 3;
    return 1;
}

// 全屏 attach 和恢复共用同一派发路径；恢复传入完整 CGRect，不能丢掉 origin。
static BOOL SPSubmitSceneFrameSettings(id scene, CGRect frame, BOOL touchForeground, NSString **diag) {
    if (diag) *diag = nil;
    if (!scene) { if (diag) *diag = @"no-scene"; return NO; }
    @try {
        id settings = SPGet(scene, @"settings");
        if (!settings) { if (diag) *diag = @"no-settings"; return NO; }
        id desired = SPCopy0(settings, YES);
        if (!desired) { if (diag) *diag = @"copy-nil"; return NO; }
        if (!SPABI(desired, @"setFrame:", "v", 1, @encode(CGRect))) {
            if (diag) *diag = @"no-setFrame";
            return NO;
        }
        SPVoidRect1(desired, @"setFrame:", frame);
        // 方向只用于 sceneView 工厂参数，绝不回写 settings 的方向字段。
        // 前台化逻辑保持原样；恢复时 touchForeground=NO，不改变前后台状态。
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
        id immutable = SPCopy0(desired, NO);
        if (!immutable) { if (diag) *diag = @"immutable-nil"; return NO; }
        SEL upd = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if (SPABI(scene, @"updateSettings:withTransitionContext:completion:", "v", 3, "@", "@", "@")) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd, immutable, nil, nil);
            if (diag) *diag = @"sent3";
            return YES;
        }
        SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if (SPABI(scene, @"updateSettings:withTransitionContext:", "v", 2, "@", "@")) {
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

static BOOL SPSubmitSceneSettingsEx(id scene, CGSize pane, NSInteger orient, BOOL touchForeground, NSString **diag) {
    (void)orient;  // 保留调用/工厂参数兼容性，不再把方向写回远端 settings。
    return SPSubmitSceneFrameSettings(scene, CGRectMake(0, 0, pane.width, pane.height), touchForeground, diag);
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
    CGSize target = container.bounds.size;
    if (target.width < 2 || target.height < 2) target = reference;

    // 用户要求：App 的底栏（任务/消息那些 tab）必须完整可见。
    // 所以用 fit（MIN 缩放）：整个 App 界面缩进容器，上下都不裁。
    // 之前用 MAX（cover）会把底部 tab 栏切掉 —— 这是用户截图里看不到底栏的原因。
    // host 的 bounds 用 reference（推给 scene 的尺寸），容器实际尺寸可能已变，
    // 所以按实际比例缩放（fit：完整显示、不裁切、不变形）。
    // 注意顺序：先设 identity + bounds，再设 transform，最后设 center，否则居中会算错。
    CGFloat sx = target.width / reference.width;
    CGFloat sy = target.height / reference.height;
    // PV 用 cover：铺满容器、超出裁掉。这样 45pt 宽的容器里看到的是完整画面的
    // 一块裁切区域，而不是把 App 压成一条。
    CGFloat scale = MAX(sx, sy);

    host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0, 0, reference.width, reference.height);
    host.transform = CGAffineTransformMakeScale(scale, scale);
    host.center = CGPointMake(target.width / 2.0, target.height / 2.0);
    container.clipsToBounds = YES;
}


// 纯快照：只贴图，零 scene 操作。

- (BOOL)attachSnapshot:(UIImage *)image cropHalf:(NSInteger)half toContainer:(UIView *)container {
    [self detach];  // 新快照 attachment 同样使旧的重试/轮询失效
    if (!container) return NO;
    _containerView = container;
    _attachmentWindow = container.window;
    _attachmentWindowScene = container.window.windowScene;

    UIImage *use = image;
    if (image && half >= 0 && half <= 1) {
        // 把整张全屏图对半裁开：上半给上容器、下半给下容器
        CGImageRef cg = image.CGImage;
        if (cg) {
            size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
            CGRect r = CGRectMake(0, half == 0 ? 0 : h / 2.0, w, h / 2.0);
            CGImageRef sub = CGImageCreateWithImageInRect(cg, r);
            if (sub) { use = [UIImage imageWithCGImage:sub scale:image.scale orientation:image.imageOrientation]; CGImageRelease(sub); }
        }
    }

    UIImageView *iv = [[UIImageView alloc] initWithImage:use];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:iv];
    iv.frame = container.bounds;
    _snapshotView = iv;
    _snapshotActive = YES;
    _attached = NO;
    _live = NO;
    SPLog(@"attach SNAPSHOT %@ half=%ld img=%@", _bundleID, (long)half,
          use ? NSStringFromCGSize(use.size) : @"nil");
    return YES;
}

- (BOOL)attachSnapshot:(UIImage *)image toContainer:(UIView *)container {
    [self detach];  // 新快照 attachment 同样使旧的重试/轮询失效
    if (!container) return NO;
    _containerView = container;
    _attachmentWindow = container.window;
    _attachmentWindowScene = container.window.windowScene;

    UIImageView *iv = [[UIImageView alloc] initWithImage:image];
    // 快照是全屏 430x932，容器只有 430x453。
    // AspectFit 会把整张图缩成中间一条（两侧黑边，用户截图实证）。
    // 改成 AspectFill + 居中：铺满容器、超出部分裁掉，看起来才像真的分屏。
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:iv];
    iv.frame = container.bounds;
    _snapshotView = iv;
    _snapshotActive = YES;
    _attached = NO;      // 没有托管活 scene
    _live = NO;
    SPLog(@"attach SNAPSHOT %@ img=%@", _bundleID,
          image ? NSStringFromCGSize(image.size) : @"nil");
    return YES;
}

// 一个 attachment 的容器、window 和 windowScene 身份在该代内固定。
// container 被移到另一个 window/scene 时，也不能让旧 block 复活旧宿主。
- (BOOL)isCurrentAttachTarget:(NSUInteger)generation container:(UIView *)container
               inWindowScene:(UIWindowScene *)windowScene {
    UIWindow *window = _attachmentWindow;
    return generation == _attachGeneration && container && windowScene && window &&
           _containerView == container && _attachmentWindowScene == windowScene &&
           container.window == window && window.windowScene == windowScene;
}

- (BOOL)isCurrentAttachment:(NSUInteger)generation host:(UIView *)host
                 container:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    return [self isCurrentAttachTarget:generation container:container inWindowScene:windowScene] &&
           _attached && host && _hostView == host && host.superview == container &&
           host.window == _attachmentWindow;
}

- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    // 每个新的公开 attach 请求都换代；重试只调用 tryAttach，不再次换代。
    [self detach];
    _containerView = container;
    _attachmentWindow = container.window;
    _attachmentWindowScene = windowScene;
    return [self tryAttachToContainer:container inWindowScene:windowScene generation:_attachGeneration];
}

- (BOOL)tryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                 generation:(NSUInteger)generation {
    if (![self isCurrentAttachTarget:generation container:container inWindowScene:windowScene]) {
        _lastDiag = @"stale-or-unmounted-target";
        return NO;
    }

    // sceneView 工厂和远端 scene settings 始终使用 UIScreen 的完整尺寸。
    // 容器尺寸只进入 SPFitHostView；绝不按半屏、细条或容器比例缩小 ref。
    CGSize ref = [UIScreen mainScreen].bounds.size;
    _referenceSize = ref;
    _lastSize = container.bounds.size;
    // ⚠️ 绝不能按容器宽高比推方向！
    // 分屏容器是 430x453（宽 > 高），会被判成横屏 → App 整个界面旋转 90 度，
    // 画面就"丢失"了（用户截图实证：标题竖排、内容跑到左上角）。
    // 屏幕本身是竖屏，就永远按竖屏推。
    NSInteger orient = SPDeviceOrientation();   // 跟随设备真实方向

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
        // 失败时只清理本次工厂引用，保留同一代的目标，供受保护的重试使用。
        _scene = nil;
        _handle = nil;
        _controller = nil;
        return NO;
    }

    // 在派发任何 settings 前，必须保存绑定到该 scene 的完整原始 frame。
    if (![self captureOriginalSettings]) {
        _lastDiag = @"original-settings-unavailable";
        _scene = nil;
        _handle = nil;
        _controller = nil;
        return NO;
    }

    NSMutableString *prepDiag = [NSMutableString string];
    SPPrepareSceneHost(host, prepDiag);

    NSString *sub = nil;
    BOOL sent = SPSubmitSceneSettings(scene, ref, orient, &sub);
    _lastDiag = [NSString stringWithFormat:@"%@%@/%@", _lastDiag, prepDiag, sub ?: @"-"];

    // scene 按 ref 全屏渲染；容器内继续沿用 SPFitHostView 的本地等比 cover 布局。
    // 容器底色给个深灰，避免透明区域露出下面的内容。
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
    // sceneView 是 attach 时才建出来的，必须在此时补装 drop（PV 递归装到每层）
    @try { [SPXferDrag attachToContainer:container label:_bundleID]; } @catch (__unused NSException *e) {}
    // 仅保留原有托管登记；不在这里安装或启用 SPScenePin。
    SPHostRegisterHostedBundleID(_bundleID);
    _live = YES;
    _snapshotActive = NO;
    SPLog(@"attach OK %@ diag=%@ sent=%d view=%@ bounds=%@", _bundleID, _lastDiag, sent,
          NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));

    // 画面自检：1.2s 后如果宿主里依然没有渲染内容，就露出快照（宁可显示旧画面也不给灰屏）
    __weak typeof(self) wself = self;
    __weak UIView *whost = host;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        UIView *currentHost = whost;
        UIView *currentContainer = wc;
        UIWindowScene *currentScene = ws;
        if (!self || ![self isCurrentAttachment:generation host:currentHost
                                      container:currentContainer inWindowScene:currentScene]) return;
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
                  (long)cs, (int)valid, (unsigned long)currentHost.subviews.count,
                  hasContent ? @"live" : @"not-ready");
        } @catch (NSException *e) { SPLog(@"content check ex %@", e.reason); }
        if (!hasContent && self->_snapshotView) {
            // 没就绪：先用快照垫住，别露黑；同时轮询等它真正出画面
            currentHost.hidden = YES;
            self->_snapshotView.hidden = NO;
            self->_snapshotActive = YES;
            [self waitForContentReady:8 generation:generation host:currentHost
                           container:currentContainer inWindowScene:currentScene];
        }
    });
    return YES;
}

- (void)attachWhenReady:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                attempts:(NSInteger)attempts interval:(NSTimeInterval)interval {
    [self detach];
    _containerView = container;
    _attachmentWindow = container.window;
    _attachmentWindowScene = windowScene;
    [self retryAttachToContainer:container inWindowScene:windowScene generation:_attachGeneration
                        attempts:attempts interval:interval];
}

- (void)retryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                   generation:(NSUInteger)generation attempts:(NSInteger)attempts
                     interval:(NSTimeInterval)interval {
    if (![self isCurrentAttachTarget:generation container:container inWindowScene:windowScene]) {
        SPLog(@"attach abandon %@ (stale/unmounted target)", self.bundleID);
        return;
    }
    if (_attached || [self tryAttachToContainer:container inWindowScene:windowScene generation:generation]) return;
    if (attempts <= 0) { SPLog(@"attach gave up %@", self.bundleID); return; }
    __weak typeof(self) wself = self;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        UIView *currentContainer = wc;
        UIWindowScene *currentScene = ws;
        if (!self || self->_attached ||
            ![self isCurrentAttachTarget:generation container:currentContainer inWindowScene:currentScene]) return;
        // 不调用公开 attachWhenReady，整条重试链共享同一个 ticket，不能自行换代复活。
        [self retryAttachToContainer:currentContainer inWindowScene:currentScene generation:generation
                            attempts:attempts - 1 interval:interval];
    });
}

- (void)setFrameSize:(CGSize)size {
    if (!_containerView) return;
    CGSize r = CGSizeMake(round(size.width), round(size.height));
    if (r.width < 2 || r.height < 2) return;
    _lastSize = r;
    // 拖动只做本地布局；referenceSize 在本次 attachment 中保持 UIScreen 全屏。
    // 没有远端 settings 提交，也不再需要原来 8pt 的跨进程推送节流。
    SPFitHostView(_hostView, _containerView, _referenceSize);
    _snapshotView.frame = _containerView.bounds;
}

// 等 scene 真正渲染出内容再换上活画面（首次分屏时下面那个 App 常还在启动）
- (void)waitForContentReady:(int)tries generation:(NSUInteger)generation host:(UIView *)host
                 container:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    if (![self isCurrentAttachment:generation host:host container:container inWindowScene:windowScene]) {
        SPLog(@"content poll stopped: %@ (stale attachment)", _bundleID);
        return;
    }
    if (tries <= 0) { SPLog(@"content never ready: %@", _bundleID); return; }
    __weak typeof(self) wself = self;
    __weak UIView *whost = host;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        UIView *currentHost = whost;
        UIView *currentContainer = wc;
        UIWindowScene *currentScene = ws;
        if (!self || ![self isCurrentAttachment:generation host:currentHost
                                      container:currentContainer inWindowScene:currentScene]) return;
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
            currentHost.hidden = NO;
            self->_snapshotView.hidden = YES;
            self->_snapshotActive = NO;
            SPLog(@"content ready: %@", self->_bundleID);
        } else {
            [self waitForContentReady:tries - 1 generation:generation host:currentHost
                           container:currentContainer inWindowScene:currentScene];
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

- (BOOL)captureOriginalSettings {
    if (!_scene) return NO;
    if (_touchedSettings) {
        if (_originalScene == _scene && _originalSettings[@"frame"]) return YES;
        // 不把另一个 scene 尚未成功恢复的记录覆盖成新 scene 的原值。
        [self restoreOriginalSceneSettings];
        if (_touchedSettings) return NO;
    }
    @try {
        id settings = SPGet(_scene, @"settings");
        if (!SPABI(settings, @"frame", @encode(CGRect), 0)) return NO;
        CGRect frame = SPRect0(settings, @"frame");
        _originalSettings = @{@"frame": [NSValue valueWithCGRect:frame]};
        _originalScene = _scene;
        _touchedSettings = YES;
        SPLog(@"scene %@ original frame=%@", _bundleID, NSStringFromCGRect(frame));
        return YES;
    } @catch (NSException *e) { SPLog(@"capture settings ex %@", e.reason); }
    return NO;
}

- (void)restoreOriginalSceneSettings {
    if (!_touchedSettings || !_originalScene || !_originalSettings) return;
    NSValue *frameVal = _originalSettings[@"frame"];
    if (!frameVal) return;
    id scene = _originalScene;  // detach 清掉 _scene 后仍然有正确的恢复目标
    CGRect orig = [frameVal CGRectValue];
    CGRect screen = [UIScreen mainScreen].bounds;
    CGRect target = orig;
    // 沿用旧的半屏/无效尺寸兜底，但只替换 size，始终保留捕获到的 origin。
    if (target.size.width < 2 || target.size.height < screen.size.height * 0.9)
        target.size = screen.size;
    NSString *sub = nil;
    BOOL sent = SPSubmitSceneFrameSettings(scene, target, NO, &sub);
    SPLog(@"scene %@ restore frame=%@ orig=%@ dispatched=%d (%@)", _bundleID,
          NSStringFromCGRect(target), NSStringFromCGRect(orig), (int)sent, sub ?: @"-");
    // 缺 API、copy 失败或异常时保留全部恢复状态，让调用方之后可以重试。
    // sent 仅表示成功调用 updateSettings，不声称远端已异步应用。
    if (!sent) return;
    _touchedSettings = NO;
    _originalSettings = nil;
    _originalScene = nil;
    @try {
        id settings = SPGet(scene, @"settings");
        if (SPABI(settings, @"frame", @encode(CGRect), 0))
            SPLog(@"scene %@ restore immediate readback=%@", _bundleID,
                  NSStringFromCGRect(SPRect0(settings, @"frame")));
    } @catch (NSException *e) { SPLog(@"verify ex %@", e.reason); }
}

- (void)detach {
    ++_attachGeneration;  // 必须先换代，再调用任何可能重入的私有拆卸 API。
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
    _containerView = nil;
    _attachmentWindow = nil;
    _attachmentWindowScene = nil;
    _attached = NO;
    _live = NO;
    _snapshotActive = NO;
    _lastSize = CGSizeZero;
    // 不清 originalScene/originalSettings：恢复失败时，detach 后仍可继续派发恢复。
    SPHostUnregisterHostedBundleID(_bundleID);
    _scene = nil;
    _handle = nil;
    _controller = nil;
}

- (void)dealloc {
    [_hostView removeFromSuperview];
    [_snapshotView removeFromSuperview];
}

@end