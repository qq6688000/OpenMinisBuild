#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Registers activation gestures on SpringBoard's key window.
@interface DPGestureController : NSObject

+ (instancetype)shared;

- (void)installOnView:(UIView *)view;
- (void)uninstall;
- (void)reloadFromSettings;

@end

NS_ASSUME_NONNULL_END
