#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPWindowRegistry.h"

// ============================================================================
// 长按主屏图标 → 弹出 SplitPane 自己的小菜单（不改系统菜单）
//
// 血泪史：
//   0.4.22  valueForKey:@"menuProvider"      → NSValueForUndefinedKeyException
//   0.4.23  object_getIvar 遍历找 provider    → weak ivar 野指针 SIGSEGV
//   0.4.24  改 offset memcpy                 → 手机没装上，仍在跑 0.4.21
//
// 根本约束（已核实）：UIContextMenuConfiguration 的 actionProvider 是**只写不读**，
// 公开 API 只有 configurationWithIdentifier:previewProvider:actionProvider: 这个 creator，
// 没有任何 getter；私有 ivar 又是 weak/block 混存，读一次就可能炸。
//
// 结论：想"往系统菜单里插一项"必须拿到原 provider —— 拿不到。
// 所以 0.4.25 不再碰系统菜单：
//   长按图标 → 我们**原样返回系统 configuration**（菜单照常弹）
//            → 同时 record 图标 bundleID，并挂一个自己的浮动菜单（贴在长按位置）
//   用户在我们的小菜单里点「上下分屏」→ 进分屏
// 这样系统菜单 100% 不受影响，绝不会因为我们的代码让 SpringBoard 挂掉。
// ============================================================================

typedef id (*SPCtxMenuFn)(id, SEL, id, CGPoint);
static SPCtxMenuFn gOrigCtxMenu = NULL;

static NSString *SPStringOrNil(id v) {
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}

static NSString *SPBundleIDForIconView(id iconView) {
    @try {
        id icon = SPMsg0(iconView, @"icon");
        if (!icon) return nil;
        NSString *a = SPStringOrNil(SPMsg0(icon, @"applicationBundleID"));
        if (a) return a;
        NSString *b = SPStringOrNil(SPMsg0(icon, @"bundleIdentifier"));
        if (b) return b;
        id app = SPMsg0(icon, @"application");
        if (app) {
            NSString *c = SPStringOrNil(SPMsg0(app, @"bundleIdentifier"));
            if (c) return c;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

#pragma mark - 长按后挂的小菜单

@interface SPIconMenuBar : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, copy) NSString *bundleID;
+ (instancetype)shared;
- (void)showForBundleID:(NSString *)bid nearPoint:(CGPoint)pt inScene:(id)scene;
- (void)dismiss;
@end

@implementation SPIconMenuBar
+ (instancetype)shared {
    static SPIconMenuBar *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SPIconMenuBar new]; });
    return s;
}

- (void)dismiss {
    if (_window) {
        _window.hidden = YES;
        [SPWindowRegistry releaseWindow:_window];
        _window = nil;
    }
    _bundleID = nil;
}

- (void)showForBundleID:(NSString *)bid nearPoint:(CGPoint)pt inScene:(id)scene {
    [self dismiss];
    if (!bid.length) return;
    _bundleID = [bid copy];

    // 找当前活跃的 UIWindowScene：优先传入的，其次 SpringBoard 自己的
    UIWindowScene *ws = nil;
    if ([scene isKindOfClass:[UIWindowScene class]]) ws = (UIWindowScene *)scene;
    if (!ws) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                ws = (UIWindowScene *)s; break;
            }
        }
    }
    if (!ws) { SPLog(@"icon menu: 找不到 windowScene"); return; }

    UIWindow *w = [SPWindowRegistry makeWindowWithScene:ws level:UIWindowLevelStatusBar + 10];
    w.backgroundColor = [UIColor clearColor];
    w.frame = ws.coordinateSpace.bounds;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = vc;

    CGFloat wd = 210, ht = 56;
    CGFloat x = MIN(MAX(12.0, pt.x - wd / 2), w.frame.size.width - wd - 12);
    CGFloat y = MAX(60.0, pt.y - ht);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(x, y, wd, ht)];
    card.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    card.layer.cornerRadius = 14;
    card.layer.masksToBounds = YES;

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(18, 0, wd - 60, ht)];
    lab.text = @"上下分屏";
    lab.textColor = [UIColor whiteColor];
    lab.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [card addSubview:lab];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(wd - 38, 16, 24, 24)];
    iv.image = [UIImage systemImageNamed:@"rectangle.split.1x2"];
    iv.tintColor = [UIColor whiteColor];
    [card addSubview:iv];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = card.bounds;
    [btn addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:btn];

    [vc.view addSubview:card];
    w.hidden = NO;

    // 点空白关闭
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)];
    [vc.view addGestureRecognizer:tap];

    _window = w;
    SPLog(@"icon menu: 浮动菜单已弹出 %@ at %.0f,%.0f", bid, x, y);

    // 6 秒无操作自动关
    __weak typeof(self) ws2 = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(ws2) self2 = ws2;
        if (self2 && self2.window) [self2 dismiss];
    });
}

- (void)backgroundTapped:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:g.view];
    UIView *card = g.view.subviews.firstObject;
    if (!CGRectContainsPoint(card.frame, p)) [self dismiss];
}

- (void)tapped {
    NSString *bid = [_bundleID copy];
    [self dismiss];
    if (!bid.length) return;
    SPLog(@"icon menu -> split %@", bid);
    @try {
        [[SPGesture shared] startSplitFromIconForBundleID:bid];
    } @catch (NSException *e) {
        SPLog(@"icon menu: start split ex %@", e.reason);
    }
}
@end

#pragma mark - hook

static id SPHookedCtxMenu(id self, SEL _cmd, id interaction, CGPoint location) {
    // 无论发生什么，都必须返回系统原本的 configuration —— 绝不影响系统菜单
    id original = nil;
    @try {
        SPLog(@"icon menu: 长按触发");
        original = gOrigCtxMenu ? gOrigCtxMenu(self, _cmd, interaction, location) : nil;
    } @catch (NSException *e) {
        SPLog(@"icon menu: 原实现异常 %@", e.reason);
        return nil;
    }

    @try {
        NSString *bid = SPBundleIDForIconView(self);
        SPLog(@"icon menu: bundleID=%@", bid ?: @"nil");
        if (bid.length) {
            id scene = nil;
            @try { scene = SPMsg0(self, @"windowScene"); } @catch (__unused NSException *e) {}
            if (!scene) {
                @try { scene = SPMsg0([self window], @"windowScene"); } @catch (__unused NSException *e) {}
            }
            // 等系统菜单动画起来再弹，避免两个菜单同一帧叠在一起
            NSString *bidCopy = [bid copy];
            SEL ignored = _cmd;
            (void)ignored;
            __weak typeof([SPIconMenuBar shared]) wbar = [SPIconMenuBar shared];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    [[SPIconMenuBar shared] dismiss];
                    [wbar showForBundleID:bidCopy nearPoint:location inScene:scene];
                } @catch (NSException *e) { SPLog(@"icon menu: 延迟弹出异常 %@", e.reason); }
            });
        }
    } @catch (NSException *e) {
        SPLog(@"icon menu: 弹菜单异常 %@", e.reason);
    }
    return original;
}

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
    if (!gOrigCtxMenu) SPLog(@"icon menu: ⚠️ original 为空，hook 可能未生效");
}