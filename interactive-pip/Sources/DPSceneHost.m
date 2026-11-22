#import "DPSceneHost.h"
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Only describes known private initializers; no private class is implemented.
@interface DPSceneLayerContainerABI : UIView
- (instancetype)initWithScene:(id)scene debugDescription:(NSString *)description;
- (instancetype)initWithScene:(id)scene;
@end

static void DPInvalidateHostView(UIView *host, NSString *stage) {
    SEL sel = NSSelectorFromString(@"invalidate");
    if (!host || ![host respondsToSelector:sel]) return;
    NSMethodSignature *sig = [host methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != 'v') return;
    @try {
        ((void(*)(id,SEL))objc_msgSend)(host,sel);
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] host teardown stage=%@ host=%p class=%@ exception=%@ reason=%@",
              stage, host, NSStringFromClass(host.class), e.name, e.reason);
    }
}

@interface DPSceneHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, assign, readwrite, getter=isLive) BOOL live;
@property (nonatomic, copy, readwrite, nullable) NSString *statusText;
@property (nonatomic, strong, nullable) id scene;
@property (nonatomic, strong, nullable) id sceneHandle;
@property (nonatomic, strong, nullable) UIView *hostView;
@property (nonatomic, strong, nullable) UIView *externalSceneContainer;
@property (nonatomic, copy) NSArray *hostedExternalLayers;
@property (nonatomic, assign) NSUInteger externalRefreshGeneration;
@property (nonatomic, weak, nullable) id observedLayerManager;
@property (nonatomic, assign) BOOL observingLayerManager;
@property (nonatomic, strong, nullable) UIView *placeholder;
@property (nonatomic, strong, nullable) UIImageView *iconView;
@property (nonatomic, strong, nullable) UIImageView *snapshotView;
@property (nonatomic, strong, nullable) UILabel *nameLabel;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@property (nonatomic, strong, nullable) NSString *requesterToken;
@property (nonatomic, assign) NSInteger attemptCount;
@property (nonatomic, assign) BOOL attaching;
@property (nonatomic, assign) BOOL invalidated;
@property (nonatomic, strong) id originalSettings;
@property (nonatomic, strong) id settingsScene;
@property (nonatomic, assign) BOOL snapshotAttempted;
@property (nonatomic, assign) CGSize lastCommittedSceneSize;
@property (nonatomic, assign) CGSize nativeSceneSize;
@property (nonatomic, assign) BOOL hostIsSceneView;
@property (nonatomic, copy, readwrite, nullable) NSString *hostViewDiag;
@property (nonatomic, copy, readwrite, nullable) NSString *layerDiag;
@property (nonatomic, copy, readwrite, nullable) NSString *layoutDiag;
@property (nonatomic, strong, nullable) dispatch_source_t keepAliveTimer;
@property (nonatomic, strong, nullable) dispatch_source_t reconnectTimer;
@property (nonatomic, assign) NSUInteger reconnectAttempts;
@property (nonatomic, strong, nullable) id processAssertion;
@property (nonatomic, assign) BOOL processAssertionAttempted;
- (void)enableInteractionInView:(UIView *)view;
- (void)scheduleReconnect;
- (void)stopReconnect;
- (void)scheduleExternalSceneRefresh;
- (void)refreshExternalSceneHosts;
- (void)clearExternalSceneHosts;
- (void)startObservingLayerManager;
- (void)stopObservingLayerManager;
- (nullable Class)externalSceneHostClass;
- (nullable id)layerManagerFromScene:(id)scene;
- (BOOL)layerHasExternalSceneID:(id)layer;
@property (nonatomic, strong, nullable) id retainedSceneController; // 防止 VC 被释放
- (void)layoutHostView;
@end

@implementation DPSceneHost

+ (BOOL)isSceneHostingAvailable {
    return NSClassFromString(@"FBSceneManager") != Nil
        || NSClassFromString(@"SBApplicationController") != Nil
        || NSClassFromString(@"SBMainDisplaySceneManager") != Nil;
}

- (instancetype)initWithBundleID:(NSString *)bundleID {
    self = [super init];
    if (self) {
        _bundleID = [bundleID copy];
        _view = [[UIView alloc] initWithFrame:CGRectZero];
        _view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
        _view.clipsToBounds = YES;
        _live = NO;
        _attaching = NO;
        _requesterToken = [NSString stringWithFormat:@"DualPane.%@.%p",
                           bundleID ?: @"app", self];
        _attemptCount = 0;
        _lastCommittedSceneSize = CGSizeZero;
        _nativeSceneSize = CGSizeZero;
        [self buildPlaceholder];
        // 延迟到有 frame 后再挂，避免 0x0 尺寸创建坏的 host view
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attemptLiveSceneHost];
        });
    }
    return self;
}

#pragma mark - Lookup

- (id)sbApplication {
    Class cls = NSClassFromString(@"SBApplicationController");
    if (!cls) return nil;
    id controller = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    } else if ([cls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstanceIfExists));
    }
    if (!controller) return nil;

    for (NSString *name in @[@"applicationWithBundleIdentifier:",
                             @"applicationWithBundleID:"]) {
        SEL sel = NSSelectorFromString(name);
        if ([controller respondsToSelector:sel]) {
            id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, sel, self.bundleID);
            if (app) return app;
        }
    }
    return nil;
}

- (id)mainSceneFromApplication:(id)app {
    if (!app) return nil;
    for (NSString *name in @[@"mainScene", @"_mainScene", @"primaryScene"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id scene = nil;
            if ([app respondsToSelector:sel]) {
                scene = ((id (*)(id, SEL))objc_msgSend)(app, sel);
            } else {
                scene = [app valueForKey:name];
            }
            if (scene) return scene;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (id)fbSceneManager {
    Class cls = NSClassFromString(@"FBSceneManager");
    if (!cls) return nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    }
    return nil;
}

- (id)sbMainDisplaySceneManager {
    for (NSString *cn in @[@"SBMainDisplaySceneManager",
                           @"SBSceneManagerCoordinator",
                           @"SBSceneManager"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            if ([cn isEqualToString:@"SBSceneManagerCoordinator"] && obj) {
                @try {
                    id m = [obj valueForKey:@"mainDisplaySceneManager"];
                    if (m) return m;
                } @catch (__unused NSException *e) {}
            }
            if (obj) return obj;
        }
        if ([cls respondsToSelector:@selector(mainDisplaySceneManager)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(mainDisplaySceneManager));
            if (obj) return obj;
        }
    }
    return nil;
}

- (BOOL)string:(NSString *)s matchesBundleID:(NSString *)bid {
    if (![s isKindOfClass:[NSString class]] || !bid.length) return NO;
    if ([s isEqualToString:bid]) return YES;
    // scene id 常见形态: sceneID:com.xxx-default / com.xxx-default
    if ([s containsString:bid]) return YES;
    return NO;
}

- (BOOL)object:(id)obj matchesBundleID:(NSString *)bid {
    if (!obj || !bid.length) return NO;

    NSArray *keys = @[@"identifier", @"sceneIdentifier", @"persistentIdentifier",
                      @"clientIdentifier", @"bundleIdentifier",
                      @"applicationBundleIdentifier", @"_identifier"];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([self string:val matchesBundleID:bid]) return YES;
        } @catch (__unused NSException *e) {}
    }

    for (NSString *key in @[@"application", @"clientProcess", @"definition",
                             @"sceneIdentity", @"identity"]) {
        @try {
            id nested = [obj valueForKey:key];
            if (!nested || nested == obj) continue;
            for (NSString *nk in @[@"bundleIdentifier", @"identifier",
                                    @"applicationBundleIdentifier",
                                    @"workspaceIdentifier"]) {
                @try {
                    id val = [nested valueForKey:nk];
                    if ([self string:val matchesBundleID:bid]) return YES;
                } @catch (__unused NSException *e) {}
            }
            // definition.identity
            @try {
                id identity = [nested valueForKey:@"identity"];
                NSString *ws = [identity valueForKey:@"workspaceIdentifier"];
                if ([self string:ws matchesBundleID:bid]) return YES;
            } @catch (__unused NSException *e) {}
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

- (NSArray *)arrayFromCollection:(id)result {
    if ([result isKindOfClass:[NSSet class]]) return [result allObjects];
    if ([result isKindOfClass:[NSOrderedSet class]]) return [result array];
    if ([result isKindOfClass:[NSArray class]]) return result;
    if ([result isKindOfClass:[NSDictionary class]]) return [result allValues];
    return @[];
}

- (NSArray *)allScenesFromManager:(id)manager {
    if (!manager) return @[];
    NSMutableArray *out = [NSMutableArray array];

    for (NSString *name in @[@"scenes", @"_scenes"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id result = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        [out addObjectsFromArray:[self arrayFromCollection:result]];
    }

    // scenesIncludingInternal:
    SEL inc = NSSelectorFromString(@"scenesIncludingInternal:");
    if ([manager respondsToSelector:inc]) {
        NSMethodSignature *sig = [manager methodSignatureForSelector:inc];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = manager;
            inv.selector = inc;
            BOOL yes = YES;
            [inv setArgument:&yes atIndex:2];
            [inv invoke];
            __unsafe_unretained id tmp = nil;
            [inv getReturnValue:&tmp];
            [out addObjectsFromArray:[self arrayFromCollection:tmp]];
        }
    }

    for (NSString *name in @[@"scenesByID", @"_scenesByID", @"sceneMap"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id map = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        [out addObjectsFromArray:[self arrayFromCollection:map]];
    }
    return out;
}

#pragma mark - Scene handle / FBScene

- (id)sceneHandleForBundleID {
    id app = [self sbApplication];

    // 1) SBApplication 上直接取
    if (app) {
        for (NSString *key in @[@"mainSceneHandle", @"_mainSceneHandle",
                                 @"sceneHandle", @"mainScene", @"_mainScene",
                                 @"primaryScene"]) {
            @try {
                id val = nil;
                SEL sel = NSSelectorFromString(key);
                if ([app respondsToSelector:sel]) {
                    val = ((id (*)(id, SEL))objc_msgSend)(app, sel);
                } else {
                    val = [app valueForKey:key];
                }
                if (val) return val;
            } @catch (__unused NSException *e) {}
        }

        @try {
            id scenes = nil;
            if ([app respondsToSelector:@selector(scenes)]) {
                scenes = ((id (*)(id, SEL))objc_msgSend)(app, @selector(scenes));
            } else {
                scenes = [app valueForKey:@"scenes"];
            }
            NSArray *arr = [self arrayFromCollection:scenes];
            for (id s in arr) {
                if ([self object:s matchesBundleID:self.bundleID]) return s;
            }
            if (arr.count) return arr.firstObject;
        } @catch (__unused NSException *e) {}
    }

    // 2) SBMainDisplaySceneManager 的 external handles
    id sbm = [self sbMainDisplaySceneManager];
    if (sbm) {
        for (NSString *name in @[@"externalForegroundApplicationSceneHandles",
                                 @"externalApplicationSceneHandles",
                                 @"applicationSceneHandles",
                                 @"sceneHandles",
                                 @"_externalForegroundApplicationSceneHandles",
                                 @"_externalApplicationSceneHandles"]) {
            @try {
                id set = nil;
                SEL sel = NSSelectorFromString(name);
                if ([sbm respondsToSelector:sel]) {
                    set = ((id (*)(id, SEL))objc_msgSend)(sbm, sel);
                } else {
                    set = [sbm valueForKey:name];
                }
                for (id handle in [self arrayFromCollection:set]) {
                    if ([self object:handle matchesBundleID:self.bundleID]) return handle;
                    @try {
                        id a = [handle valueForKey:@"application"];
                        NSString *bid = [a valueForKey:@"bundleIdentifier"];
                        if ([bid isEqualToString:self.bundleID]) return handle;
                    } @catch (__unused NSException *e) {}
                }
            } @catch (__unused NSException *e) {}
        }

        // sceneHandleForIdentifier: / existingSceneHandleForPersistenceIdentifier:
        for (NSString *name in @[@"sceneHandleForIdentifier:",
                                 @"existingSceneHandleForPersistenceIdentifier:",
                                 @"sceneHandleForSceneIdentity:"]) {
            SEL sel = NSSelectorFromString(name);
            if (![sbm respondsToSelector:sel]) continue;
            // 尝试常见 scene id 形态
            NSArray *candidates = @[
                self.bundleID,
                [NSString stringWithFormat:@"sceneID:%@-default", self.bundleID],
                [NSString stringWithFormat:@"%@-default", self.bundleID],
            ];
            for (NSString *cid in candidates) {
                @try {
                    id h = ((id (*)(id, SEL, id))objc_msgSend)(sbm, sel, cid);
                    if (h) return h;
                } @catch (__unused NSException *e) {}
            }
        }
    }
    return nil;
}

- (id)fbSceneFromHandle:(id)handle {
    if (!handle) return nil;
    for (NSString *name in @[@"sceneIfExists", @"scene", @"fbScene", @"_scene"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id s = nil;
            if ([handle respondsToSelector:sel]) {
                s = ((id (*)(id, SEL))objc_msgSend)(handle, sel);
            } else {
                s = [handle valueForKey:name];
            }
            if (s) return s;
        } @catch (__unused NSException *e) {}
    }
    NSString *cn = NSStringFromClass([handle class]);
    if ([cn containsString:@"FBScene"] && ![cn containsString:@"Handle"] &&
        ![cn containsString:@"Manager"] && ![cn containsString:@"Host"]) {
        return handle;
    }
    return nil;
}

- (id)findFBScene {
    id appScene = [self mainSceneFromApplication:[self sbApplication]];
    if (appScene) {
        self.sceneHandle = appScene;
        return appScene;
    }

    id handle = [self sceneHandleForBundleID];
    self.sceneHandle = handle;
    id scene = [self fbSceneFromHandle:handle];
    if (scene) return scene;

    // 直接按 identifier 取
    id mgr = [self fbSceneManager];
    if (mgr) {
        @try {
            id workspace = [mgr valueForKey:@"_workspace"];
            for (NSString *key in @[@"_allScenesByID", @"_scenesByIdentifier", @"_scenesByID"]) {
                id map = [workspace valueForKey:key];
                if (![map isKindOfClass:[NSDictionary class]]) continue;
                for (id identifier in map) {
                    if ([identifier isKindOfClass:[NSString class]] &&
                        [identifier containsString:self.bundleID]) {
                        id candidate = map[identifier];
                        id inner = [self fbSceneFromHandle:candidate];
                        return inner ?: candidate;
                    }
                }
            }
        } @catch (__unused NSException *e) {}

        for (NSString *name in @[@"sceneWithIdentifier:", @"sceneFromIdentifier:"]) {
            SEL sel = NSSelectorFromString(name);
            if (![mgr respondsToSelector:sel]) continue;
            NSArray *candidates = @[
                self.bundleID,
                [NSString stringWithFormat:@"sceneID:%@-default", self.bundleID],
                [NSString stringWithFormat:@"%@-default", self.bundleID],
            ];
            for (NSString *cid in candidates) {
                @try {
                    id s = ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, cid);
                    if (s) return s;
                } @catch (__unused NSException *e) {}
            }
        }

        for (id s in [self allScenesFromManager:mgr]) {
            if ([self object:s matchesBundleID:self.bundleID]) return s;
        }
    }

    id sbm = [self sbMainDisplaySceneManager];
    for (id s in [self allScenesFromManager:sbm]) {
        if ([self object:s matchesBundleID:self.bundleID]) {
            id inner = [self fbSceneFromHandle:s];
            return inner ?: s;
        }
    }
    return nil;
}

#pragma mark - Host view creation

- (UIView *)viewFromMaybeController:(id)result {
    if ([result isKindOfClass:[UIView class]]) return (UIView *)result;
    if (result && [result respondsToSelector:@selector(view)]) {
        self.retainedSceneController = result; // 强引用，避免 VC 释放带走 view
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(result, @selector(view));
        if ([v isKindOfClass:[UIView class]]) return v;
    }
    return nil;
}

- (UIView *)hostViewFromSceneHandle:(id)handle size:(CGSize)size {
    if (!handle) return nil;
    CGSize s = size;
    if (s.width < 2 || s.height < 2) {
        s = CGSizeMake(180, 320);
    }
    long long orientation = 1; // UIInterfaceOrientationPortrait
    NSString *req = self.requesterToken ?: @"DualPane";

    // 优先 SceneViewController（iOS 15/16 更稳）
    NSArray *vcSels = @[
        @"newSceneViewControllerForReferenceSize:orientation:hostRequester:",
        @"newSceneViewControllerForReferenceSize:",
    ];
    for (NSString *name in vcSels) {
        SEL sel = NSSelectorFromString(name);
        if (![handle respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [handle methodSignatureForSelector:sel];
        if (!sig) continue;
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = handle;
            inv.selector = sel;
            [inv setArgument:&s atIndex:2];
            if (sig.numberOfArguments >= 4) {
                [inv setArgument:&orientation atIndex:3];
            }
            if (sig.numberOfArguments >= 5) {
                [inv setArgument:&req atIndex:4];
            }
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            UIView *v = [self viewFromMaybeController:result];
            if (v) {
                NSLog(@"[InteractivePiP] %@ via %@", self.bundleID, name);
                return v;
            }
        } @catch (NSException *e) {
            NSLog(@"[InteractivePiP] %@ 异常: %@", name, e);
        }
    }

    // newSceneViewWithReferenceSize:orientation:hostRequester:
    SEL viewSel = NSSelectorFromString(@"newSceneViewWithReferenceSize:orientation:hostRequester:");
    if ([handle respondsToSelector:viewSel]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:viewSel];
        if (sig) {
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle;
                inv.selector = viewSel;
                [inv setArgument:&s atIndex:2];
                [inv setArgument:&orientation atIndex:3];
                [inv setArgument:&req atIndex:4];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                UIView *v = [self viewFromMaybeController:result];
                if (v) {
                    NSLog(@"[InteractivePiP] newSceneViewWithReferenceSize OK %@", self.bundleID);
                    return v;
                }
            } @catch (NSException *e) {
                NSLog(@"[InteractivePiP] newSceneView 异常: %@", e);
            }
        }
    }

    // 无 orientation 变体
    SEL viewSel2 = NSSelectorFromString(@"newSceneViewWithReferenceSize:hostRequester:");
    if ([handle respondsToSelector:viewSel2]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:viewSel2];
        if (sig) {
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle;
                inv.selector = viewSel2;
                [inv setArgument:&s atIndex:2];
                [inv setArgument:&req atIndex:3];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                UIView *v = [self viewFromMaybeController:result];
                if (v) return v;
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

- (void)enableHostingOnManager:(id)hostManager {
    if (!hostManager) return;
    NSString *req = self.requesterToken ?: @"DualPane";

    // enableHostingForRequester:orderFront:  (经典 FBSceneHostManager)
    SEL en = NSSelectorFromString(@"enableHostingForRequester:orderFront:");
    if ([hostManager respondsToSelector:en]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:en];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = en;
            [inv setArgument:&req atIndex:2];
            BOOL order = YES;
            [inv setArgument:&order atIndex:3];
            @try { [inv invoke]; } @catch (__unused NSException *e) {}
            return;
        }
    }

    // enableHostingForRequester:priority:
    en = NSSelectorFromString(@"enableHostingForRequester:priority:");
    if ([hostManager respondsToSelector:en]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:en];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = en;
            [inv setArgument:&req atIndex:2];
            // FBSceneHostingPriority 常见 default/high
            NSInteger prio = 1;
            [inv setArgument:&prio atIndex:3];
            @try { [inv invoke]; } @catch (__unused NSException *e) {}
            return;
        }
    }

    // enableAndOrderFrontForRequester:
    en = NSSelectorFromString(@"enableAndOrderFrontForRequester:");
    if ([hostManager respondsToSelector:en]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(hostManager, en, req);
        } @catch (__unused NSException *e) {}
    }
}

- (UIView *)invokeHostViewForRequester:(id)hostManager {
    if (!hostManager) return nil;
    NSString *req = self.requesterToken ?: @"DualPane";

    // 先 enable，再取 view —— 绝不递归
    [self enableHostingOnManager:hostManager];

    // hostViewForRequester:enableAndOrderFront:
    SEL sel = NSSelectorFromString(@"hostViewForRequester:enableAndOrderFront:");
    if ([hostManager respondsToSelector:sel]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = sel;
            [inv setArgument:&req atIndex:2];
            BOOL order = YES;
            [inv setArgument:&order atIndex:3];
            @try {
                [inv invoke];
                __unsafe_unretained UIView *view = nil;
                [inv getReturnValue:&view];
                if ([view isKindOfClass:[UIView class]]) {
                    NSLog(@"[InteractivePiP] hostViewForRequester:enableAndOrderFront OK %@", self.bundleID);
                    return view;
                }
            } @catch (NSException *e) {
                NSLog(@"[InteractivePiP] hostViewForRequester 异常: %@", e);
            }
        }
    }

    // hostViewForRequester:
    sel = NSSelectorFromString(@"hostViewForRequester:");
    if ([hostManager respondsToSelector:sel]) {
        @try {
            UIView *view = ((id (*)(id, SEL, id))objc_msgSend)(hostManager, sel, req);
            if ([view isKindOfClass:[UIView class]]) return view;
        } @catch (__unused NSException *e) {}
    }

    // Compatibility fallbacks that still return a live host view.
    for (NSString *name in @[@"contextHostViewForRequester:",
                             @"_hostViewForRequester:"]) {
        SEL s2 = NSSelectorFromString(name);
        if (![hostManager respondsToSelector:s2]) continue;
        @try {
            UIView *view = ((id (*)(id, SEL, id))objc_msgSend)(hostManager, s2, req);
            if ([view isKindOfClass:[UIView class]]) return view;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (id)hostManagerFromScene:(id)scene {
    if (!scene) return nil;
    for (NSString *name in @[@"hostManager", @"contextHostManager",
                             @"_hostManager", @"_contextHostManager",
                             @"layerHostManager"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id hm = nil;
            if ([scene respondsToSelector:sel]) {
                hm = ((id (*)(id, SEL))objc_msgSend)(scene, sel);
            } else {
                hm = [scene valueForKey:name];
            }
            if (hm) return hm;
        } @catch (__unused NSException *e) {}
    }
    // layerManager 上再取 hostManager
    @try {
        id lm = nil;
        if ([scene respondsToSelector:NSSelectorFromString(@"layerManager")]) {
            lm = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"layerManager"));
        } else {
            lm = [scene valueForKey:@"layerManager"];
        }
        if (lm) {
            for (NSString *name in @[@"hostManager", @"contextHostManager", @"_hostManager"]) {
                @try {
                    id hm = [lm valueForKey:name];
                    if (hm) return hm;
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

- (id)settingsCopyForScene:(id)scene {
    if (!scene) return nil;
    @try {
        id source = nil;
        for (NSString *name in @[@"settings", @"mutableSettings", @"_mutableSettings"]) {
            SEL sel = NSSelectorFromString(name);
            if ([scene respondsToSelector:sel]) {
                source = ((id (*)(id, SEL))objc_msgSend)(scene, sel);
            } else {
                source = [scene valueForKey:name];
            }
            if (source) break;
        }
        if ([source respondsToSelector:@selector(mutableCopy)]) {
            id copied = [source mutableCopy];
            if (copied) return copied;
        }
        return source;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

- (BOOL)submitSettings:(id)settings toScene:(id)scene {
    if (!settings || !scene) return NO;
    @try {
        SEL twoArg = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:twoArg]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, twoArg, settings, nil);
            return YES;
        }

        SEL threeArg = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:threeArg]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, threeArg, settings, nil, nil);
            return YES;
        }

        SEL legacy = NSSelectorFromString(@"_applyMutableSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:legacy]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, legacy, settings, nil, nil);
            return YES;
        }

        SEL single = NSSelectorFromString(@"updateSettings:");
        if ([scene respondsToSelector:single]) {
            ((void (*)(id, SEL, id))objc_msgSend)(scene, single, settings);
            return YES;
        }
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] scene settings failed %@: %@", self.bundleID, e);
    }
    return NO;
}

- (BOOL)applySceneForeground:(BOOL)foreground
                  backgrounded:(BOOL)backgrounded
                           size:(CGSize)size
                   includeFrame:(BOOL)includeFrame {
    id settings = [self settingsCopyForScene:self.scene];
    if (!settings) return NO;
    if (self.settingsScene != self.scene) {
        if (self.settingsScene && self.originalSettings) [self submitSettings:self.originalSettings toScene:self.settingsScene];
        self.settingsScene = self.scene;
        self.originalSettings = [self settingsCopyForScene:self.scene];
    }

    @try {

        SEL setForeground = NSSelectorFromString(@"setForeground:");
        if ([settings respondsToSelector:setForeground]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setForeground, foreground);
        }

        SEL setBackgrounded = NSSelectorFromString(@"setBackgrounded:");
        if ([settings respondsToSelector:setBackgrounded]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setBackgrounded, backgrounded);
        }

        if (foreground) {
            SEL setReasons = NSSelectorFromString(@"setDeactivationReasons:");
            if ([settings respondsToSelector:setReasons]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, setReasons, 0);
            }
            // Keyboard arbitration (_UIRemoteKeyboards) only dispatches to an
            // ACTIVE scene. Without setSceneActive:YES the hosted app can show a
            // caret but never receives a keyboard - the long-standing "keyboard
            // won't come up" symptom. FBSceneSettings carries this separately
            // from foreground/backgrounded.
            SEL setActive = NSSelectorFromString(@"setSceneActive:");
            if ([settings respondsToSelector:setActive]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setActive, YES);
            }
            SEL setActiveAlt = NSSelectorFromString(@"setActive:");
            if (![settings respondsToSelector:setActive] && [settings respondsToSelector:setActiveAlt]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setActiveAlt, YES);
            }
            SEL setUiActive = NSSelectorFromString(@"setUIApplicationSceneActive:");
            if ([settings respondsToSelector:setUiActive]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setUiActive, YES);
            }
        } else {
            SEL setActive = NSSelectorFromString(@"setSceneActive:");
            if ([settings respondsToSelector:setActive]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(settings, setActive, NO);
            }
        }

        if (includeFrame && size.width > 1 && size.height > 1) {
            SEL setFrame = NSSelectorFromString(@"setFrame:");
            if ([settings respondsToSelector:setFrame]) {
                CGRect frame = CGRectMake(0, 0, size.width, size.height);
                ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, setFrame, frame);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] scene state failed %@: %@", self.bundleID, e);
        return NO;
    }

    return [self submitSettings:settings toScene:self.scene];
}

- (UIView *)layerContainerViewFromScene:(id)scene {
    Class containerClass = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!scene || !containerClass) return nil;

    SEL detailedInit = NSSelectorFromString(@"initWithScene:debugDescription:");
    SEL sceneInit = NSSelectorFromString(@"initWithScene:");
    NSMethodSignature *sig = nil;
    BOOL detailed = NO;
    for (NSString *name in @[@"initWithScene:debugDescription:", @"initWithScene:"]) {
        SEL candidate = NSSelectorFromString(name);
        NSMethodSignature *test = [containerClass instanceMethodSignatureForSelector:candidate];
        NSUInteger count = [name isEqualToString:@"initWithScene:"] ? 3 : 4;
        if (!test || test.numberOfArguments != count || test.methodReturnType[0] != '@') continue;
        BOOL valid = YES;
        for (NSUInteger i = 2; i < count; i++) if ([test getArgumentTypeAtIndex:i][0] != '@') valid = NO;
        if (valid) { sig = test; detailed = count == 4; break; }
    }
    if (!sig) return nil; // Never allocate an object that cannot be initialized.
    UIView *container = nil;
    BOOL transferred = NO;
    @try {
        DPSceneLayerContainerABI *receiver = (DPSceneLayerContainerABI *)[containerClass alloc];
        container = detailed ? [receiver initWithScene:scene debugDescription:@"DualPane"] : [receiver initWithScene:scene];
        if (![container isKindOfClass:UIView.class]) return nil;

        UIView *containerView = (UIView *)container;
        CGSize size = self.nativeSceneSize;
        if (size.width < 2 || size.height < 2) size = [UIScreen mainScreen].bounds.size;
        containerView.frame = CGRectMake(0, 0, size.width, size.height);
        containerView.clipsToBounds = YES;

        SEL setPresentationContext = NSSelectorFromString(@"_setPresentationContext:");
        Class contextClass = NSClassFromString(@"UIScenePresentationContext");
        if ([container respondsToSelector:setPresentationContext] && contextClass) {
            id context = [contextClass alloc];
            SEL defaultInit = NSSelectorFromString(@"_initWithDefaultValues");
            if ([context respondsToSelector:defaultInit]) {
                context = ((id (*)(id, SEL))objc_msgSend)(context, defaultInit);
            } else {
                context = ((id (*)(id, SEL))objc_msgSend)(context, @selector(init));
            }
            if (context) {
                ((void (*)(id, SEL, id))objc_msgSend)(container, setPresentationContext, context);
            }
        }

        id containerScene = scene;
        SEL sceneSelector = NSSelectorFromString(@"scene");
        if ([container respondsToSelector:sceneSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(container, sceneSelector);
            if (value) containerScene = value;
        }

        id layerManager = nil;
        SEL layerManagerSelector = NSSelectorFromString(@"layerManager");
        if ([containerScene respondsToSelector:layerManagerSelector]) {
            layerManager = ((id (*)(id, SEL))objc_msgSend)(containerScene, layerManagerSelector);
        }
        id layers = nil;
        SEL layersSelector = NSSelectorFromString(@"layers");
        if ([layerManager respondsToSelector:layersSelector]) {
            layers = ((id (*)(id, SEL))objc_msgSend)(layerManager, layersSelector);
        }

        SEL createHost = NSSelectorFromString(@"_createHostViewForLayer:");
        NSUInteger created = 0;
        if ([container respondsToSelector:createHost]) {
            for (id layer in [self arrayFromCollection:layers]) {
                UIView *layerView = ((id (*)(id, SEL, id))objc_msgSend)(container, createHost, layer);
                if (![layerView isKindOfClass:[UIView class]]) continue;
                layerView.frame = containerView.bounds;
                layerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                if (layerView.superview != containerView) [containerView addSubview:layerView];
                created += 1;
            }
        }

        self.layerDiag = [NSString stringWithFormat:@"layers=%lu created=%lu lm=%d sc=%d",
                           (unsigned long)[[self arrayFromCollection:layers] count],
                           (unsigned long)created, layerManager ? 1 : 0, containerScene ? 1 : 0];
        if (created > 0) {
            NSLog(@"[InteractivePiP] layer container attached %@ layers=%@", self.bundleID, @(created));
            transferred = YES;
            return containerView;
        }
    } @catch (NSException *e) {
        NSLog(@"[InteractivePiP] layer container failed %@: %@ reason=%@", self.bundleID, e.name, e.reason);
    } @finally {
        // Covers zero hosts AND exceptions after partially creating host layers.
        if (!transferred && container) DPInvalidateHostView(container, @"construction-failed");
    }
    return nil;
}

- (UIView *)sceneViewFromSceneManager:(CGSize)size {
    // iOS 16 exposes scene view creation on FBSceneManager, NOT on the FBScene.
    id mgr = [self fbSceneManager] ?: [self sbMainDisplaySceneManager];
    if (!mgr) return nil;
    NSString *req = self.requesterToken ?: @"InteractivePiP";
    NSArray *names = @[
        @"newSceneViewWithReferenceSize:hostRequester:",
        @"newSceneViewWithReferenceSize:orientation:hostRequester:",
        @"newSceneViewWithReferenceSize:containerOrientation:hostRequester:",
        @"newSceneViewForScene:",
    ];
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![mgr respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
        if (!sig) continue;
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = mgr;
            inv.selector = sel;
            NSUInteger argc = sig.numberOfArguments;
            if (argc > 2) [inv setArgument:&size atIndex:2];
            if (argc > 3) [inv setArgument:&req atIndex:3];
            if (argc > 4) { NSInteger z = 0; [inv setArgument:&z atIndex:4]; }
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            UIView *v = (UIView *)result;
            if (![v isKindOfClass:[UIView class]] && [v respondsToSelector:@selector(view)]) {
                v = ((UIView *(*)(id, SEL))objc_msgSend)(v, @selector(view));
            }
            if ([v isKindOfClass:[UIView class]] && v.frame.size.height > 1) {
                self.hostViewDiag = [NSString stringWithFormat:@"ok-mgr %@ -> %@", name, NSStringFromClass([v class])];
                NSLog(@"[InteractivePiP] sceneView via manager %@ -> %@", name, NSStringFromClass([v class]));
                return v;
            }
            self.hostViewDiag = [NSString stringWithFormat:@"badview-mgr %@ h=%.1f", name, v ? ((UIView *)v).frame.size.height : 0.0];
        } @catch (NSException *e) {
            self.hostViewDiag = [NSString stringWithFormat:@"throw-mgr %@: %@", name, e.name];
            NSLog(@"[InteractivePiP] manager %@ failed: %@", name, e);
        }
    }
    return nil;
}

- (UIView *)hostViewFromFBScene:(id)scene {
    if (!scene) return nil;
    // Request the scene at the phone's native canvas, not the pane size: a
    // mismatched reference size makes the client lay itself out narrow, which
    // then shows as side bars after scaling.
    CGSize ref = self.nativeSceneSize;
    if (ref.width < 2 || ref.height < 2) ref = [UIScreen mainScreen].bounds.size;
    if (ref.width < 2 || ref.height < 2) ref = [UIScreen mainScreen].bounds.size;

    // 1) Ask FrontBoard for a real scene view. It owns the remote scene's
    //    presentation layer, which is what input/keyboard pairing needs.
    UIView *sceneView = [self newSceneViewForScene:scene size:ref];
    if (sceneView) {
        self.hostIsSceneView = YES;
        NSLog(@"[InteractivePiP] sceneView %@ -> %@", self.bundleID, NSStringFromClass(sceneView.class));
        return sceneView;
    }

    // 2) Legacy host manager (absent on newer systems).
    id hostManager = [self hostManagerFromScene:scene];
    if (hostManager) {
        UIView *hv = [self invokeHostViewForRequester:hostManager];
        if (hv) {
            self.hostIsSceneView = ([NSStringFromClass(hv.class) containsString:@"Scene"]);
            return hv;
        }
    }

    // 3) Pixel-only fallback: renders but cannot take the system keyboard.
    self.hostIsSceneView = NO;
    NSLog(@"[InteractivePiP] layer fallback %@ (no keyboard)", self.bundleID);
    return [self layerContainerViewFromScene:scene];
}

- (UIView *)newSceneViewForScene:(id)scene size:(CGSize)size {
    // FrontBoard / SpringBoard expose several spellings across iOS versions.
    NSArray *selectors = @[
        @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:",
        @"newSceneViewWithReferenceSize:orientation:hostRequester:",
        @"newSceneViewWithReferenceSize:hostRequester:",
    ];
    for (NSString *name in selectors) {
        SEL sel = NSSelectorFromString(name);
        if (![scene respondsToSelector:sel]) {
            self.hostViewDiag = [NSString stringWithFormat:@"no-respond %@", name];
            continue;
        }
        NSMethodSignature *sig = [scene methodSignatureForSelector:sel];
        if (!sig) {
            self.hostViewDiag = [NSString stringWithFormat:@"no-sig %@", name];
            continue;
        }
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = scene;
            inv.selector = sel;
            NSUInteger argc = sig.numberOfArguments;
            [inv setArgument:&size atIndex:2];
            NSInteger zero = 0;
            if (argc > 4) { [inv setArgument:&zero atIndex:3]; [inv setArgument:&zero atIndex:4]; }
            else if (argc > 3) { [inv setArgument:&zero atIndex:3]; }
            if (argc > 5) {
                NSString *req = self.requesterToken ?: @"InteractivePiP";
                [inv setArgument:&req atIndex:5];
            }
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            UIView *v = (UIView *)result;
            if (![v isKindOfClass:[UIView class]] && [v respondsToSelector:@selector(view)]) {
                self.retainedSceneController = v;
                v = ((UIView *(*)(id, SEL))objc_msgSend)(v, @selector(view));
            }
            if ([v isKindOfClass:[UIView class]] && v.frame.size.height > 1) {
                self.hostViewDiag = [NSString stringWithFormat:@"ok %@ -> %@", name, NSStringFromClass([v class])];
                return v;
            }
            self.hostViewDiag = [NSString stringWithFormat:@"bad-view %@ h=%.1f", name, v ? ((UIView *)v).frame.size.height : 0.0];
        } @catch (NSException *e) {
            self.hostViewDiag = [NSString stringWithFormat:@"throw %@: %@", name, e.name];
            NSLog(@"[InteractivePiP] %@ failed: %@", name, e);
        }
    }
    return nil;
}

- (nullable id)layerManagerFromScene:(id)scene {
    if (!scene) return nil;
    id layerManager = nil;
    SEL managerSelector = NSSelectorFromString(@"layerManager");
    @try {
        if ([scene respondsToSelector:managerSelector]) {
            layerManager = ((id (*)(id, SEL))objc_msgSend)(scene, managerSelector);
        } else {
            layerManager = [scene valueForKey:@"layerManager"];
        }
    } @catch (__unused NSException *exception) {}
    return layerManager;
}

- (BOOL)layerHasExternalSceneID:(id)layer {
    if (!layer) return NO;
    // Prefer the FrontBoard external marker first. Some layer objects expose
    // sceneID for the keyboard extension scene as a secondary fallback.
    for (NSString *key in @[@"externalSceneID", @"sceneID"]) {
        @try {
            SEL selector = NSSelectorFromString(key);
            id value = nil;
            if ([layer respondsToSelector:selector]) {
                value = ((id (*)(id, SEL))objc_msgSend)(layer, selector);
            } else if ([layer respondsToSelector:NSSelectorFromString(@"valueForKey:")]) {
                value = [layer valueForKey:key];
            }
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                // sceneID alone is only accepted for FBSExternalSceneLayer-like classes.
                if ([key isEqualToString:@"sceneID"]) {
                    NSString *className = NSStringFromClass([layer class]);
                    if ([className rangeOfString:@"External" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                        continue;
                    }
                }
                return YES;
            }
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

- (nullable Class)externalSceneHostClass {
    SEL initializer = NSSelectorFromString(@"initWithSceneLayer:parentScene:");
    for (NSString *name in @[@"FBExternalSceneLayerHostView",
                             @"_UIExternalSceneLayerHostView",
                             @"UIExternalSceneLayerHostView"]) {
        Class cls = NSClassFromString(name);
        if (cls && [cls instancesRespondToSelector:initializer]) {
            return cls;
        }
    }
    return Nil;
}

- (NSArray *)externalSceneLayers {
    if (!self.scene) return @[];

    id layerManager = [self layerManagerFromScene:self.scene];
    if (!layerManager) return @[];

    id layers = nil;
    SEL layersSelector = NSSelectorFromString(@"layers");
    @try {
        if ([layerManager respondsToSelector:layersSelector]) {
            layers = ((id (*)(id, SEL))objc_msgSend)(layerManager, layersSelector);
        } else {
            layers = [layerManager valueForKey:@"layers"];
        }
    } @catch (__unused NSException *exception) {}

    NSMutableArray *external = [NSMutableArray array];
    for (id layer in [self arrayFromCollection:layers]) {
        if ([self layerHasExternalSceneID:layer]) {
            [external addObject:layer];
        }
    }
    return [external copy];
}

- (void)startObservingLayerManager {
    id layerManager = [self layerManagerFromScene:self.scene];
    if (!layerManager) return;
    if (self.observingLayerManager && self.observedLayerManager == layerManager) return;

    [self stopObservingLayerManager];
    @try {
        [layerManager addObserver:self
                       forKeyPath:@"layers"
                          options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld)
                          context:NULL];
        self.observedLayerManager = layerManager;
        self.observingLayerManager = YES;
    } @catch (NSException *exception) {
        NSLog(@"[InteractivePiP] layer observe failed %@: %@", self.bundleID, exception);
        self.observedLayerManager = nil;
        self.observingLayerManager = NO;
    }
}

- (void)stopObservingLayerManager {
    if (!self.observingLayerManager || !self.observedLayerManager) {
        self.observedLayerManager = nil;
        self.observingLayerManager = NO;
        return;
    }
    @try {
        [self.observedLayerManager removeObserver:self forKeyPath:@"layers"];
    } @catch (__unused NSException *exception) {}
    self.observedLayerManager = nil;
    self.observingLayerManager = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"layers"] && object == self.observedLayerManager) {
        [self scheduleExternalSceneRefresh];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)scheduleExternalSceneRefresh {
    NSUInteger generation = ++self.externalRefreshGeneration;
    NSArray<NSNumber *> *delays = @[@0.0, @0.05, @0.12, @0.25, @0.5, @0.9, @1.5, @2.5];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (!self2 || generation != self2.externalRefreshGeneration) return;
            [self2 refreshExternalSceneHosts];
        });
    }
}

- (void)refreshExternalSceneHosts {
    [self startObservingLayerManager];

    NSArray *layers = [self externalSceneLayers];
    if (layers.count == 0) {
        [self clearExternalSceneHosts];
        return;
    }

    UIView *root = self.view.window.rootViewController.view ?: self.view.window;
    if (!root) return;
    if ([layers isEqualToArray:self.hostedExternalLayers]
        && self.externalSceneContainer.superview == root) {
        self.externalSceneContainer.frame = root.bounds;
        [root bringSubviewToFront:self.externalSceneContainer];
        return;
    }

    Class externalHostClass = [self externalSceneHostClass];
    SEL initializer = NSSelectorFromString(@"initWithSceneLayer:parentScene:");
    if (!externalHostClass) {
        NSLog(@"[InteractivePiP] no external scene host class for %@", self.bundleID);
        return;
    }

    UIView *container = [[UIView alloc] initWithFrame:root.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    // YES: QQ 内容必须接收触摸才能点击聊天。chrome 按钮在 chromeView（上层），
    // 不受影响。0.7.61 把这里设为 NO 导致悬浮窗无法点击。
    container.userInteractionEnabled = YES;
    container.clipsToBounds = NO;
    NSUInteger created = 0;
    for (id layer in layers) {
        @try {
            id allocated = [externalHostClass alloc];
            UIView *host = ((id (*)(id, SEL, id, id))objc_msgSend)(
                allocated, initializer, layer, self.scene);
            if (![host isKindOfClass:[UIView class]]) continue;
            host.frame = container.bounds;
            host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            host.userInteractionEnabled = YES;
            [container addSubview:host];
            created += 1;
        } @catch (NSException *exception) {
            NSLog(@"[InteractivePiP] external host create failed %@: %@", self.bundleID, exception);
        }
    }
    if (created == 0) {
        NSLog(@"[InteractivePiP] external layers present but host create failed %@ count=%@",
              self.bundleID, @(layers.count));
        return;
    }

    [self.externalSceneContainer removeFromSuperview];
    self.hostedExternalLayers = [layers copy];
    self.externalSceneContainer = container;
    [root addSubview:container];
    [root bringSubviewToFront:container];
    NSLog(@"[InteractivePiP] external scene hosts %@ class=%@ layers=%@",
          self.bundleID, NSStringFromClass(externalHostClass), @(created));
}

- (void)clearExternalSceneHosts {
    [self.externalSceneContainer removeFromSuperview];
    self.externalSceneContainer = nil;
    self.hostedExternalLayers = @[];
}

#pragma mark - Snapshot / icon

- (UIImage *)iconImageLarge {
    id app = [self sbApplication];
    if (app) {
        for (NSString *key in @[@"iconImage", @"_iconImage"]) {
            @try {
                id img = [app valueForKey:key];
                if ([img isKindOfClass:[UIImage class]]) return img;
            } @catch (__unused NSException *e) {}
        }
        // iconImageForFormat: 0 = home screen style (best-effort)
        SEL sel = NSSelectorFromString(@"iconImageForFormat:");
        if ([app respondsToSelector:sel]) {
            @try {
                NSMethodSignature *sig = [app methodSignatureForSelector:sel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app;
                    inv.selector = sel;
                    NSInteger fmt = 0;
                    [inv setArgument:&fmt atIndex:2];
                    [inv invoke];
                    __unsafe_unretained id img = nil;
                    [inv getReturnValue:&img];
                    if ([img isKindOfClass:[UIImage class]]) return img;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

- (UIImage *)snapshotImage {
    id handle = self.sceneHandle ?: [self sceneHandleForBundleID];
    if (handle) {
        for (NSString *name in @[@"snapshotView", @"sceneSnapshotView", @"_snapshotView"]) {
            @try {
                id v = nil;
                SEL sel = NSSelectorFromString(name);
                if ([handle respondsToSelector:sel]) {
                    v = ((id (*)(id, SEL))objc_msgSend)(handle, sel);
                } else {
                    v = [handle valueForKey:name];
                }
                if ([v isKindOfClass:[UIImage class]]) return v;
                if ([v isKindOfClass:[UIView class]]) {
                    UIView *vv = (UIView *)v;
                    if (vv.bounds.size.width > 1 && vv.bounds.size.height > 1) {
                        UIGraphicsBeginImageContextWithOptions(vv.bounds.size, NO, 0);
                        [vv drawViewHierarchyInRect:vv.bounds afterScreenUpdates:NO];
                        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
                        UIGraphicsEndImageContext();
                        if (img) return img;
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return [self iconImageLarge];
}

#pragma mark - Main attach

- (void)attemptLiveSceneHost {
    if (self.invalidated || self.attaching || (self.live && self.hostView.superview == self.view)) return;
    self.attaching = YES;
    self.attemptCount += 1;

    @try {
        if ([self.bundleID isEqualToString:@"com.apple.springboard"]) {
            self.statusText = @"主屏幕";
            [self updatePlaceholderHint:@"主屏幕区域\n（右侧/下方是你选择的应用）"];
            self.placeholder.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1];
            self.live = NO;
            return;
        }

        // The established path is SBApplication.mainScene.hostManager.
        // Scene-handle factories differ across iOS versions and often render blank.
        id scene = [self findFBScene];
        self.scene = scene;
        if (scene) {
            CGSize size = [UIScreen mainScreen].bounds.size;
            if (size.width < 2 || size.height < 2) size = CGSizeMake(390, 844);
            self.nativeSceneSize = size;
            [self applySceneForeground:YES backgrounded:NO size:size includeFrame:YES];

            UIView *hv = [self hostViewFromFBScene:scene];
            if (hv) {
                [self attachHostView:hv scene:scene];
                self.statusText = @"已连接画面";
                return;
            }
            self.statusText = [NSString stringWithFormat:@"找到 %@，但没有可用宿主图层",
                               NSStringFromClass([scene class])];
            NSLog(@"[InteractivePiP] scene found but no host view: %@ class=%@",
                  self.bundleID, NSStringFromClass([scene class]));
        } else {
            self.statusText = @"应用尚未在后台运行";
            NSLog(@"[InteractivePiP] no scene for %@", self.bundleID);
        }

        [self applySnapshotFallback];
        [self scheduleReconnect];
    } @finally {
        self.attaching = NO;
    }
}

- (void)startSceneKeepAlive {
    if (self.keepAliveTimer || !self.scene || !self.live) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || !self2.live || !self2.scene) return;
        // Do NOT force foreground every second: that pins hosted scenes above
        // the home/lock screen and is the "rebound after a few seconds" cause.
        // [self2 applySceneForeground:YES backgrounded:NO size:CGSizeZero includeFrame:NO];
        [self2 acquireProcessAssertionIfNeeded];
        [self2 refreshExternalSceneHosts];
    });
    self.keepAliveTimer = timer;
    dispatch_resume(timer);
}

- (void)stopSceneKeepAlive {
    if (!self.keepAliveTimer) return;
    dispatch_source_cancel(self.keepAliveTimer);
    self.keepAliveTimer = nil;
}

- (void)scheduleReconnect {
    if (self.invalidated || self.reconnectTimer || self.live) return;

    self.reconnectAttempts = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                      dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                              (uint64_t)(0.75 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || self2.live || self2.reconnectAttempts >= 20) {
            [self2 stopReconnect];
            return;
        }
        self2.reconnectAttempts += 1;
        [self2 retryAttach];
        if (self2.live) [self2 stopReconnect];
    });
    self.reconnectTimer = timer;
    dispatch_resume(timer);
}

- (void)stopReconnect {
    if (!self.reconnectTimer) return;
    dispatch_source_cancel(self.reconnectTimer);
    self.reconnectTimer = nil;
    self.reconnectAttempts = 0;
}

- (int)hostedApplicationPID {
    id app = [self sbApplication];
    if (!app) return 0;

    @try {
        SEL pidSelector = NSSelectorFromString(@"pid");
        if ([app respondsToSelector:pidSelector]) {
            int pid = ((int (*)(id, SEL))objc_msgSend)(app, pidSelector);
            if (pid > 0) return pid;
        }

        SEL processStateSelector = NSSelectorFromString(@"processState");
        if ([app respondsToSelector:processStateSelector]) {
            id state = ((id (*)(id, SEL))objc_msgSend)(app, processStateSelector);
            if ([state respondsToSelector:pidSelector]) {
                int pid = ((int (*)(id, SEL))objc_msgSend)(state, pidSelector);
                if (pid > 0) return pid;
            }
        }
    } @catch (__unused NSException *e) {}
    return 0;
}

- (void)acquireProcessAssertionIfNeeded {
    if (self.processAssertion || self.processAssertionAttempted) return;
    int pid = [self hostedApplicationPID];
    if (pid <= 0) return;

    Class targetClass = NSClassFromString(@"RBSTarget");
    Class attributeClass = NSClassFromString(@"RBSLegacyAttribute");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    if (!targetClass || !attributeClass || !assertionClass) {
        self.processAssertionAttempted = YES;
        return;
    }

    @try {
        SEL targetSelector = NSSelectorFromString(@"targetWithPid:");
        id target = ((id (*)(id, SEL, int))objc_msgSend)(targetClass, targetSelector, pid);
        NSUInteger flags = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5);
        SEL attributeSelector = NSSelectorFromString(@"attributeWithReason:flags:");
        id attribute = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(
            attributeClass, attributeSelector, 7, flags);
        if (!target || !attribute) return;

        id assertion = [assertionClass alloc];
        SEL initSelector = NSSelectorFromString(@"initWithExplanation:target:attributes:");
        assertion = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            assertion, initSelector, @"DualPane live app host", target, @[attribute]);
        if (!assertion) return;

        NSError *error = nil;
        SEL acquireSelector = NSSelectorFromString(@"acquireWithError:");
        BOOL acquired = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(
            assertion, acquireSelector, &error);
        self.processAssertionAttempted = YES;
        if (acquired) {
            self.processAssertion = assertion;
            NSLog(@"[InteractivePiP] process assertion acquired %@ pid=%d", self.bundleID, pid);
        } else {
            NSLog(@"[InteractivePiP] process assertion failed %@: %@", self.bundleID, error);
        }
    } @catch (NSException *e) {
        self.processAssertionAttempted = YES;
        NSLog(@"[InteractivePiP] process assertion exception %@: %@", self.bundleID, e);
    }
}

- (void)dealloc {
    // RBSAssertion raises if it is deallocated while still valid. Any release
    // path (ARC teardown from the window hierarchy, home exit, reload) must
    // invalidate it first, otherwise SpringBoard dies in .cxx_destruct.
    // Do everything inline: calling helpers here can touch already-released
    // weak refs.
    if (_keepAliveTimer) { dispatch_source_cancel(_keepAliveTimer); _keepAliveTimer = nil; }
    if (_reconnectTimer) { dispatch_source_cancel(_reconnectTimer); _reconnectTimer = nil; }
    if (_observingLayerManager && _observedLayerManager) {
        @try { [_observedLayerManager removeObserver:self forKeyPath:@"layers"]; }
        @catch (__unused NSException *e) {}
        _observingLayerManager = NO;
        _observedLayerManager = nil;
    }
    DPInvalidateHostView(_hostView, @"owner-dealloc");
    id assertion = _processAssertion;
    if (assertion) {
        SEL invalidate = NSSelectorFromString(@"invalidate");
        if ([assertion respondsToSelector:invalidate]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(assertion, invalidate); }
            @catch (__unused NSException *e) {}
        }
        _processAssertion = nil;
    }
}

- (void)releaseProcessAssertion {
    SEL invalidate = NSSelectorFromString(@"invalidate");
    if ([self.processAssertion respondsToSelector:invalidate]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(self.processAssertion, invalidate);
        } @catch (__unused NSException *e) {}
    }
    self.processAssertion = nil;
    self.processAssertionAttempted = NO;
}

- (void)attachHostView:(UIView *)hostView scene:(id)scene {
    if (!hostView) return;

    [self stopReconnect];

    if (self.hostView == hostView && hostView.superview == self.view) {
        self.scene = scene ?: self.scene;
        [self layoutHostView];
        self.placeholder.hidden = YES;
        self.snapshotView.hidden = YES;
        self.live = YES;
    [self startObservingLayerManager];
    [self startSceneKeepAlive];
        return;
    }

    if (self.hostView != hostView) {
        DPInvalidateHostView(self.hostView, @"replace");
        [self.hostView removeFromSuperview];
    }
    self.hostView = hostView;
    self.scene = scene;
    self.lastCommittedSceneSize = CGSizeZero;
    if (self.nativeSceneSize.width < 2 || self.nativeSceneSize.height < 2) {
        self.nativeSceneSize = [UIScreen mainScreen].bounds.size;
    }
    hostView.autoresizingMask = UIViewAutoresizingNone; // 0.7.5 cover-scale: bounds+center+transform own the geometry; flexible mask fights the transform
    hostView.clipsToBounds = YES;
    [self.view addSubview:hostView];
    [self.view bringSubviewToFront:hostView];
    [self layoutHostView];

    self.placeholder.hidden = YES;
    self.snapshotView.hidden = YES;
    self.live = YES;

    [self commitHostedFrame];
    [self startObservingLayerManager];
    [self startSceneKeepAlive];
    [self acquireProcessAssertionIfNeeded];
    NSLog(@"[InteractivePiP] LIVE attach %@ view=%@", self.bundleID, NSStringFromClass([hostView class]));
}

- (void)layoutHostView {
    if (!self.hostView) return;

    CGSize target = self.view.bounds.size;
    CGSize canvas = self.nativeSceneSize;
    if (canvas.width < 2 || canvas.height < 2) canvas = [UIScreen mainScreen].bounds.size;
    if (target.width < 1 || target.height < 1 || canvas.width < 1 || canvas.height < 1) return;

    // 0.7.5 original: uniform cover-scale into the pane (aspect fill).
    // Keeps app aspect ratio (no stretch), fills pane, clips overflow.
    self.hostView.transform = CGAffineTransformIdentity;
    self.hostView.bounds = CGRectMake(0, 0, canvas.width, canvas.height);
    self.hostView.center = CGPointMake(target.width / 2.0, target.height / 2.0);
    CGFloat scale = MAX(target.width / canvas.width, target.height / canvas.height);
    self.view.clipsToBounds = YES;
    self.hostView.transform = CGAffineTransformMakeScale(scale, scale);
    self.layoutDiag = [NSString stringWithFormat:@"view=%@ canvas=%@ sc=%.3f",
                       NSStringFromCGSize(target), NSStringFromCGSize(canvas), scale];
}

- (void)applySnapshotFallback {
    UIImage *snap = self.snapshotView.image;
    if (!self.snapshotAttempted) {
        self.snapshotAttempted = YES;
        snap = [self snapshotImage];
    }
    if (!self.snapshotView) {
        self.snapshotView = [[UIImageView alloc] initWithFrame:self.view.bounds];
        self.snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.snapshotView.contentMode = UIViewContentModeScaleAspectFill;
        self.snapshotView.clipsToBounds = YES;
        self.snapshotView.alpha = 0.35;
        [self.view insertSubview:self.snapshotView aboveSubview:self.placeholder];
    }
    if (snap && snap != self.iconView.image) {
        self.snapshotView.image = snap;
        self.snapshotView.hidden = NO;
    } else {
        self.snapshotView.hidden = YES;
    }

    NSString *hint = nil;
    if (self.scene || self.sceneHandle) {
        hint = [NSString stringWithFormat:
                @"暂时无法嵌入实时画面\n%@\niOS %@",
                self.statusText ?: @"", [UIDevice currentDevice].systemVersion];
    } else {
        hint = [NSString stringWithFormat:
                @"%@\n正在后台创建 scene（最长约 3 秒）\n若仍失败请点「重新连接」",
                self.statusText ?: @"应用尚未在后台运行"];
    }
    [self updatePlaceholderHint:hint];
    self.placeholder.hidden = NO;
    self.live = NO;
}

#pragma mark - Placeholder UI

- (void)buildPlaceholder {
    self.placeholder = [[UIView alloc] initWithFrame:self.view.bounds];
    self.placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 深灰，不要系统蓝——避免被看成「蓝屏」
    self.placeholder.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    [self.view addSubview:self.placeholder];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.tag = 7701;
    [self.placeholder addSubview:stack];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.layer.cornerRadius = 14;
    self.iconView.clipsToBounds = YES;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.iconView.image = [self iconImageLarge];
    [stack addArrangedSubview:self.iconView];
    [self.iconView.widthAnchor constraintEqualToConstant:64].active = YES;
    [self.iconView.heightAnchor constraintEqualToConstant:64].active = YES;

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.nameLabel.text = [self displayNameForBundleID:self.bundleID];
    [stack addArrangedSubview:self.nameLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.text = @"正在连接应用画面…";
    [stack addArrangedSubview:self.hintLabel];

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"重新连接画面" forState:UIControlStateNormal];
    retry.tintColor = [UIColor colorWithRed:0.45 green:0.72 blue:1.0 alpha:1.0];
    retry.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [retry addTarget:self action:@selector(retryAttach) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:retry];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.placeholder.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.placeholder.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.placeholder.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.placeholder.trailingAnchor constant:-16],
    ]];
}

- (void)updatePlaceholderHint:(NSString *)text {
    self.hintLabel.text = text;
    self.placeholder.hidden = NO;
    if (!self.iconView.image) {
        self.iconView.image = [self iconImageLarge];
    }
    if (!self.nameLabel.text.length) {
        self.nameLabel.text = [self displayNameForBundleID:self.bundleID];
    }
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return @"主屏幕";
    id app = [self sbApplication];
    if (app) {
        @try {
            NSString *n = [app valueForKey:@"displayName"];
            if (n.length) return n;
        } @catch (__unused NSException *e) {}
    }
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(LSApplicationProxy,
            @selector(applicationProxyForIdentifier:), bundleID);
        @try {
            NSString *name = [proxy valueForKey:@"localizedName"];
            if (name.length) return name;
        } @catch (__unused NSException *e) {}
    }
    NSString *last = [[bundleID componentsSeparatedByString:@"."] lastObject];
    return last.length ? last.capitalizedString : bundleID;
}

#pragma mark - Public

- (void)enableInteractionInView:(UIView *)view {
    if (!view) return;
    view.userInteractionEnabled = YES;
    view.multipleTouchEnabled = YES;
    for (UIView *subview in view.subviews) {
        [self enableInteractionInView:subview];
    }
}

- (UIView *)keyboardRoutingView {
    // A hosted scene view is the ideal keyboard host, but the remote keyboard
    // registration does not care what the host view is called: it only needs a
    // view that actually presents the remote scene, plus the app pid and the
    // scene identity. Requiring the "Scene" class name here silently skipped the
    // registration on every build that fell back to a host manager view or a
    // layer container, which is exactly why the keyboard window appeared with
    // no content at all.
    if (!self.live || !self.hostView) return nil;
    return self.hostView;
}

- (id)keyboardRoutingScene { return self.live ? self.scene : nil; }

- (BOOL)keyboardHostIsSceneView { return self.hostIsSceneView; }

- (int)keyboardRoutingPID { return [self hostedApplicationPID]; }

- (void)prepareForInput {
    if (!self.scene || !self.live) return;
    id hostManager = [self hostManagerFromScene:self.scene];
    [self enableHostingOnManager:hostManager];

    NSString *requester = self.requesterToken ?: @"DualPane";
    SEL orderFront = NSSelectorFromString(@"orderRequesterFront:");
    if ([hostManager respondsToSelector:orderFront]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(hostManager, orderFront, requester);
        } @catch (__unused NSException *exception) {}
    }

    for (NSString *name in @[@"setInteractionEnabled:forRequester:",
                             @"setAllowsInteraction:forRequester:",
                             @"setUserInteractionEnabled:forRequester:",
                             @"setHostingInteractionEnabled:forRequester:",
                             @"setHostingEnabled:forRequester:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![hostManager respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [hostManager methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments < 4) continue;
        @try {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = hostManager;
            invocation.selector = selector;
            BOOL enabled = YES;
            [invocation setArgument:&enabled atIndex:2];
            [invocation setArgument:&requester atIndex:3];
            [invocation invoke];
        } @catch (__unused NSException *exception) {}
    }

    for (NSString *name in @[@"enableInteractionForRequester:",
                             @"enableUserInteractionForRequester:",
                             @"enableHostingInteractionForRequester:"]) {
        SEL selector = NSSelectorFromString(name);
        if (![hostManager respondsToSelector:selector]) continue;
        NSMethodSignature *signature = [hostManager methodSignatureForSelector:selector];
        if (!signature || signature.numberOfArguments < 3) continue;
        @try {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = hostManager;
            invocation.selector = selector;
            [invocation setArgument:&requester atIndex:2];
            [invocation invoke];
        } @catch (__unused NSException *exception) {}
    }

    [self enableInteractionInView:self.hostView];
    self.view.userInteractionEnabled = YES;
    [self applySceneForeground:YES backgrounded:NO size:CGSizeZero includeFrame:NO];
    [self startObservingLayerManager];
    [self scheduleExternalSceneRefresh];
}

- (void)setHostedFrame:(CGRect)frame {
    if (self.view.superview) {
        self.view.frame = self.view.superview.bounds;
    } else {
        self.view.frame = frame;
    }
    [self layoutHostView];
    self.placeholder.frame = self.view.bounds;
    self.snapshotView.frame = self.view.bounds;

}


- (void)commitHostedFrame {
    if (self.live && self.scene) {
        [self updateSceneSettingsWithSize:self.view.bounds.size];
    }
}

- (void)updateSceneSettingsWithSize:(CGSize)size {
    if (!self.scene || size.width < 1 || size.height < 1) return;
    if (CGSizeEqualToSize(size, self.lastCommittedSceneSize)) return;
    // Keep scene full-screen: a half-screen setFrame is invalid on iOS 16 and
    // kills the hosted pid. Scale the host view uniformly into the pane.
    if ([self applySceneForeground:YES backgrounded:NO size:CGSizeZero includeFrame:NO]) {
        self.lastCommittedSceneSize = size;
        self.layoutDiag = [NSString stringWithFormat:@"view=%@ pane=%d",
                           NSStringFromCGSize(self.view.bounds.size), self.scene ? 1 : 0];
    }
}

- (void)setSuspended:(BOOL)suspended {
    self.view.alpha = suspended ? 0.0 : 1.0;
    if (suspended) {
        [self stopSceneKeepAlive];
    } else {
        [self applySceneForeground:YES backgrounded:NO size:CGSizeZero includeFrame:NO];
    [self startObservingLayerManager];
    [self startSceneKeepAlive];
    }
}

- (void)retryAttach {
    if (self.invalidated || self.attaching) return;
    if (self.settingsScene && self.originalSettings) [self submitSettings:self.originalSettings toScene:self.settingsScene];
    self.settingsScene = nil; self.originalSettings = nil;
    NSLog(@"[InteractivePiP] retryAttach #%@ %@", @(self.attemptCount + 1), self.bundleID);
    self.externalRefreshGeneration += 1;
    [self stopObservingLayerManager];
    [self clearExternalSceneHosts];
    [self stopSceneKeepAlive];
    [self releaseProcessAssertion];
    DPInvalidateHostView(self.hostView, @"retry");
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.retainedSceneController = nil;
    self.live = NO;
    self.scene = nil;
    self.lastCommittedSceneSize = CGSizeZero;
    // 保留 sceneHandle 缓存也可清掉重找
    self.sceneHandle = nil;
    self.placeholder.hidden = NO;
    [self updatePlaceholderHint:@"正在重新连接…"];
    [self attemptLiveSceneHost];
}

- (void)invalidate {
    self.invalidated = YES;
    self.externalRefreshGeneration += 1;
    [self stopObservingLayerManager];
    [self clearExternalSceneHosts];
    [self stopSceneKeepAlive];
    [self stopReconnect];
    [self releaseProcessAssertion];
    if (self.settingsScene && self.originalSettings) {
        [self submitSettings:self.originalSettings toScene:self.settingsScene];
    }
    self.settingsScene = nil; self.originalSettings = nil;
    if (self.scene) {
        id hostManager = [self hostManagerFromScene:self.scene];
        if (hostManager) {
            NSString *req = self.requesterToken ?: @"DualPane";
            for (NSString *name in @[@"invalidateHostViewForRequester:",
                                     @"disableHostingForRequester:",
                                     @"disableHostingForRequester:priority:"]) {
                SEL sel = NSSelectorFromString(name);
                if (![hostManager respondsToSelector:sel]) continue;
                @try {
                    if ([name containsString:@"priority"]) {
                        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
                        if (!sig) continue;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = hostManager;
                        inv.selector = sel;
                        [inv setArgument:&req atIndex:2];
                        NSInteger prio = 1;
                        [inv setArgument:&prio atIndex:3];
                        [inv invoke];
                    } else {
                        ((void (*)(id, SEL, id))objc_msgSend)(hostManager, sel, req);
                    }
                } @catch (__unused NSException *e) {}
            }
        }
    }
    DPInvalidateHostView(self.hostView, @"close");
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.retainedSceneController = nil;
    [self.view removeFromSuperview];
    self.scene = nil;
    self.sceneHandle = nil;
    self.nativeSceneSize = CGSizeZero;
    self.live = NO;
}

@end
