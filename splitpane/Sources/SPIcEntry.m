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
static void SPDumpCtxMenuIvarsOnce(void) {
    static BOOL done = NO;
    if (done) return; done = YES;
    unsigned n = 0;
    Ivar *ivs = class_copyIvarList(NSClassFromString(@"UIContextMenuConfiguration"), &n);
    NSMutableString *msg = [NSMutableString stringWithFormat:@"ctxmenu ivars=%u:", n];
    for (unsigned i = 0; i < n; i++)
        [msg appendFormat:@" %s", ivar_getName(ivs[i])];
    free(ivs);
    SPLog(@"%@", msg);
}

// ===== 安全读 ivar =====
// 崩溃教训（SpringBoard-2026-11-25-062119）：object_getIvar 对 weak ivar 会返回
// 未持有/已释放的地址，随后任何 isKindOfClass 都会 objc_retain → 野指针 SIGSEGV。
// 所以：跳过 weak ivar，其余只按类型名比对，不 retain。

// 不 retain 地拿类名：只读 isa，做可读性/自洽校验，全程不 retain。
static const char *SPClassSafe(const void *p) {
    if (!p) return NULL;
    uintptr_t a = (uintptr_t)p;
    if ((a & 0x7) || a < 0x100000000ULL) return NULL;   // 未对齐或明显非法
    uintptr_t isaRaw = 0;
    memcpy(&isaRaw, p, sizeof(isaRaw));
    if (!isaRaw || (isaRaw & 0x7) || isaRaw < 0x100000000ULL) return NULL;
    const char *name = NULL;
    @try { name = class_getName((__bridge Class)(void *)isaRaw); } @catch (...) { return NULL; }
    if (!name || !*name) return NULL;
    for (const char *q = name; *q; q++)
        if (*q < 0x20 || *q > 0x7e) return NULL;
    return name;
}

static id SPFindMenuProvider(id cfg) {
    unsigned n = 0;
    Ivar *ivs = class_copyIvarList(object_getClass(cfg), &n);
    id found = nil;
    for (unsigned i = 0; i < n; i++) {
        const char *iname = ivar_getName(ivs[i]);
        if (!iname) continue;
        void *raw = NULL;
        @try {
            // 不要用 object_getIvar：它内部会对 weak 做一次 retain/autorelease
            ptrdiff_t off = ivar_getOffset(ivs[i]);
            if (off < 0) continue;
            memcpy(&raw, (const char *)(__bridge const void *)cfg + off, sizeof(raw));
        } @catch (...) { continue; }
        if (!raw) { SPLog(@"ctxmenu ivar %s = nil", iname); continue; }
        const char *cn = SPClassSafe(raw);
        if (!cn) { SPLog(@"ctxmenu ivar %s = <不可解析 %p>", iname, raw); continue; }
        SPLog(@"ctxmenu ivar %s = %s", iname, cn);
        if (!strstr(cn, "Block")) continue;
        if (strcasestr(iname, "preview")) continue;
        // 用 block 的 invoke 指针签名做判据（不 retain，直接读 block 布局）
        // struct Block_layout { void *isa; int flags; int reserved; void *invoke; ... }
        void *invoke = NULL;
        memcpy(&invoke, (const char *)raw + 24, sizeof(invoke));
        SPLog(@"ctxmenu block %s invoke=%p", iname, invoke);
        if (!invoke) continue;
        if (!found) found = (__bridge id)raw;
    }
    free(ivs);
    return found;
}

// 安全按名读 ivar：按 offset memcpy，不 retain、不碰 weak。
static id SPReadIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    void *raw = NULL;
    ptrdiff_t off = ivar_getOffset(iv);
    if (off <= 0) return nil;
    @try { memcpy(&raw, (const char *)(__bridge const void *)obj + off, sizeof(raw)); }
    @catch (...) { return nil; }
    if (!raw) return nil;
    if (!SPClassSafe(raw)) return nil;        // 野指针直接丢弃
    id v = (__bridge id)raw;
    if ([v isKindOfClass:NSNull.class]) return nil;
    return v;
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
