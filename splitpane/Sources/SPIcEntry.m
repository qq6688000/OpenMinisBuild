#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import <string.h>

// 长按主屏图标 → 菜单里多一项「上下分屏」。
// 依据探针实测（0.4.18 日志）：
//   SBIconView 实现 contextMenuInteraction:configurationForMenuAtLocation: = Y
// 所以我们包一层，改写它返回的 configuration 的 actionProvider。

typedef id (*SPCtxMenuFn)(id, SEL, id, CGPoint);
static SPCtxMenuFn gOrigCtxMenu = NULL;

// 直接按 ivar 名读，不走 KVC —— KVC 读不存在的键会抛 NSValueForUndefinedKeyException，
// 而 UIContextMenuConfiguration 的 menuProvider ivar 名各系统版本不同（_menuProvider / _menuProviderBlock…），
// 在 hook 返回处抛出没人接 = SpringBoard SIGABRT。
// 一次性把 UIContextMenuConfiguration 的全部 ivar 打出来，用于定名。
static void SPDumpCtxMenuIvarsOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class cls = NSClassFromString(@"UIContextMenuConfiguration");
    unsigned n = 0;
    Ivar *ivs = class_copyIvarList(cls, &n);
    NSMutableString *msg = [NSMutableString stringWithFormat:@"ctxmenu ivars=%u:", n];
    for (unsigned i = 0; i < n; i++) {
        [msg appendFormat:@" %s(%s)", ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i])];
    }
    free(ivs);
    SPLog(@"%@", msg);
}

static id SPReadIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
}

// 不去猜 ivar 名了：遍历所有 ivar，按 block 签名识别谁可能是 menuProvider。
// UIContextMenuConfiguration 内部把动作块存在 _setupProvider / _menuProvider 之类的位置，
// 各版本命名不同，按类型认最稳。
static const char *SPBlockSignature(id blk) {
    if (!blk) return NULL;
    Class c = object_getClass(blk);
    if (!c || !class_conformsToProtocol(c, @protocol(NSObject))) {
        if (!class_getSuperclass(c)) return NULL;
    }
    // _NSConcreteStackBlock / __NSMallocBlock__ 都继承 NSBlock
    if (![[[blk class] description] containsString:@"Block"]) {
        Class sup = class_getSuperclass(object_getClass(blk));
        NSString *sn = sup ? NSStringFromClass(sup) : @"";
        if (![sn containsString:@"Block"]) return NULL;
    }
    // NSBlock 上 -signature 是私有方法，但 block 对象响应 invoke
    @try {
        SEL sigSel = NSSelectorFromString(@"signature");
        if ([blk respondsToSelector:sigSel]) {
            NSMethodSignature *ms = ((id (*)(id, SEL))objc_msgSend)(blk, sigSel);
            return [ms methodReturnType];
        }
    } @catch (__unused NSException *e) {}
    return NULL;
}

static id SPFindMenuProvider(id cfg) {
    unsigned n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(cfg), &n);
    id found = nil;
    for (unsigned i = 0; i < n; i++) {
        NSString *nm = [NSString stringWithUTF8String:ivar_getName(ivs[i])];
        id v = nil;
        @try { v = object_getIvar(cfg, ivs[i]); } @catch (__unused NSException *e) { continue; }
        if (!v || [v isKindOfClass:NSNull.class]) continue;
        NSString *cn = NSStringFromClass([v class]);
        BOOL isBlock = [cn containsString:@"Block"];
        SPLog(@"ctxmenu ivar %@ = %@%@", nm, cn, isBlock ? @" (block)" : @"");
        if (!isBlock) continue;
        // previewProvider 的返回类型是 UIViewController*，menuProvider 是 UIMenu*
        if ([nm rangeOfString:@"preview" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
        // 最终判据：menuProvider 的签名是「返回 UIMenu*，参数 NSArray*」
        NSMethodSignature *ms = nil;
        @try {
            SEL sigSel = NSSelectorFromString(@"signature");
            if ([v respondsToSelector:sigSel]) ms = ((id (*)(id, SEL))objc_msgSend)(v, sigSel);
        } @catch (__unused NSException *e) {}
        const char *rt = ms ? [ms methodReturnType] : NULL;
        NSInteger argc = ms ? (NSInteger)[ms numberOfArguments] : -1;
        SPLog(@"ctxmenu block %@ rt=%s argc=%ld", nm, rt ? rt : "?", (long)argc);
        BOOL looksMenu = (rt && strncmp(rt, "@", 1) == 0) && (argc == 2 || argc == 3);
        if (!looksMenu) continue;
        if (!found) found = v;
    }
    free(ivs);
    return found;
}

static id SPReadProvider(id obj, const char *name) {
    id v = SPReadIvar(obj, name);
    if (!v || [v isKindOfClass:NSNull.class]) return nil;
    return v;
}

static NSString *SPBundleIDForIconView(id iconView) {
    @try {
        id icon = SPMsg0(iconView, @"icon");
        if (!icon) return nil;
        for (NSString *k in @[@"applicationBundleID", @"bundleIdentifier"]) {
            id v = SPMsg0(icon, k);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        }
        id app = SPMsg0(icon, @"application");
        if (app) {
            id bid = SPMsg0(app, @"bundleIdentifier");
            if ([bid isKindOfClass:[NSString class]] && [(NSString *)bid length]) return bid;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static id SPHookedCtxMenu(id self, SEL _cmd, id interaction, CGPoint location) {
    @try {
        // 这一行出现 = 长按确实走到了我们的 hook
        SPLog(@"icon menu: 长按触发");
        id original = gOrigCtxMenu ? gOrigCtxMenu(self, _cmd, interaction, location) : nil;
        SPDumpCtxMenuIvarsOnce();
        if ([original isKindOfClass:[UIContextMenuConfiguration class]]) {
            unsigned n = 0;
            Ivar *ivs = class_copyIvarList(object_getClass(original), &n);
            NSMutableString *m = [NSMutableString stringWithString:@"ctxmenu vals:"];
            for (unsigned i = 0; i < n; i++) {
                id v = nil;
                @try { v = object_getIvar(original, ivs[i]); } @catch (__unused NSException *e) {}
                [m appendFormat:@" %s=%@", ivar_getName(ivs[i]),
                    v ? NSStringFromClass([v class]) : @"nil"];
            }
            free(ivs);
            SPLog(@"%@", m);
        } else {
            SPLog(@"ctxmenu: original 不是 configuration");
        }
        if (![original isKindOfClass:[UIContextMenuConfiguration class]]) {
            SPLog(@"icon menu: original 不是 configuration");
            return original;
        }

        NSString *bid = SPBundleIDForIconView(self);
        SPLog(@"icon menu: bundleID=%@", bid ?: @"nil");
        if (!bid.length) return original;

        UIContextMenuConfiguration *cfg = (UIContextMenuConfiguration *)original;
        id oldProvider = SPFindMenuProvider(cfg);
        if (!oldProvider) oldProvider = SPReadProvider(cfg, "_menuProvider");
        if (!oldProvider) oldProvider = SPReadProvider(cfg, "_configurationProvider");
        id oldPreview = SPReadProvider(cfg, "_previewProvider");
        id identifier = SPReadProvider(cfg, "_identifier");
        if (!oldProvider) {
            // 拿不到原始 provider 就不能构造新 configuration（会丢掉系统菜单）
            SPLog(@"icon menu: 取不到 menuProvider，放弃注入");
            return original;
        }
        SPLog(@"icon menu: provider ok bid=%@ preview=%@", bid, oldPreview ? @"Y" : @"n");

        UIMenu *(^newProvider)(NSArray<UIMenuElement *> *) = ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
            UIMenu *base = nil;
            @try {
                UIMenu *(^p)(NSArray<UIMenuElement *> *) = (id)oldProvider;
                base = p(suggested);
            } @catch (NSException *e) { SPLog(@"menu provider ex %@", e.reason); }

            NSString *target = [bid copy];
            UIAction *split = [UIAction actionWithTitle:@"上下分屏"
                                                 image:[UIImage systemImageNamed:@"rectangle.split.1x2"]
                                            identifier:@"com.seagull.splitpane.entry"
                                               handler:^(__kindof UIAction *a) {
                SPLog(@"icon menu -> split %@", target);
                [[SPGesture shared] startSplitFromIconForBundleID:target];
            }];

            NSMutableArray *children = [NSMutableArray arrayWithObject:split];
            if ([base isKindOfClass:[UIMenu class]]) [children addObjectsFromArray:base.children];
            return [UIMenu menuWithTitle:@"" children:children];
        };

        UIContextMenuConfiguration *modified =
            [UIContextMenuConfiguration configurationWithIdentifier:identifier
                                                   previewProvider:oldPreview
                                                    actionProvider:newProvider];
        return modified ?: original;
    } @catch (NSException *e) {
        SPLog(@"icon menu: hook 异常 %@", e.reason);
        return gOrigCtxMenu ? gOrigCtxMenu(self, _cmd, interaction, location) : nil;
    }
}

// 不能直接引 MSHookMessageEx 符号（链接期会 undefined），必须 dlsym 取。
typedef void (*SPHookMsgExFn)(Class, SEL, IMP, IMP *);

void SPInstallIconMenuHook(void) {
    Class cls = NSClassFromString(@"SBIconView");
    NSString *selName = @"contextMenuInteraction:configurationForMenuAtLocation:";
    SPLog(@"icon menu: 开始安装, SBIconView=%@", cls ? @"Y" : @"n");
    if (!cls) { SPLog(@"icon menu: SBIconView 不存在"); return; }
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) {
        SPLog(@"icon menu: %@ 不存在", selName);
        return;
    }
    SPHookMsgExFn hook = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) { SPLog(@"icon menu: MSHookMessageEx 不可用"); return; }
    hook(cls, sel, (IMP)SPHookedCtxMenu, (IMP *)&gOrigCtxMenu);
    SPLog(@"icon menu hooked: SBIconView (orig=%p)", gOrigCtxMenu);
    // 自检：hook 后 original 必须非空，否则等于没装上
    if (!gOrigCtxMenu) SPLog(@"icon menu: ⚠️ original 为空，hook 可能未生效");
}
