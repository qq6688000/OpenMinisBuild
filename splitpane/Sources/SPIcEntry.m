#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPWindowRegistry.h"

// ============================================================================
// 长按主屏图标 → 菜单里多一项「上下分屏」
//
// 参考实现：InteractivePiP Duo 0.7.50（Sources/Tweak.x）
//
// 之前四版为什么全挂：
//   0.4.22  valueForKey:@"menuProvider"                    → NSValueForUndefinedKeyException
//   0.4.23  object_getIvar 遍历 UIContextMenuConfiguration → weak ivar 野指针 SIGSEGV
//   0.4.24  换 offset memcpy                             → 手机没装上，仍跑 0.4.21
//   0.4.25  完全不改系统菜单、另弹浮层                     → 能用但体验割裂
//
// 正解：系统长按菜单的数据源是 -[SBIconView applicationShortcutItems]，
// 返回 NSArray<SBSApplicationShortcutItem *>。往这个数组里插一项即可，
// 既不用读 UIContextMenuConfiguration 的任何私有字段，也不会动系统原有菜单项。
//
// 点击拦截要 hook 三个类 × 两个签名（不同 iOS 版本走不同路径）：
//   SBIconView       -activateShortcut:withBundleIdentifier:forIconView:
//   SBIconController -appIconView:activateShortcut:withBundleIdentifier:
//                    -activateShortcut:withBundleIdentifier:forIconView:
//   SBHIconManager   -iconView:activateShortcut:withBundleIdentifier:
//                    -activateShortcut:withBundleIdentifier:forIconView:
// ============================================================================

static NSString *const kSPSplitType = @"com.seagull.splitpane.action.split";

#pragma mark - 取 bundleID

static NSString *SPStringOrNil(id v) {
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}

static NSString *SPBundleIDFromIcon(id icon) {
    if (!icon) return nil;
    @try {
        SEL s = NSSelectorFromString(@"isFolderIcon");
        if ([icon respondsToSelector:s]) {
            BOOL (^b)(void) = ^{ return ((BOOL (*)(id, SEL))objc_msgSend)(icon, s); };
            if (b()) return nil;
        }
    } @catch (__unused NSException *e) {}
    NSString *a = SPStringOrNil(SPMsg0(icon, @"applicationBundleID"));
    if (a) return a;
    NSString *b = SPStringOrNil(SPMsg0(icon, @"bundleIdentifier"));
    if (b) return b;
    id app = [icon respondsToSelector:NSSelectorFromString(@"application")] ? SPMsg0(icon, @"application") : nil;
    if (app) {
        NSString *c = SPStringOrNil(SPMsg0(app, @"bundleIdentifier"));
        if (c) return c;
    }
    return nil;
}

static NSString *SPBundleIDForIconView(id iconView) {
    if (!iconView) return nil;
    id icon = nil;
    @try { icon = SPMsg0(iconView, @"icon"); } @catch (__unused NSException *e) {}
    return SPBundleIDFromIcon(icon);
}

#pragma mark - 造 shortcut item

static id SPMakeSystemIcon(NSString *name) {
    if (!name.length) return nil;
    Class C = NSClassFromString(@"SBSApplicationShortcutSystemIcon");
    if (!C) return nil;
    SEL s1 = NSSelectorFromString(@"iconWithSystemImageName:");
    if ([C respondsToSelector:s1])
        return ((id (*)(id, SEL, id))objc_msgSend)(C, s1, name);
    SEL s2 = NSSelectorFromString(@"initWithSystemImageName:");
    if ([C instancesRespondToSelector:s2])
        return ((id (*)(id, SEL, id))objc_msgSend)([C alloc], s2, name);
    return nil;
}

static void SPSetIf( id obj, NSString *selName, id value) {
    SEL s = NSSelectorFromString(selName);
    if (!s || !obj) return;
    @try {
        if ([obj respondsToSelector:s]) ((void (*)(id, SEL, id))objc_msgSend)(obj, s, value);
    } @catch (__unused NSException *e) {}
}

static id SPMakeShortcutItem(void) {
    Class C = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!C) return nil;
    id item = [[C alloc] init];
    if (!item) return nil;
    SPSetIf(item, @"setType:", kSPSplitType);
    SPSetIf(item, @"setLocalizedTitle:", @"上下分屏");
    SPSetIf(item, @"setLocalizedSubtitle:", @"两块各占半屏");
    id ic = SPMakeSystemIcon(@"rectangle.split.1x2");
    if (ic) SPSetIf(item, @"setIcon:", ic);
    // bundleIdentifierToLaunch 故意不设 —— 我们自己处理，不让系统去启动 App
    SPSetIf(item, @"setUserInfo:", @{ @"splitpane": @YES });
    return item;
}

static BOOL SPIsOurType(NSString *type) {
    return [type isKindOfClass:[NSString class]] && [type isEqualToString:kSPSplitType];
}

static NSString *SPTypeOf(id item) {
    if (!item) return nil;
    id t = SPMsg0(item, @"type");
    return [t isKindOfClass:[NSString class]] ? t : nil;
}

#pragma mark - 点击处理

static BOOL SPHandleShortcut(id item, NSString *bundleID, id iconView) {
    NSString *type = SPTypeOf(item);
    if (!SPIsOurType(type)) return NO;

    NSString *bid = bundleID.length ? bundleID : SPBundleIDForIconView(iconView);
    if (!bid.length) bid = SPBundleIDFromIcon(iconView);
    if (!bid.length) {
        SPLog(@"icon menu: 点击了但取不到 bundleID，吞掉");
        return YES;
    }
    SPLog(@"icon menu -> split %@", bid);
    @try {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[SPGesture shared] startSplitFromIconForBundleID:bid];
        });
    } @catch (NSException *e) {
        SPLog(@"icon menu: start split ex %@", e.reason);
    }
    return YES;   // 吞掉，绝不让系统再全屏打开 App
}

#pragma mark - 安装

typedef void (*SPHookMsgExFn)(Class, SEL, IMP, IMP *);

// 统一注册：类不存在或方法不存在就跳过，不报错。
static BOOL SPTryHook(NSString *clsName, NSString *selName, IMP imp, IMP *orig) {
    Class cls = NSClassFromString(clsName);
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) return NO;
    SPHookMsgExFn hook = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(cls, sel, imp, orig);
    return YES;
}

// ---- applicationShortcutItems 注入 ----

typedef id (*SPShortcutItemsFn)(id, SEL);
static SPShortcutItemsFn gOrigShortcutItems = NULL;

static id SPHookedShortcutItems(id self, SEL _cmd) {
    id items = gOrigShortcutItems ? gOrigShortcutItems(self, _cmd) : nil;
    @try {
        NSString *bid = SPBundleIDForIconView(self);
        if (!bid.length) return items;      // 文件夹 / 组件 之类，不注入

        id ours = SPMakeShortcutItem();
        if (!ours) return items;

        NSMutableArray *out = items ? [items mutableCopy] : [NSMutableArray array];
        // 去重
        NSMutableIndexSet *rm = [NSMutableIndexSet indexSet];
        for (NSUInteger i = 0; i < out.count; i++) {
            if (SPIsOurType(SPTypeOf(out[i]))) [rm addIndex:i];
        }
        [out removeObjectsAtIndexes:rm];
        [out insertObject:ours atIndex:0];
        return out;
    } @catch (NSException *e) {
        SPLog(@"icon menu: 注入异常 %@", e.reason);
    }
    return items;
}


#pragma mark - 5 个 activate 入口

// 各入口签名不同，用宏统一生成；每个都要自己的 orig 指针。
#define SP_DEFINE_ACT(ivName, retType, args, callOrig)                       \
    static retType (*gOrig_##ivName) args;                                   \
    static retType SPOnActivateShortcut_##ivName args {                      \
        @try {                                                               \
            if (SPHandleShortcut(item, bundleID, iconView)) return;         \
        } @catch (NSException *e) { SPLog(@"icon menu: handle ex %@", e.reason); } \
        if (gOrig_##ivName) callOrig;                                         \
    }

// ---- SBIconView: -activateShortcut:withBundleIdentifier:forIconView:
static void (*gOrig_Act_IconView)(id, SEL, id, id, id) = NULL;
static void SPOnActivateShortcut_IconView(id self, SEL _cmd, id item, id bid, id iconView) {
    @try {
        if (SPHandleShortcut(item, bid, iconView)) return;
    } @catch (NSException *e) { SPLog(@"icon menu: iv ex %@", e.reason); }
    if (gOrig_Act_IconView) gOrig_Act_IconView(self, _cmd, item, bid, iconView);
}

// ---- SBIconController / SBHIconManager: -appIconView:activateShortcut:withBundleIdentifier:
static void (*gOrig_Act_Ctrl3)(id, SEL, id, id, id) = NULL;
static void SPOnActivateShortcut_Ctrl3(id self, SEL _cmd, id iconView, id item, id bid) {
    @try {
        if (SPHandleShortcut(item, bid, iconView)) return;
    } @catch (NSException *e) { SPLog(@"icon menu: c3 ex %@", e.reason); }
    if (gOrig_Act_Ctrl3) gOrig_Act_Ctrl3(self, _cmd, iconView, item, bid);
}

static void (*gOrig_Act_Mgr3)(id, SEL, id, id, id) = NULL;
static void SPOnActivateShortcut_Mgr3(id self, SEL _cmd, id iconView, id item, id bid) {
    @try {
        if (SPHandleShortcut(item, bid, iconView)) return;
    } @catch (NSException *e) { SPLog(@"icon menu: m3 ex %@", e.reason); }
    if (gOrig_Act_Mgr3) gOrig_Act_Mgr3(self, _cmd, iconView, item, bid);
}

// ---- -activateShortcut:withBundleIdentifier:forIconView:
static void (*gOrig_Act_Ctrl4)(id, SEL, id, id, id) = NULL;
static void SPOnActivateShortcut_Ctrl4(id self, SEL _cmd, id item, id bid, id iconView) {
    @try {
        if (SPHandleShortcut(item, bid, iconView)) return;
    } @catch (NSException *e) { SPLog(@"icon menu: c4 ex %@", e.reason); }
    if (gOrig_Act_Ctrl4) gOrig_Act_Ctrl4(self, _cmd, item, bid, iconView);
}

static void (*gOrig_Act_Mgr4)(id, SEL, id, id, id) = NULL;
static void SPOnActivateShortcut_Mgr4(id self, SEL _cmd, id item, id bid, id iconView) {
    @try {
        if (SPHandleShortcut(item, bid, iconView)) return;
    } @catch (NSException *e) { SPLog(@"icon menu: m4 ex %@", e.reason); }
    if (gOrig_Act_Mgr4) gOrig_Act_Mgr4(self, _cmd, item, bid, iconView);
}

void SPInstallIconMenuHook(void) {
    SPLog(@"icon menu: 开始安装");

    SPHookMsgExFn hook = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) { SPLog(@"icon menu: MSHookMessageEx 不可用"); return; }

    // 1) 数据源注入（核心）
    Class iconCls = NSClassFromString(@"SBIconView");
    SEL itemsSel = NSSelectorFromString(@"applicationShortcutItems");
    if (iconCls && [iconCls instancesRespondToSelector:itemsSel]) {
        hook(iconCls, itemsSel, (IMP)SPHookedShortcutItems, (IMP *)&gOrigShortcutItems);
        SPLog(@"icon menu: applicationShortcutItems hooked (orig=%p)", gOrigShortcutItems);
    } else {
        SPLog(@"icon menu: ⚠️ SBIconView 没有 applicationShortcutItems");
    }

    // 2) 点击拦截 —— 三个类 × 两个签名
    int n = 0;
    n += SPTryHook(@"SBIconView",
                   @"activateShortcut:withBundleIdentifier:forIconView:",
                   (IMP)SPOnActivateShortcut_IconView, NULL);
    n += SPTryHook(@"SBIconController",
                   @"appIconView:activateShortcut:withBundleIdentifier:",
                   (IMP)SPOnActivateShortcut_Ctrl3, NULL);
    n += SPTryHook(@"SBIconController",
                   @"activateShortcut:withBundleIdentifier:forIconView:",
                   (IMP)SPOnActivateShortcut_Ctrl4, NULL);
    n += SPTryHook(@"SBHIconManager",
                   @"iconView:activateShortcut:withBundleIdentifier:",
                   (IMP)SPOnActivateShortcut_Mgr3, NULL);
    n += SPTryHook(@"SBHIconManager",
                   @"activateShortcut:withBundleIdentifier:forIconView:",
                   (IMP)SPOnActivateShortcut_Mgr4, NULL);
    SPLog(@"icon menu: activate 入口 hooked %d/5", n);
}