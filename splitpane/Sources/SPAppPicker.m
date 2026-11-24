#import "SPAppPicker.h"
#import "SPCompat.h"
#import "SPHost.h"
#import <objc/runtime.h>

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } SBIconImageInfo;

// 选 App 面板。两条路径：
//   A. SBIconController + SBIconListView 原位（主屏网格搬过来，系统原样图标）
//   B. 自绘：从 SBApplicationController 枚举已安装 App，取图标，网格排
// 任一步失败都退到 B。面板本身就是 PV 的「挂起后择 App」。

#pragma mark - 图标获取

static UIImage *SPIconForBundleID(NSString *bundleID, CGSize size) {
    // ① 系统图标缓存（SpringBoard 里最靠谱，返回的是已经渲染好的图标）
    Class cacheCls = NSClassFromString(@"SBIconImageInfoCache");
    (void)cacheCls;
    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    id app = ctrl ? SPMsg1(ctrl, @"applicationWithBundleIdentifier:", bundleID) : nil;
    id icon = SPMsg0(app, @"icon");
    if (icon) {
        // SBIcon -iconImageWithInfo: 收的是 SBIconImageInfo{size, scale, continuousCornerRadius}
        SBIconImageInfo info = { size, [UIScreen mainScreen].scale, size.width * 0.2237 };
        SEL infoSel = NSSelectorFromString(@"iconImageWithInfo:");
        Method m = class_getInstanceMethod(object_getClass(icon), infoSel);
        if (m) {
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
            if (sig.numberOfArguments == 3 && sig.methodReturnType && strcmp(sig.methodReturnType, "@") == 0) {
                @try {
                    UIImage *img = ((UIImage * (*)(id, SEL, SBIconImageInfo))objc_msgSend)(icon, infoSel, info);
                    if ([img isKindOfClass:[UIImage class]]) return img;
                } @catch (__unused NSException *e) {}
            }
        }
    }
    // ② Fallback：主屏图标视图（SBIconView）渲染一帧
    Class iconViewCls = NSClassFromString(@"SBIconView");
    if (icon && iconViewCls) {
        SEL initSel = NSSelectorFromString(@"initWithConfigurationOptions:");
        UIView *iconView = nil;
        @try {
            if ([iconViewCls instancesRespondToSelector:initSel])
                iconView = ((id (*)(id, SEL, unsigned long long))objc_msgSend)([iconViewCls alloc], initSel, 0);
            if (iconView) {
                [iconView setValue:icon forKey:@"icon"];
                iconView.frame = CGRectMake(0, 0, size.width, size.width);
                [iconView layoutIfNeeded];
                UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:iconView.bounds.size];
                return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                    [iconView.layer renderInContext:ctx.CGContext];
                }];
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSString *SPDisplayNameForBundleID(NSString *bundleID) {
    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    id app = ctrl ? SPMsg1(ctrl, @"applicationWithBundleIdentifier:", bundleID) : nil;
    id name = SPMsg0(app, @"displayName");
    if (![name isKindOfClass:[NSString class]] || ![name length]) {
        id app = [SPHost applicationProxyForBundleID:bundleID];
        name = SPMsg0(app, @"displayName");
    }
    return [name isKindOfClass:[NSString class]] && [name length] ? name : bundleID;
}

static NSArray<NSString *> *SPInstalledAppBundleIDs(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    NSArray *apps = nil;
    if (ctrl) apps = SPMsg0(ctrl, @"allApplications");
    if (![apps isKindOfClass:[NSArray class]]) apps = SPMsg0(ctrl, @"applications");
    for (id app in apps) {
        if (![app respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) continue;
        NSString *bid = SPMsg0(app, @"bundleIdentifier");
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;
        // 系统进程/隐藏 App
        if (SPBool0(app, @"isSystemApplication")) continue;
        if ([seen containsObject:bid]) continue;
        [seen addObject:bid];
        [out addObject:bid];
    }
    (void)seen;
    return out;
}

#pragma mark - 面板

@interface SPAppPicker () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic, copy) void (^pickBlock)(NSString *);
@property (nonatomic, copy) void (^cancelBlock)(void);
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *hintLabel;
@end

@implementation SPAppPicker

static SPAppPicker *gPicker = nil;

+ (BOOL)isPresenting { return gPicker != nil; }

+ (void)presentFromWindowScene:(UIWindowScene *)scene bundleIDs:(NSArray *)extra
                        onPick:(void (^)(NSString *))onPick onCancel:(void (^)(void))onCancel {
    if (gPicker) return;
    if (!scene) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s; break;
            }
        }
    }
    if (!scene) return;
    SPAppPicker *p = [SPAppPicker new];
    gPicker = p;
    p.pickBlock = onPick;
    p.cancelBlock = onCancel;
    NSMutableArray *items = [NSMutableArray array];
    if ([extra isKindOfClass:[NSArray class]]) [items addObjectsFromArray:extra];
    [items addObjectsFromArray:SPInstalledAppBundleIDs()];
    NSMutableArray *uniq = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSString *b in items) { if (![seen containsObject:b]) { [seen addObject:b]; [uniq addObject:b]; } }
    p.items = uniq;
    [p buildInScene:scene];
}

- (void)buildInScene:(UIWindowScene *)scene {
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelStatusBar + 130;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.hidden = NO;
    _window = w;

    _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    _blur.frame = vc.view.bounds;
    _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _blur.alpha = 0;
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancel:)];
    [_blur addGestureRecognizer:bgTap];
    [vc.view addSubview:_blur];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = CGSizeMake(76, 100);
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 20;
    layout.sectionInset = UIEdgeInsetsMake(12, 16, 12, 16);
    _grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _grid.backgroundColor = UIColor.clearColor;
    _grid.dataSource = self;
    _grid.delegate = self;
    _grid.showsVerticalScrollIndicator = NO;
    _grid.alpha = 0;
    [_grid registerClass:NSClassFromString(@"UICollectionViewCell") forCellWithReuseIdentifier:@"app"];
    [vc.view addSubview:_grid];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"选一个 App 放在下半屏";
    hint.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.alpha = 0;
    [vc.view addSubview:hint];

    [_grid setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:24],
        [hint.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [_grid.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:18],
        [_grid.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [_grid.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
        [_grid.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
    ]];
    [vc.view layoutIfNeeded];

    [UIView animateWithDuration:0.28 animations:^{
        self.blur.alpha = 0.92;
        self.grid.alpha = 1;
        hint.alpha = 1;
    }];
    _hintLabel = hint;
}

- (void)cancel:(id)sender {
    [self finishWithBundleID:nil];
}

- (void)finishWithBundleID:(NSString *)bundleID {
    if (!_window) return;
    UIWindow *w = _window;
    _window = nil;
    gPicker = nil;
    [UIView animateWithDuration:0.2 animations:^{
        self.blur.alpha = 0;
        self.grid.alpha = 0;
    } completion:^(BOOL finished) {
        w.hidden = YES;
        w.rootViewController = nil;
    }];
    if (bundleID && self.pickBlock) self.pickBlock(bundleID);
    else if (self.cancelBlock) self.cancelBlock();
    self.pickBlock = nil;
    self.cancelBlock = nil;
}

#pragma mark - 网格

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return _items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"app" forIndexPath:ip];
    NSString *bid = _items[ip.item];
    UIImageView *iv = [cell.contentView viewWithTag:1001];
    UILabel *lb = [cell.contentView viewWithTag:1002];
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:CGRectMake(6, 0, 64, 64)];
        iv.tag = 1001;
        iv.layer.cornerRadius = 14;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.layer.masksToBounds = YES;
        iv.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
        [cell.contentView addSubview:iv];
        lb = [[UILabel alloc] initWithFrame:CGRectMake(-4, 66, 84, 32)];
        lb.tag = 1002;
        lb.font = [UIFont systemFontOfSize:10.5];
        lb.textColor = [UIColor colorWithWhite:1 alpha:0.88];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.numberOfLines = 2;
        [cell.contentView addSubview:lb];
    }
    iv.image = SPIconForBundleID(bid, CGSizeMake(64, 64));
    lb.text = SPDisplayNameForBundleID(bid);
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [self finishWithBundleID:_items[ip.item]];
}

@end