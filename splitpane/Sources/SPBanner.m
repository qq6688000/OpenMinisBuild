#import "SPLog.h"
#import "SPWindowRegistry.h"
#import <UIKit/UIKit.h>

// 可见探针。dylib 被注入且 constructor 跑到了，屏幕顶部就会滑下一条小浮条。
// 看不见 = 没注入，跟手势逻辑无关。

void SPShowLoadBanner(NSString *text) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
        }
        if (!scene) scene = [UIApplication sharedApplication].windows.firstObject.windowScene;
        if (!scene) return;

        UIWindow *w = [SPWindowRegistry makeWindowWithScene:scene level:UIWindowLevelNormal + 4];
        w.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        w.rootViewController = vc;
        w.hidden = NO;

        UILabel *label = [UILabel new];
        label.text = text;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        label.layer.cornerRadius = 14;
        label.layer.cornerCurve = kCACornerCurveContinuous;
        label.layer.masksToBounds = YES;
        CGFloat width = MIN(scene.coordinateSpace.bounds.size.width - 60, 280);
        label.frame = CGRectMake(0, -34, width, 30);
        label.center = CGPointMake(scene.coordinateSpace.bounds.size.width / 2.0, 0);
        [vc.view addSubview:label];

        [UIView animateWithDuration:0.3 animations:^{
            label.center = CGPointMake(label.center.x, 62);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.3 delay:2.4 options:0 animations:^{
                label.alpha = 0;
            } completion:^(BOOL finished2) {
                [SPWindowRegistry releaseWindow:w];
            }];
        }];
    });
}