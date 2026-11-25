#import "SPAppPicker.h"
#import "SPCompat.h"
#import "SPHost.h"
#import "SPWindowRegistry.h"
#import "SPSettings.h"
#import <objc/runtime.h>

typedef struct { CGSize size; CGFloat scale; CGFloat continuousCornerRadius; } SBIconImageInfo;

// 选 App 面板。两条路径：
//   A. SBIconController + SBIconListView 原位（主屏网格搬过来，系统原样图标）
//   B. 自绘：从 SBApplicationController 枚举已安装 App，取图标，网格排
// 任一步失败都退到 B。面板本身就是 PV 的「挂起后择 App」。

#pragma mark - 图标获取

static NSCache *SPIconCache(void) {
    static NSCache *c; static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [NSCache new]; c.countLimit = 200; });
    return c;
}

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
    // ② 取不到就返回 nil，cell 会显示深灰占位。绝不在这里同步渲染 SBIconView ——
    //    这台机器上那条路必然失败，却会把主线程拖住。
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
    if (![apps isKindOfClass:[NSArray class]]) return out;
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

@interface SPAppPickerCell : UICollectionViewCell
@property (nonatomic, copy) NSString *representedBundleID;
@end

@implementation SPAppPickerCell
- (void)prepareForReuse {
    [super prepareForReuse];
    self.representedBundleID = nil;
    ((UIImageView *)[self.contentView viewWithTag:1001]).image = nil;
}
@end

@interface SPAppPicker () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic, copy) void (^pickBlock)(NSString *);
@property (nonatomic, copy) void (^cancelBlock)(void);
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, assign) BOOL finishing;
@property (nonatomic, copy) NSString *resultBundleID;
- (void)finishWithBundleID:(NSString *)bundleID animated:(BOOL)animated;
@end

@implementation SPAppPicker

static SPAppPicker *gPicker = nil;

+ (BOOL)isPresenting { return gPicker != nil; }

+ (void)cancelIfPresent {
    if (gPicker) [gPicker finishWithBundleID:nil animated:NO];
}

+ (void)presentFromWindowScene:(UIWindowScene *)scene bundleIDs:(NSArray *)extra
                        onPick:(void (^)(NSString *))onPick onCancel:(void (^)(void))onCancel {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentFromWindowScene:scene bundleIDs:extra onPick:onPick onCancel:onCancel];
        });
        return;
    }
    if (gPicker) return;
    if (![SPSettings enabled]) { if (onCancel) onCancel(); return; }
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive ||
        [NSStringFromClass(scene.class) containsString:@"Aperture"]) {
        scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive &&
                ![NSStringFromClass(s.class) containsString:@"Aperture"]) {
                scene = (UIWindowScene *)s; break;
            }
        }
    }
    if (!scene) { if (onCancel) onCancel(); return; }
    SPAppPicker *p = [SPAppPicker new];
    gPicker = p;
    p.pickBlock = onPick;
    p.cancelBlock = onCancel;
    @try {
        NSMutableArray *items = [NSMutableArray array];
        if ([extra isKindOfClass:[NSArray class]]) [items addObjectsFromArray:extra];
        [items addObjectsFromArray:SPInstalledAppBundleIDs()];
        NSMutableArray *uniq = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
        for (id b in items) {
            if (![b isKindOfClass:[NSString class]] || ![b length] || [seen containsObject:b]) continue;
            [seen addObject:b]; [uniq addObject:b];
        }
        p.items = uniq;
        [p buildInScene:scene];
    } @catch (__unused NSException *e) {
        [p finishWithBundleID:nil animated:NO];
    }
}

- (void)buildInScene:(UIWindowScene *)scene {
    UIWindow *w = [SPWindowRegistry makeWindowWithScene:scene level:UIWindowLevelNormal + 3];
    if (!w) { [self finishWithBundleID:nil animated:NO]; return; }
    _window = w;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.hidden = NO;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(settingsChanged:) name:SPNotifyChanged object:nil];
    [nc addObserver:self selector:@selector(sceneDisconnected:) name:UISceneDidDisconnectNotification object:scene];
    [nc addObserver:self selector:@selector(sceneDisconnected:) name:UISceneDidEnterBackgroundNotification object:scene];
    [nc addObserver:self selector:@selector(windowHidden:) name:UIWindowDidBecomeHiddenNotification object:w];

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
    [_grid registerClass:SPAppPickerCell.class forCellWithReuseIdentifier:@"app"];
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

    // 明确的关闭按钮：不选就直接退出（用户要求）
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.92] forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    close.layer.cornerRadius = 19;
    close.frame = CGRectMake(vc.view.bounds.size.width - 58,
                             vc.view.safeAreaInsets.top + 14, 38, 38);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close addTarget:self action:@selector(cancel:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:close];
    _hintLabel = hint;
}

- (void)cancel:(id)sender {
    [self finishWithBundleID:nil animated:YES];
}

- (void)settingsChanged:(NSNotification *)notification {
    if (![SPSettings enabled]) [self finishWithBundleID:nil animated:NO];
}

- (void)sceneDisconnected:(NSNotification *)notification {
    [self finishWithBundleID:nil animated:NO];
}

- (void)windowHidden:(NSNotification *)notification {
    [self finishWithBundleID:nil animated:NO];
}

- (void)finishWithBundleID:(NSString *)bundleID animated:(BOOL)animated {
    if (_finishing) {
        if (!bundleID.length) self.resultBundleID = nil; // 动画期间的关闭/断场景优先于先前选择
        return;
    }
    _finishing = YES;
    self.resultBundleID = bundleID;
    UIWindow *w = _window;
    w.userInteractionEnabled = NO;
    void (^pick)(NSString *) = self.pickBlock;
    void (^cancel)(void) = self.cancelBlock;
    self.pickBlock = nil;
    self.cancelBlock = nil;
    void (^cleanup)(void) = ^{
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        NSString *result = self.resultBundleID;
        self.resultBundleID = nil;
        self.grid.delegate = nil;
        self.grid.dataSource = nil;
        self.window = nil;
        [SPWindowRegistry releaseWindow:w];
        if (gPicker == self) gPicker = nil;
        // 交接前必须已放掉自己的窗口；回调可能立即创建分屏或另一个 picker。
        if (result.length && pick) pick(result);
        else if (cancel) cancel();
    };
    if (!animated || !w || w.hidden || !w.windowScene) { cleanup(); return; }
    [UIView animateWithDuration:0.2 animations:^{
        self.blur.alpha = 0;
        self.grid.alpha = 0;
        self.hintLabel.alpha = 0;
    } completion:^(BOOL finished) { cleanup(); }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 网格

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    return _items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    SPAppPickerCell *cell = (SPAppPickerCell *)[cv dequeueReusableCellWithReuseIdentifier:@"app" forIndexPath:ip];
    NSString *bid = _items[ip.item];
    cell.representedBundleID = bid;
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
    // 图标异步加载：cell 里绝不做同步渲染（12 个格子同步跑会卡住主线程）
    UIImage *cached = [SPIconCache() objectForKey:bid];
    iv.image = cached;
    iv.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    if (!cached) {
        __weak SPAppPickerCell *weakCell = cell;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = nil;
            @try { img = SPIconForBundleID(bid, CGSizeMake(64, 64)); }
            @catch (__unused NSException *e) {}
            if (!img) return;
            [SPIconCache() setObject:img forKey:bid];
            dispatch_async(dispatch_get_main_queue(), ^{
                SPAppPicker *picker = weakSelf;
                SPAppPickerCell *currentCell = weakCell;
                if (!picker.window || picker.finishing || !currentCell ||
                    ![currentCell.representedBundleID isEqualToString:bid]) return;
                UIImageView *currentImage = [currentCell.contentView viewWithTag:1001];
                currentImage.image = img;
            });
        });
    }
    lb.text = SPDisplayNameForBundleID(bid);
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    if (_finishing || ip.item >= _items.count) return;
    [self finishWithBundleID:_items[ip.item] animated:YES];
}

@end