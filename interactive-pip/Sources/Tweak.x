#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import <objc/message.h>
#import "DPSettings.h"
#import "DPWindowManager.h"
#import "DPGestureController.h"

// ── 主屏幕图标工具 ─────────────────────────────────────────────────────────

static char kDPIconSwipeKey;
static char kDPIconLongPressKey;

static NSString *DPBundleIDFromIcon(id icon) {
    if (!icon) return nil;
    NSArray *keys = @[@"applicationBundleID", @"bundleIdentifier", @"applicationBundleIdentifier"];
    for (NSString *key in keys) {
        @try {
            id val = [icon valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val length]) return val;
        } @catch (__unused NSException *e) {}
    }
    if ([icon respondsToSelector:@selector(applicationBundleID)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id val = [icon performSelector:@selector(applicationBundleID)];
#pragma clang diagnostic pop
        if ([val isKindOfClass:[NSString class]] && [val length]) return val;
    }
    @try {
        if ([[icon valueForKey:@"isFolderIcon"] boolValue]) return nil;
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *DPBundleIDFromIconView(id iconView) {
    if (!iconView) return nil;
    id icon = nil;
    @try { icon = [iconView valueForKey:@"icon"]; } @catch (__unused NSException *e) {}
    return DPBundleIDFromIcon(icon);
}

static NSString *DPBundleIDFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    NSArray *keys = @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier",
                      @"_bundleIdentifier", @"applicationIdentifier"];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val length]) return val;
        } @catch (__unused NSException *e) {}
    }
    @try {
        id app = [obj valueForKey:@"application"];
        if (app && app != obj) return DPBundleIDFromObject(app);
    } @catch (__unused NSException *e) {}
    @try {
        id app = [obj valueForKey:@"sbApplication"];
        if (app) return DPBundleIDFromObject(app);
    } @catch (__unused NSException *e) {}
    // applicationSceneEntity / entities
    @try {
        id entity = [obj valueForKey:@"applicationSceneEntity"];
        if (entity) {
            NSString *b = DPBundleIDFromObject(entity);
            if (b.length) return b;
            id app = [entity valueForKey:@"application"];
            b = DPBundleIDFromObject(app);
            if (b.length) return b;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static void DPHaptic(void) {
    if (![DPSettings shared].hapticFeedback) return;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g impactOccurred];
}

static BOOL DPSceneIsHosted(id scene) {
    if (!scene) return NO;
    NSString *identifier = nil;
    for (NSString *key in @[@"identifier", @"_identifier", @"sceneIdentifier"]) {
        @try {
            id value = [scene valueForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                identifier = value;
                break;
            }
        } @catch (__unused NSException *e) {}
    }
    if (!identifier.length) return NO;

    for (NSString *bundleID in [DPWindowManager shared].hostedBundleIDs) {
        if ([identifier containsString:bundleID]) return YES;
    }
    return NO;
}

static id DPSettingsByKeepingSceneForeground(id scene, id settings) {
    if (!settings || !DPSceneIsHosted(scene)) return settings;
    @try {
        id mutableSettings = [settings respondsToSelector:@selector(mutableCopy)]
            ? [settings mutableCopy] : settings;
        SEL setForeground = NSSelectorFromString(@"setForeground:");
        if ([mutableSettings respondsToSelector:setForeground]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(mutableSettings, setForeground, YES);
        }
        SEL setBackgrounded = NSSelectorFromString(@"setBackgrounded:");
        if ([mutableSettings respondsToSelector:setBackgrounded]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(mutableSettings, setBackgrounded, NO);
        }
        SEL setReasons = NSSelectorFromString(@"setDeactivationReasons:");
        if ([mutableSettings respondsToSelector:setReasons]) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(mutableSettings, setReasons, 0);
        }
        return mutableSettings;
    } @catch (__unused NSException *e) {
        return settings;
    }
}

// ── 图标上滑 ───────────────────────────────────────────────────────────────

@interface DPIconGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *iconView;
- (void)handleSwipe:(UISwipeGestureRecognizer *)gr;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gr;
@end

@implementation DPIconGestureTarget

- (void)handleSwipe:(UISwipeGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateRecognized) return;
    if (![DPSettings shared].isEnabled) return;
    if (![[DPSettings shared] isGestureEnabled:DPActivationGestureIconSwipeUp]) return;
    NSString *bid = DPBundleIDFromIconView(self.iconView);
    if (!bid.length) return;
    DPHaptic();
    // 0.7.178: PV式全屏分屏
    [[DPWindowManager shared] startPVFullscreenSplitForBundleID:bid];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    if (![DPSettings shared].isEnabled) return;
    // 仅当系统快捷菜单注入失败时作为兜底；默认不抢系统长按
    // 这里用「长按 + 轻微上移」会更合适，但为可靠起见：若用户关闭了系统菜单开关则启用
    if ([[DPSettings shared] isGestureEnabled:DPActivationGestureIconLongPress]) {
        // 系统菜单优先；此手势 minimumPressDuration 较长，作兜底
    }
    NSString *bid = DPBundleIDFromIconView(self.iconView);
    if (!bid.length) return;

    // 系统快捷菜单可能失效：用我们自己的选择面板（走 WindowManager 的 mode chooser）
    DPHaptic();
    // 0.7.178: PV式全屏分屏
    [[DPWindowManager shared] startPVFullscreenSplitForBundleID:bid];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gestureRecognizer;
    (void)other;
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gestureRecognizer;
    (void)other;
    return NO;
}

@end

static void DPAttachIconGestures(UIView *iconView) {
    if (!iconView) return;
    if (![DPSettings shared].isEnabled) return;

    // 下滑 (0.7.149: was swipe-up, switched to swipe-down)
    if ([[DPSettings shared] isGestureEnabled:DPActivationGestureIconSwipeUp]) {
        if (!objc_getAssociatedObject(iconView, &kDPIconSwipeKey)) {
            DPIconGestureTarget *target = [[DPIconGestureTarget alloc] init];
            target.iconView = iconView;
            UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:target action:@selector(handleSwipe:)];
            swipe.direction = UISwipeGestureRecognizerDirectionDown;
            swipe.numberOfTouchesRequired = 1;
            swipe.cancelsTouchesInView = YES;
            swipe.delaysTouchesBegan = NO;
            [iconView addGestureRecognizer:swipe];
            objc_setAssociatedObject(iconView, &kDPIconSwipeKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    // 长按兜底：仅当系统快捷菜单类不存在时才挂，避免和系统 Haptic Touch 叠在一起
    if ([[DPSettings shared] isGestureEnabled:DPActivationGestureIconLongPress]) {
        if (!objc_getAssociatedObject(iconView, &kDPIconLongPressKey)) {
            DPIconGestureTarget *target = [[DPIconGestureTarget alloc] init];
            target.iconView = iconView;
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(handleLongPress:)];
            lp.minimumPressDuration = 0.42;
            lp.delegate = target;
            lp.cancelsTouchesInView = YES;
            lp.allowableMovement = 12;
            [iconView addGestureRecognizer:lp];

            for (UIGestureRecognizer *other in iconView.gestureRecognizers) {
                if (other == lp) continue;
                NSString *className = NSStringFromClass(other.class);
                if ([className localizedCaseInsensitiveContainsString:@"long"]
                    || [className localizedCaseInsensitiveContainsString:@"context"]
                    || [className localizedCaseInsensitiveContainsString:@"shortcut"]
                    || [className localizedCaseInsensitiveContainsString:@"haptic"]) {
                    [other requireGestureRecognizerToFail:lp];
                }
            }
            objc_setAssociatedObject(iconView, &kDPIconLongPressKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

// ── 快捷菜单项构造 ─────────────────────────────────────────────────────────

static id DPMakeSystemIcon(NSString *systemImageName) {
    if (!systemImageName.length) return nil;
    Class IconClass = NSClassFromString(@"SBSApplicationShortcutSystemIcon");
    if (!IconClass) return nil;

    // iOS 13+: iconWithSystemImageName:
    SEL sel1 = NSSelectorFromString(@"iconWithSystemImageName:");
    if ([IconClass respondsToSelector:sel1]) {
        return ((id (*)(id, SEL, id))objc_msgSend)(IconClass, sel1, systemImageName);
    }
    // initWithSystemImageName:
    if ([IconClass instancesRespondToSelector:NSSelectorFromString(@"initWithSystemImageName:")]) {
        id obj = [IconClass alloc];
        return ((id (*)(id, SEL, id))objc_msgSend)(obj, NSSelectorFromString(@"initWithSystemImageName:"), systemImageName);
    }
    // 旧 API: type 枚举
    SEL sel2 = NSSelectorFromString(@"initWithType:");
    if ([IconClass instancesRespondToSelector:sel2]) {
        id obj = [IconClass alloc];
        NSUInteger type = 0;
        return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(obj, sel2, type);
    }
    return nil;
}

static id DPMakeShortcutItem(NSString *type, NSString *title, NSString *subtitle, NSString *systemImage) {
    Class ItemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!ItemClass) return nil;
    id item = [[ItemClass alloc] init];
    if (!item) return nil;

    // type
    if ([item respondsToSelector:@selector(setType:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setType:), type);
    } else {
        @try { [item setValue:type forKey:@"type"]; } @catch (__unused NSException *e) {}
    }

    // localizedTitle
    if ([item respondsToSelector:@selector(setLocalizedTitle:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setLocalizedTitle:), title);
    } else {
        @try { [item setValue:title forKey:@"localizedTitle"]; } @catch (__unused NSException *e) {}
    }

    // localizedSubtitle
    if (subtitle.length) {
        if ([item respondsToSelector:@selector(setLocalizedSubtitle:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setLocalizedSubtitle:), subtitle);
        } else {
            @try { [item setValue:subtitle forKey:@"localizedSubtitle"]; } @catch (__unused NSException *e) {}
        }
    }

    // bundleIdentifierToLaunch 留空 —— 我们自己处理，不让系统启动

    id iconObj = DPMakeSystemIcon(systemImage);
    if (iconObj) {
        if ([item respondsToSelector:@selector(setIcon:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setIcon:), iconObj);
        } else {
            @try { [item setValue:iconObj forKey:@"icon"]; } @catch (__unused NSException *e) {}
        }
    }

    // userInfo 标记
    NSDictionary *info = @{ @"dualpane": @YES };
    if ([item respondsToSelector:@selector(setUserInfo:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(item, @selector(setUserInfo:), info);
    } else {
        @try { [item setValue:info forKey:@"userInfo"]; } @catch (__unused NSException *e) {}
    }

    return item;
}

static BOOL DPIsOurShortcutType(NSString *type) {
    if (![type isKindOfClass:[NSString class]]) return NO;
    return [type isEqualToString:@"com.seagull.interactivepip.action.split"]
        || [type isEqualToString:@"com.seagull.interactivepip.action.float"];
}

static BOOL DPHandleShortcutType(NSString *type, NSString *bundleID, id iconView) {
    if (!DPIsOurShortcutType(type)) return NO;

    DPPresentationMode mode = [type hasSuffix:@".split"] ? DPPresentationModeSplit : DPPresentationModeFloating;

    NSString *bid = bundleID;
    if (!bid.length) bid = DPBundleIDFromIconView(iconView);
    if (!bid.length) return YES; // 吞掉，避免系统再处理坏项
    DPHaptic();
    // 0.7.178: PV式全屏分屏 —— App全屏启动，上滑到顶固定为第一半再选第二个。
    [[DPWindowManager shared] startPVFullscreenSplitForBundleID:bid];
    return YES;
}

static NSArray *DPInjectedShortcutItems(void) {
    // 0.7.174: 窗口模式已删除 —— 只保留「Duo 分屏」一项。
    // 之前的「悬浮窗打开 / 小窗叠在桌面上」已移除。
    NSMutableArray *out = [NSMutableArray array];
    id splitItem = DPMakeShortcutItem(@"com.seagull.interactivepip.action.split", @"Duo 分屏", @"双应用各占半屏", @"rectangle.split.2x1");
    if (splitItem) [out addObject:splitItem];
    return out;
}

// Preserve activation only for scenes currently owned by DualPane.
%hook FBScene

- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(id)completion {
    id effectiveSettings = DPSettingsByKeepingSceneForeground(self, settings);
    %orig(effectiveSettings, context, completion);
}

- (void)updateSettings:(id)settings withTransitionContext:(id)context {
    id effectiveSettings = DPSettingsByKeepingSceneForeground(self, settings);
    %orig(effectiveSettings, context);
}

%end

// ── SpringBoard 启动：装独立顶层窗 ─────────────────────────────────────────

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![DPSettings shared].isEnabled) return;
        [[DPWindowManager shared] install];
        UIWindow *keyWindow = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        if (!keyWindow) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
        if (keyWindow) {
            [[DPGestureController shared] installOnView:keyWindow];
        }
        NSLog(@"[InteractivePiP] install complete, keyWindow=%@", keyWindow);
    });
}

- (void)frontDisplayDidChange:(id)arg {
    %orig;
    // 仅在我们处于悬浮/分屏模式时做补救，避免误伤
    if ([DPWindowManager shared].mode == DPPresentationModeNone) return;

    NSString *bid = DPBundleIDFromObject(arg);
    [[DPWindowManager shared] noteForegroundApplicationChanged:bid];
    if ([[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        NSLog(@"[InteractivePiP] frontDisplay 补救回桌面: %@", bid);
        [[DPWindowManager shared] handlePotentialFullscreenActivationForBundleID:bid];
    } else {
        [[DPWindowManager shared] bringOverlayToFront];
    }
}

%end

// ── 拦截：托管中的 App 禁止切到全屏前台 ───────────────────────────────────
// 注意：不要轻易 return NO，错误拦截会导致 SpringBoard 卡顿/死锁。
// 策略：允许 transition 完成，再异步 goHome 补救。

%hook SBMainWorkspace

- (BOOL)executeTransitionRequest:(id)request {
    NSString *bid = DPBundleIDFromObject(request);
    if (!bid.length) {
        @try {
            id app = [request valueForKey:@"application"];
            bid = DPBundleIDFromObject(app);
        } @catch (__unused NSException *e) {}
        @try {
            id dest = [request valueForKey:@"destinationApplication"];
            if (!bid.length) bid = DPBundleIDFromObject(dest);
        } @catch (__unused NSException *e) {}
        @try {
            id info = [request valueForKey:@"applicationSceneEntity"];
            if (!bid.length) bid = DPBundleIDFromObject(info);
        } @catch (__unused NSException *e) {}
    }

    // 0.7.199: 每次转场都抓系统自建的真实 displayItem 进缓存表（上滑待命/第二个 App 组分屏都靠它）
    [[DPWindowManager shared] cacheRealDisplayItemFromRequest:request bundleID:bid];
    // 0.7.204: 一次性递归 dump request 对象树，定位真实 displayItem 藏在哪个字段
    [[DPWindowManager shared] dumpTransitionRequest:request];

    // 0.7.198: 分屏待命中，用户手动打开的第二个 App —— 先放行 %orig 让系统正常
    // 启动它（建好真实 scene + displayItem），延迟后再组 itemA(缓存) + itemB(真实) 分屏。
    if (bid.length && [[DPWindowManager shared] isPVFullscreenSplitPending]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DPWindowManager shared] tryActivatePendingSplitForLaunchedBundleID:bid request:request];
        });
    }

    BOOL shouldSuppress = [[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid];
    BOOL ok = %orig;
    if (shouldSuppress && bid.length) {
        NSLog(@"[InteractivePiP] transition 后补救回桌面: %@", bid);
        [[DPWindowManager shared] handlePotentialFullscreenActivationForBundleID:bid];
    }
    return ok;
}

- (void)noteInterfaceOrientationChanged:(long long)orientation duration:(double)duration {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DPWindowManager shared] handleOrientationChange];
    });
}

%end



// Remote app responders do not live in SpringBoard. Route only actual host touches.


// 不再 hook SBWorkspaceTransaction.begin 硬 return —— 那是卡顿主因之一

// ── 图标：上滑 + 长按菜单 ─────────────────────────────────────────────────

%hook SBIconView

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (view.window) {
        DPAttachIconGestures(view);
    }
}

- (void)setIcon:(id)icon {
    %orig;
    DPAttachIconGestures((UIView *)self);
}

- (id)applicationShortcutItems {
    NSArray *items = %orig;
    if (![DPSettings shared].isEnabled) return items;
    if (![[DPSettings shared] isGestureEnabled:DPActivationGestureIconLongPress]) return items;

    NSString *bid = DPBundleIDFromIconView((id)self);
    if (!bid.length) return items;

    NSArray *ours = DPInjectedShortcutItems();
    if (ours.count == 0) return items;

    NSMutableArray *out = items ? [items mutableCopy] : [NSMutableArray array];
    // 去重：避免重复注入
    NSMutableIndexSet *remove = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < out.count; i++) {
        id it = out[i];
        NSString *t = nil;
        @try { t = [it valueForKey:@"type"]; } @catch (__unused NSException *e) {}
        if (DPIsOurShortcutType(t)) [remove addIndex:i];
    }
    [out removeObjectsAtIndexes:remove];

    // 插到最前
    for (NSInteger i = (NSInteger)ours.count - 1; i >= 0; i--) {
        [out insertObject:ours[(NSUInteger)i] atIndex:0];
    }
    return out;
}

// iOS 13+ 部分路径
- (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView ?: (id)self)) {
        return; // 绝不 %orig，防止系统再全屏打开
    }
    %orig;
}

%end

%hook SBHIconView

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (view.window) DPAttachIconGestures(view);
}

- (void)setIcon:(id)icon {
    %orig;
    DPAttachIconGestures((UIView *)self);
}

%end

%hook SBIconController

- (void)appIconView:(id)iconView activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) {
        return;
    }
    %orig;
}

- (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) return;
    %orig;
}

%end

%hook SBHIconManager

- (void)iconView:(id)iconView activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) {
        return;
    }
    %orig;
}

- (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) return;
    %orig;
}

%end

%hook SBUIController
- (void)handleHomeButtonSinglePressUp {
    [[DPWindowManager shared] handleUserHome];
    %orig;
}
- (void)clickedMenuButton {
    [[DPWindowManager shared] handleUserHome];
    %orig;
}
%end

// ── PV式：全屏 App 内直接上滑到顶 → 该 App 变上半屏 + 选第二个（0.7.181）──
// 不需要长按图标、不需要菜单：任意 App 全屏时从底部上滑并按住到顶部，松手即保留。
// 与系统"上滑回桌面"区分：我们只在松手时窗口/手势到达顶部区才接管，否则放行原逻辑。
%hook SBFluidSwitcherGestureManager
- (void)_handleSwitcherPanGestureBegan:(id)gesture {
    %orig;
    [[DPWindowManager shared] handlePVFullscreenSplitPanBegan:gesture];
}
- (void)_handleSwitcherPanGestureChanged:(id)gesture {
    %orig;
    [[DPWindowManager shared] handlePVFullscreenSplitPanChanged:gesture];
}
- (void)_handleSwitcherPanGestureEnded:(id)gesture {
    BOOL tookOver = [[DPWindowManager shared] handlePVFullscreenSplitPanEnded:gesture];
    // 0.7.183: 绝不能跳过 %orig。系统在 ended 时已经开始"App缩成卡片"的过渡，
    // 跳过会把这个动画冻在半路（就是"卡住不动"的原因）。
    // 正确做法：正常放行，让系统完成缩小/回桌面，我们再在桌面之上拉起分屏。
    %orig;
    if (!tookOver && [DPWindowManager shared].mode != DPPresentationModeNone) {
        [[DPWindowManager shared] handleHomeGestureEnded];
    }
}
%end

%hook SBLockScreenManager
- (void)lockUIFromSource:(int)source withOptions:(id)options {
    [[DPWindowManager shared] handleDeviceLock];
    %orig;
}
- (void)unlockUIFromSource:(int)source withOptions:(id)options {
    %orig;
    [[DPWindowManager shared] handleDeviceUnlock];
}
%end

// ── Switcher 数据源：让分屏作为一张卡出现在 App Switcher ─────────────────
// 逆向自 PanoramicView：hook SBMainSwitcherControllerCoordinator 的
// appLayoutsForSwitcherContentController:，先取系统已有 layouts，
// 若处于分屏态则把我们的组合 layout 追加进去（不在数组中时）。
%hook SBMainSwitcherControllerCoordinator
- (id)appLayoutsForSwitcherContentController:(id)controller {
    id layouts = %orig;
    NSArray *arr = [layouts isKindOfClass:[NSArray class]] ? layouts : nil;
    DPWindowManager *wm = [DPWindowManager shared];
    wm.switcherSourceCalls++;
    // 0.7.210: 照 PV —— 系统把每个运行中 App 的【真实 displayItem】送进本钩子
    // （作为某个 SBAppLayout 的 item）。不手拼、不主动取，就在这里接住缓存。
    // 后台线程，避免 0.7.205 那种主路径深度反射崩 SpringBoard。
    if (arr.count > 0) {
        NSArray *snapshot = [arr copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [wm harvestRealDisplayItemsFromSwitcherLayouts:snapshot];
        });
    }
    [wm observeSwitcherContentController:controller];
    if (arr) {
        id ourLayout = [wm currentSwitcherLayout];
        if (ourLayout && ![arr containsObject:ourLayout]) {
            NSMutableArray *m = [arr mutableCopy];
            [m insertObject:ourLayout atIndex:0];
            layouts = m;
            wm.switcherAppendCalls++;
        }
        // 0.7.206: dump 默认关闭（在切换器同步主路径做深度反射会崩 SpringBoard 进安全模式）。
        // 只在用户手动打开开关 sg.split.dumpLayouts 后，下一帧异步在后台线程跑一次。
        static BOOL dumped = NO;
        BOOL wantDump = [[NSUserDefaults standardUserDefaults] boolForKey:@"sg.split.dumpLayouts"];
        if (!dumped && wantDump && arr.count > 0) {
            dumped = YES;
            NSArray *snapshot = [arr copy];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try {
                    [wm dumpRealAppLayouts:snapshot];
                } @catch (NSException *e) {
                    NSLog(@"[InteractivePiP] dumpRealAppLayouts ex %@", e);
                }
            });
        }
    }
    return layouts;
}
- (void)switcherContentController:(id)controller bringAppLayoutToFront:(id)layout {
    DPWindowManager *wm = [DPWindowManager shared];
    [wm noteSwitcherActivationCandidate:layout source:@"coordinator-bring"];
    if ([wm isSwitcherCard:layout]) {
        [wm activateSwitcherCard:layout];
        return; // 拦截：不走系统整屏激活，恢复我们的分屏
    }
    %orig;
}
- (BOOL)switcherContentController:(id)controller supportsKillingOfAppLayout:(id)layout {
    if ([[DPWindowManager shared] isSwitcherCard:layout]) return NO;
    return %orig;
}
- (BOOL)switcherContentController:(id)controller supportsTitleItemsForAppLayout:(id)layout {
    if ([[DPWindowManager shared] isSwitcherCard:layout]) return YES;
    return %orig;
}
%end

// 给我们的分屏卡提供类型安全的 page content view（DPGroupPageView，消息转发兜底）
%hook SBFluidSwitcherPageContentViewProvider
- (id)pageContentViewForAppLayout:(id)appLayout setActive:(BOOL)active {
    if ([[DPWindowManager shared] isSwitcherCard:appLayout]) {
        @try {
            DPWindowManager *wm = [DPWindowManager shared];
            wm.switcherPageCalls++;
            UIView *pv = [wm makeSwitcherPageView:appLayout];
            if (pv) {
                NSLog(@"[InteractivePiP] pageContentViewForAppLayout: 返回 DPGroupPageView");
                return pv;
            }
        } @catch (__unused NSException *e) {
            NSLog(@"[InteractivePiP] pageContentViewForAppLayout: 构造失败 -> %orig");
        }
    }
    return %orig;
}
%end

// ── 快照缓存：让系统把我们的分屏 layout 当“可缓存 layout”，为其生成切换器快照 ──
// 逆向自 PanoramicView 1.0.9（SBAppSwitcherSnapshotImageCache setCachableAppLayouts:
// hook，反汇编 0x75ec0 分支 + restore 流程 0x158cc 的配套缓存路径）。
// 数据源(appLayoutsForSwitcherContentController:)里有 layout 不够 —— 系统快照
// 缓存不认它就不会渲染卡片。只追加不删除，非分屏态完全不干预。
%hook SBAppSwitcherSnapshotImageCache
- (void)setCachableAppLayouts:(NSArray<id> *)layouts {
    NSArray *in = layouts;
    [DPWindowManager shared].switcherCacheCalls++;
    @try {
        id ourLayout = [[DPWindowManager shared] currentSwitcherLayout];
        if (ourLayout && [in isKindOfClass:[NSArray class]] && ![in containsObject:ourLayout]) {
            NSMutableArray *m = [in mutableCopy];
            [m addObject:ourLayout];
            in = m;
            NSLog(@"[InteractivePiP] cachableAppLayouts appended ours total=%lu",
                  (unsigned long)m.count);
        }
    } @catch (__unused NSException *e) {
        NSLog(@"[InteractivePiP] cachableAppLayouts hook exception -> passthrough");
    }
    %orig(in);
}
%end



// App 进程（QQ 等被托管 App）键盘窗口托管辅助

// Observe the actual switcher transition in addition to the explicit tap callback.
// Never rewrite a system request or claim a non-Duo layout.
static id DPTransitionObject(id object, SEL getter) {
    if (![object respondsToSelector:getter]) return nil;
    NSMethodSignature *sig = [object methodSignatureForSelector:getter];
    if (sig.numberOfArguments != 2 || sig.methodReturnType[0] != '@') return nil;
    return ((id(*)(id, SEL))objc_msgSend)(object, getter);
}

static char DPGroupRequestKey;

%group DPGroupRequestBinding
%hook SBSwitcherTransitionRequest
- (void)setActivatingDisplayItem:(id)item {
    if ([NSThread isMainThread]) {
        DPWindowManager *wm = [DPWindowManager shared];
        id card = [wm isSwitcherGroupDisplayItem:item] ? [wm currentSwitcherLayout] : nil;
        if (card || objc_getAssociatedObject(self, &DPGroupRequestKey)) {
            objc_setAssociatedObject(self, &DPGroupRequestKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    %orig;
}
%end
%end

static BOOL DPHasGroupRequestBinding(void) {
    Class cls = NSClassFromString(@"SBSwitcherTransitionRequest");
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:@selector(setActivatingDisplayItem:)];
    return sig.numberOfArguments == 3 && sig.methodReturnType[0] == 'v' && [sig getArgumentTypeAtIndex:2][0] == '@';
}

static id DPGroupTransitionTarget(id request, DPWindowManager *wm) {
    if (!request || ![wm currentSwitcherLayout]) return nil;
    @try {
        id bound = objc_getAssociatedObject(request, &DPGroupRequestKey);
        if (bound == [wm currentSwitcherLayout]) return bound;
        id ctx = DPTransitionObject(request, @selector(transitionContext));
        id item = DPTransitionObject(request, @selector(activatingDisplayItem));
        if ([wm isSwitcherGroupDisplayItem:item] || [wm isSwitcherGroupDisplayItem:DPTransitionObject(ctx, @selector(activatingDisplayItem))]) return [wm currentSwitcherLayout];
        id target = DPTransitionObject(request, @selector(toAppLayout));
        if ([wm isSwitcherCard:target]) return target;
        target = DPTransitionObject(ctx, @selector(toAppLayout));
        if ([wm isSwitcherCard:target]) return target;
    } @catch (__unused NSException *e) { }
    return nil;
}

%group DPGroupReturnTransition
%hook SBMainSwitcherControllerCoordinator
- (void)switcherContentController:(id)controller performTransitionWithRequest:(id)request gestureInitiated:(BOOL)gesture {
    DPWindowManager *wm = [DPWindowManager shared];
    if ([NSThread isMainThread]) {
        id target = DPGroupTransitionTarget(request, wm);
        if (target) [wm activateSwitcherCard:target];
        else [wm noteSwitcherActivationCandidate:request source:@"coordinator-unmatched"];
    }
    %orig;
}
%end
%end

// PV also installs the transition hook on the FluidSwitcher controller. On
// this iOS build the coordinator hook is not the callback receiving the tap.
%group DPFluidGroupReturnTransition
%hook SBFluidSwitcherViewController
- (void)switcherContentController:(id)controller performTransitionWithRequest:(id)request gestureInitiated:(BOOL)gesture {
    DPWindowManager *wm = [DPWindowManager shared];
    if ([NSThread isMainThread]) {
        id target = DPGroupTransitionTarget(request, wm);
        if (target) [wm activateSwitcherCard:target];
        else [wm noteSwitcherActivationCandidate:request source:@"fluid-unmatched"];
    }
    %orig;
}
- (void)switcherContentController:(id)controller bringAppLayoutToFront:(id)layout {
    DPWindowManager *wm = [DPWindowManager shared];
    [wm noteSwitcherActivationCandidate:layout source:@"fluid-bring"];
    if ([wm isSwitcherCard:layout]) {
        [wm activateSwitcherCard:layout];
        return;
    }
    %orig;
}
%end
%end

static BOOL DPHasGroupReturnTransitionForClass(NSString *className) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(@"switcherContentController:performTransitionWithRequest:gestureInitiated:");
    NSMethodSignature *sig = [cls instanceMethodSignatureForSelector:sel];
    return sig && sig.numberOfArguments == 5 && sig.methodReturnType[0] == 'v' &&
           [sig getArgumentTypeAtIndex:2][0] == '@' && [sig getArgumentTypeAtIndex:3][0] == '@' &&
           [sig getArgumentTypeAtIndex:4][0] == @encode(BOOL)[0];
}
static BOOL DPHasGroupReturnTransition(void) {
    return DPHasGroupReturnTransitionForClass(@"SBMainSwitcherControllerCoordinator");
}

%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
            // App 进程: 0.7.27 的 UIScreen bounds hook 只改了 screen 而 QQ 的
            // window 仍全屏, 结果内容居中+上下空白, 已回滚 — 这里不装任何 hook。
            NSLog(@"[InteractivePiP] 已加载到 App 进程 %@ — 无 hook", NSProcessInfo.processInfo.processName);
        } else {
        [DPSettings shared];
        if (DPHasGroupRequestBinding()) { %init(DPGroupRequestBinding); }
        if (DPHasGroupReturnTransition()) { %init(DPGroupReturnTransition); }
        if (DPHasGroupReturnTransitionForClass(@"SBFluidSwitcherViewController")) { %init(DPFluidGroupReturnTransition); }
        %init(_ungrouped);
        static int lockToken;
        notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) {
                if (state) [[DPWindowManager shared] handleDeviceLock];
                else [[DPWindowManager shared] handleDeviceUnlock];
            }
        });
        uint64_t initialState = 0;
        if (notify_get_state(lockToken, &initialState) == NOTIFY_STATUS_OK && initialState) [[DPWindowManager shared] handleDeviceLock];
        NSLog(@"[InteractivePiP] 已加载 — 启用=%d", [DPSettings shared].isEnabled);
        }
    }
}
