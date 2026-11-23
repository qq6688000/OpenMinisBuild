#import "DPPipDrawerController.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kDPDrawerTongueKey = @"dp.drawer.tongue";

@implementation DPPipDrawerController {
    BOOL _parked;
    NSInteger _edge;
    __weak UIView *_hostView;
    __weak UIView *_contentView;
    UIView *_tongueView;
    __weak UIView *_originalSuperview;
    CGRect _originalFrame;
    NSString *_bundleID;
}

+ (instancetype)shared {
    static DPPipDrawerController *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [DPPipDrawerController new]; });
    return inst;
}

- (BOOL)isParked { return _parked; }

#pragma mark - Park / Unpark

- (BOOL)parkContentView:(UIView *)contentView
             inHostView:(UIView *)hostView
                  edge:(NSInteger)edge
               bundleID:(NSString *)bundleID {
    if (!contentView) return NO;
    // 0.7.213 铁律：绝不把 UIWindow 变成别处的子视图 ——
    // UIWindow 一旦成为非 root 子视图，convertRect:fromCoordinateSpace: 会递归爆栈
    // （0.7.212 就是这样让 SpringBoard SIGSEGV / STACK GUARD 连续崩 4 次）。
    if ([contentView isKindOfClass:UIWindow.class] || [hostView isKindOfClass:UIWindow.class]) {
        NSLog(@"[InteractivePiP] refused to park UIWindow (would stack-overflow) content=%@ host=%@",
              NSStringFromClass([contentView class]), NSStringFromClass([hostView class]));
        return NO;
    }
    // 也不能挂到一个会反过来包含自己的视图里
    if ([hostView isDescendantOfView:contentView] || hostView == contentView) {
        NSLog(@"[InteractivePiP] refused: host is descendant of content");
        return NO;
    }
    [self tearDown];

    _contentView = contentView;
    _hostView = hostView ?: contentView.superview;
    _originalSuperview = contentView.superview;
    _originalFrame = contentView.frame;
    _edge = edge ?: 1;
    _bundleID = [bundleID copy];

    CGRect hostBounds = _hostView ? _hostView.bounds : [UIScreen mainScreen].bounds;
    CGRect bounds = hostBounds;

    // 抽屉宽度：屏幕短边的 ~34%，高度按 16:9-ish 收成一条
    CGFloat shortSide = MIN(bounds.size.width, bounds.size.height);
    CGFloat drawerW = MAX(160, shortSide * 0.34);
    CGFloat drawerH = drawerW * 0.62;

    CGRect drawerFrame;
    switch (_edge) {
        case 2: // 左侧
            drawerFrame = CGRectMake(-drawerW * 0.62, bounds.size.height * 0.28, drawerW, drawerH);
            break;
        case 3: // 顶部
            drawerFrame = CGRectMake(bounds.size.width - drawerW - 12, -drawerH * 0.62, drawerW, drawerH);
            break;
        case 1: // 右侧（默认）
        default:
            drawerFrame = CGRectMake(bounds.size.width - drawerW * 0.38, bounds.size.height * 0.28, drawerW, drawerH);
            break;
    }

    // 把 contentView 收进抽屉：保留它的内部结构，只改 transform + frame
    contentView.transform = CGAffineTransformIdentity;
    contentView.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
    contentView.autoresizingMask = UIViewAutoresizingNone;

    // 抽屉容器：裁剪 + 圆角 + 阴影
    UIView *drawer = [[UIView alloc] initWithFrame:drawerFrame];
    drawer.backgroundColor = [UIColor blackColor];
    drawer.clipsToBounds = NO;
    drawer.layer.cornerRadius = 14;
    drawer.layer.cornerCurve = kCACornerCurveContinuous;
    drawer.layer.masksToBounds = NO;
    drawer.layer.shadowColor = [UIColor blackColor].CGColor;
    drawer.layer.shadowOpacity = 0.35;
    drawer.layer.shadowRadius = 12;
    drawer.layer.shadowOffset = CGSizeMake(0, 4);
    drawer.tag = 0x5D9;

    UIView *clip = [[UIView alloc] initWithFrame:drawer.bounds];
    clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    clip.clipsToBounds = YES;
    clip.layer.cornerRadius = 14;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    [drawer addSubview:clip];

    // contentView 缩放到抽屉尺寸
    CGFloat sx = drawer.bounds.size.width / MAX(1, bounds.size.width);
    CGFloat sy = drawer.bounds.size.height / MAX(1, bounds.size.height);
    CGFloat s = MAX(sx, sy);
    contentView.transform = CGAffineTransformMakeScale(s, s);
    contentView.center = CGPointMake(clip.bounds.size.width / 2, clip.bounds.size.height / 2);
    [clip addSubview:contentView];

    // 贴边"舌头"：竖条，提示可拖出
    UIView *tongue = [[UIView alloc] initWithFrame:CGRectMake(_edge == 2 ? drawer.bounds.size.width - 4 : 0, 8, 4, drawer.bounds.size.height - 16)];
    tongue.backgroundColor = [UIColor whiteColor];
    tongue.alpha = 0.35;
    tongue.layer.cornerRadius = 2;
    tongue.layer.cornerCurve = kCACornerCurveContinuous;
    tongue.userInteractionEnabled = NO;
    [drawer addSubview:tongue];
    _tongueView = tongue;

    [_hostView addSubview:drawer];
    objc_setAssociatedObject(contentView, (__bridge const void *)kDPDrawerTongueKey, drawer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 点击抽屉 → 展开
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrawerTap:)];
    [drawer addGestureRecognizer:tap];

    _parked = YES;
    NSLog(@"[InteractivePiP] PiP drawer parked edge=%ld bundle=%@ frame=%@", (long)_edge, _bundleID, NSStringFromCGRect(drawerFrame));
    return YES;
}

- (void)handleDrawerTap:(UITapGestureRecognizer *)g {
    NSLog(@"[InteractivePiP] PiP drawer tapped -> unpark");
    [self unparkAnimated:YES];
}

- (void)unparkAnimated:(BOOL)animated {
    UIView *cv = _contentView;
    if (!cv) { [self tearDown]; return; }
    UIView *drawer = objc_getAssociatedObject(cv, (__bridge const void *)kDPDrawerTongueKey);

    void (^restore)(void) = ^{
        cv.transform = CGAffineTransformIdentity;
        cv.frame = self->_originalFrame;
        if (self->_originalSuperview) [self->_originalSuperview addSubview:cv];
        [drawer removeFromSuperview];
    };
    if (animated && drawer) {
        [UIView animateWithDuration:0.28 animations:^{
            drawer.alpha = 0;
            drawer.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL finished) {
            restore();
        }];
    } else {
        restore();
    }
    _parked = NO;
    NSLog(@"[InteractivePiP] PiP drawer unparked");
}

- (void)tearDown {
    UIView *cv = _contentView;
    if (cv) {
        UIView *drawer = objc_getAssociatedObject(cv, (__bridge const void *)kDPDrawerTongueKey);
        [drawer removeFromSuperview];
        objc_setAssociatedObject(cv, (__bridge const void *)kDPDrawerTongueKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cv.transform = CGAffineTransformIdentity;
    }
    _contentView = nil;
    _hostView = nil;
    _originalSuperview = nil;
    _tongueView = nil;
    _bundleID = nil;
    _parked = NO;
}

#pragma mark - 系统 PiP 容器（PV 的 PVPIPEmbedding 等价物）

- (id)makeSystemPiPContainerForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    // PV 用 SBPIPContainerViewController 托管挂起的 App。这里做能力探测：
    // 找到 PiP 控制器后问它要容器。拿不到返回 nil，调用方回退自有托管。
    Class coordCls = NSClassFromString(@"SBPIPControllerCoordinator");
    Class pipCls = NSClassFromString(@"SBPIPController");
    NSLog(@"[InteractivePiP] PiP probe: SBPIPControllerCoordinator=%@ SBPIPController=%@",
          coordCls ? @"yes" : @"no", pipCls ? @"yes" : @"no");

    id controller = nil;
    for (Class c in @[coordCls ?: [NSNull class], pipCls ?: [NSNull class]]) {
        if (c == [NSNull class]) continue;
        for (NSString *name in @[@"sharedInstance", @"sharedCoordinator", @"sharedController"]) {
            SEL sel = NSSelectorFromString(name);
            if ([c respondsToSelector:sel]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(c, sel);
                if (v) { controller = v; break; }
            }
        }
        if (controller) break;
    }
    NSLog(@"[InteractivePiP] PiP probe controller=%@",
          controller ? NSStringFromClass(object_getClass(controller)) : @"nil");

    if (!controller) return nil;

    // 找容器工厂
    for (NSString *name in @[@"pictureInPictureContainerViewController",
                             @"pipContainerViewController",
                             @"activePIPContainerViewController"]) {
        SEL sel = NSSelectorFromString(name);
        if (![controller respondsToSelector:sel]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(controller, sel);
            if (v) {
                NSLog(@"[InteractivePiP] PiP container via -%@ -> %@", name,
                      NSStringFromClass(object_getClass(v)));
                return v;
            }
        } @catch (__unused NSException *e) {}
    }
    NSLog(@"[InteractivePiP] PiP container not available on this OS build");
    return nil;
}

@end
