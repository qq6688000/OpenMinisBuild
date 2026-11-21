#import "DPPassthroughWindow.h"
#import "DPWindowManager.h"
#import "DPFloatingWindow.h"

@interface DPOverlayRootViewController ()
@property (nonatomic) CGRect lastLayoutBounds;
@property (nonatomic) UIInterfaceOrientation lastLayoutOrientation;
@property (nonatomic) BOOL hasLayoutGeometry;
@property (nonatomic) BOOL notifyingGeometry;
- (void)notifyGeometryIfNeeded:(BOOL)force;
@end

@implementation DPOverlayRootViewController

- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // Follow the owning scene; do not constrain the overlay to portrait.
    return UIInterfaceOrientationMaskAll;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self notifyGeometryIfNeeded:NO];
}

- (void)viewWillTransitionToSize:(CGSize)size
     withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        // The SpringBoard orientation hook can precede the scene/root update.
        // Read the final UIKit bounds, never transpose the announced size.
        [weakSelf notifyGeometryIfNeeded:YES];
    }];
}

- (void)notifyGeometryIfNeeded:(BOOL)force {
    if (self.notifyingGeometry || !self.isViewLoaded || !self.view.window) return;
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        orientation = self.view.window.windowScene.interfaceOrientation;
    }
    if (!force && self.hasLayoutGeometry && CGRectEqualToRect(bounds, self.lastLayoutBounds) &&
        orientation == self.lastLayoutOrientation) return;
    self.lastLayoutBounds = bounds;
    self.lastLayoutOrientation = orientation;
    self.hasLayoutGeometry = YES;
    // Relayout panes only: never unhide or reattach a window from this callback.
    self.notifyingGeometry = YES;
    if (self.geometryDidChange) self.geometryDidChange();
    self.notifyingGeometry = NO;
}

@end

@implementation DPPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 点到自己（空白处）→ 穿透给下面的系统界面
    if (hit == self) return nil;
    return hit;
}

@end

@implementation DPPassthroughWindow

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan && touch.window == self) {
                [[DPWindowManager shared] prepareForTouchInView:touch.view];
                break;
            }
        }
    }
    [super sendEvent:event];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelStatusBar + 120.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        // 不抢 keyWindow，避免干扰输入
        if (@available(iOS 13.0, *)) {
            // scene 在 install 时设置
        }
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end
