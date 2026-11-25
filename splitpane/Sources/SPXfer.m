#import "SPXfer.h"
#import <UIKit/UIKit.h>
#import "SPHost.h"

@interface SPXferSheet : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, copy) NSString *targetBundleID;
@property (nonatomic, strong) UIWindowScene *scene;
@end

@implementation SPXferSheet

- (void)dismiss {
    if (_window) {
        _window.hidden = YES;
        _window.rootViewController = nil;
        _window.windowScene = nil;
        _window = nil;
    }
}

- (void)presentInScene:(UIWindowScene *)scene target:(NSString *)bid {
    [self dismiss];
    _targetBundleID = [bid copy];
    _scene = scene;

    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelStatusBar + 200;
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    w.frame = scene.coordinateSpace.bounds;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = vc;

    CGFloat W = w.bounds.size.width;
    CGFloat cardW = W - 60, cardH = 260;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(30, (w.bounds.size.height - cardH) / 2.0, cardW, cardH)];
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.98];
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [vc.view addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, cardW - 40, 26)];
    title.text = @"发送到另一半";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 48, cardW - 40, 20)];
    sub.text = bid ?: @"";
    sub.font = [UIFont systemFontOfSize:12];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    [card addSubview:sub];

    NSArray *opts = @[@"当前剪贴板", @"最近截图", @"选一个文件…"];
    CGFloat y = 84;
    for (NSString *t in opts) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16, y, cardW - 32, 48);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.titleEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 0);
        [b setTitle:t forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
        b.layer.cornerRadius = 12;
        b.tag = [opts indexOfObject:t];
        [b addTarget:self action:@selector(optionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:b];
        y += 56;
    }

    UITapGestureRecognizer *bg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTapped:)];
    [vc.view addGestureRecognizer:bg];

    w.hidden = NO;
    _window = w;
    SPLog(@"xfer: sheet presented target=%@", bid);
}

- (void)bgTapped:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:g.view];
    UIView *card = g.view.subviews.firstObject;
    if (!CGRectContainsPoint(card.frame, p)) [self dismiss];
}

- (void)optionTapped:(UIButton *)b {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    switch (b.tag) {
        case 0: {
            if (pb.hasStrings || pb.hasImages || pb.hasURLs) {
                SPLog(@"xfer: 剪贴板已有内容，直接交棒");
                [self handoff:@"剪贴板"];
            } else {
                [self toast:@"剪贴板是空的"];
            }
            break;
        }
        case 1: {
            UIImage *img = pb.image;
            if (!img) { [self toast:@"剪贴板里没有图片"]; break; }
            SPLog(@"xfer: 发送图片 %.0fx%.0f", img.size.width, img.size.height);
            [self handoff:@"截图"];
            break;
        }
        default: {
            // 选文件：走系统 document picker 或直接共享剪贴板内容
            [self dismiss];
            NSArray *items = nil;
            if (pb.image) items = @[pb.image];
            else if (pb.string.length) items = @[pb.string];
            else if (pb.URL) items = @[pb.URL];
            if (!items.count) { [self toastFromWindow:@"没东西可发"]; break; }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIActivityViewController *avc =
                    [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
                UIWindow *host = [SPXfer topWindowInScene:_scene];
                if (host && host.rootViewController) {
                    [host.rootViewController presentViewController:avc animated:YES completion:nil];
                }
            });
            break;
        }
    }
}

- (void)toastFromWindow:(NSString *)msg {
    SPLog(@"xfer: %@", msg);
}

- (void)toast:(NSString *)msg {
    if (!_window) return;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 44)];
    l.center = _window.rootViewController.view.center;
    l.text = msg;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:14];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    l.layer.cornerRadius = 22;
    l.clipsToBounds = YES;
    [_window.rootViewController.view addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [l removeFromSuperview];
        [self dismiss];
    });
}

- (void)handoff:(NSString *)kind {
    SPLog(@"xfer: 把 %@ 交给 %@", kind, _targetBundleID);
    NSString *bid = _targetBundleID;
    [self dismiss];
    // 内容已经在系统剪贴板里，用户切到另一半窗口直接粘贴即可。
    // 这里只负责把目标 App 提到前台，剩下的粘贴由系统/用户完成。
    if (bid.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try { [SPHost reactivateApp:bid]; } @catch (__unused NSException *e) {}
        });
    }
}

@end

@implementation SPXfer

static SPXferSheet *gSheet = nil;

+ (UIWindow *)topWindowInScene:(UIWindowScene *)scene {
    UIWindow *best = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.windowLevel > UIWindowLevelStatusBar + 100) continue;   // 跳过我们自己的面板
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    return best;
}

+ (void)presentSenderForBundleID:(NSString *)targetBundleID
                      fromWindow:(UIWindow *)window
                        inScene:(UIWindowScene *)scene {
    if (!scene) return;
    if (!gSheet) gSheet = [SPXferSheet new];
    [gSheet presentInScene:scene target:targetBundleID];
}

+ (BOOL)sendPasteboardToBundleID:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if (!(pb.hasStrings || pb.hasImages || pb.hasURLs)) return NO;
    [SPHost reactivateApp:bundleID];
    return YES;
}

@end
