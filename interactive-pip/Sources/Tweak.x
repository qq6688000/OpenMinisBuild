#import <UIKit/UIKit.h>
#import <objc/runtime.h>
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
    DPPresentationMode mode = DPPresentationModeFloating;
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:mode];
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
    // 直接走询问模式，界面更统一，也避免 SpringBoard present 失败
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:DPPresentationModeFloating];
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

    // 上滑
    if ([[DPSettings shared] isGestureEnabled:DPActivationGestureIconSwipeUp]) {
        if (!objc_getAssociatedObject(iconView, &kDPIconSwipeKey)) {
            DPIconGestureTarget *target = [[DPIconGestureTarget alloc] init];
            target.iconView = iconView;
            UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:target action:@selector(handleSwipe:)];
            swipe.direction = UISwipeGestureRecognizerDirectionUp;
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
    return [type isEqualToString:@"com.dualpane.action.split"]
        || [type isEqualToString:@"com.dualpane.action.float"];
}

static BOOL DPHandleShortcutType(NSString *type, NSString *bundleID, id iconView) {
    if (!DPIsOurShortcutType(type)) return NO;

    DPPresentationMode mode = DPPresentationModeFloating;

    NSString *bid = bundleID;
    if (!bid.length) bid = DPBundleIDFromIconView(iconView);
    if (!bid.length) return YES; // 吞掉，避免系统再处理坏项
    DPHaptic();
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:mode];
    return YES;
}

static NSArray *DPInjectedShortcutItems(void) {
    id floatItem = DPMakeShortcutItem(@"com.dualpane.action.float",
                                      @"悬浮窗打开",
                                      @"小窗叠在桌面上",
                                      @"rectangle.on.rectangle");
    NSMutableArray *out = [NSMutableArray array];
    if (floatItem) [out addObject:floatItem];
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
        NSLog(@"[DualPane] install complete, keyWindow=%@", keyWindow);
    });
}

- (void)frontDisplayDidChange:(id)arg {
    %orig;
    // 仅在我们处于悬浮/分屏模式时做补救，避免误伤
    if ([DPWindowManager shared].mode == DPPresentationModeNone) return;

    NSString *bid = DPBundleIDFromObject(arg);
    if ([[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        NSLog(@"[DualPane] frontDisplay 补救回桌面: %@", bid);
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

    BOOL shouldSuppress = [[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid];
    BOOL ok = %orig;
    if (shouldSuppress && bid.length) {
        NSLog(@"[DualPane] transition 后补救回桌面: %@", bid);
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

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        Class overlayClass = NSClassFromString(@"DPPassthroughWindow");
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan
                && overlayClass
                && [touch.window isKindOfClass:overlayClass]) {
                [[DPWindowManager shared] prepareForHostedInput];
                break;
            }
        }
    }
    %orig;
}

%end

// Hosted controls live inside the SpringBoard-owned overlay window. Make that
// window key before UIKit asks the responder chain to present the keyboard.
%hook UIResponder

- (BOOL)becomeFirstResponder {
    Class overlayClass = NSClassFromString(@"DPPassthroughWindow");
    UIWindow *window = [self isKindOfClass:[UIView class]] ? ((UIView *)self).window : nil;
    BOOL isHosted = overlayClass && [window isKindOfClass:overlayClass];
    if (isHosted) {
        [[DPWindowManager shared] prepareForHostedInput];
    }
    return %orig;
}

%end

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

%ctor {
    @autoreleasepool {
        [DPSettings shared];
        NSLog(@"[DualPane] 已加载 — 启用=%d", [DPSettings shared].isEnabled);
    }
}
