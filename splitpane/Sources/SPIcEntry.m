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
static id SPReadIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    @try { return object_getIvar(obj, iv); } @catch (__unused NSException *e) { return nil; }
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
        if (![original isKindOfClass:[UIContextMenuConfiguration class]]) {
            SPLog(@"icon menu: original 不是 configuration");
            return original;
        }

        NSString *bid = SPBundleIDForIconView(self);
        SPLog(@"icon menu: bundleID=%@", bid ?: @"nil");
        if (!bid.length) return original;

        UIContextMenuConfiguration *cfg = (UIContextMenuConfiguration *)original;
        id oldProvider = SPReadProvider(cfg, "_menuProvider");
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
