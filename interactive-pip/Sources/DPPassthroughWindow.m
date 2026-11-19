#import "DPPassthroughWindow.h"
#import "DPWindowManager.h"

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
                // The text field lives in the hosted app process, so its
                // becomeFirstResponder call never reaches SpringBoard.
                [[DPWindowManager shared] prepareForHostedInput];
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
