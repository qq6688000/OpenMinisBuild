#import <UIKit/UIKit.h>
// Empty root space (including the pane divider) must not swallow SpringBoard input.
@interface SPContentWindow : UIWindow
@end
@protocol SPPanelActions <NSObject>
- (void)captureSlot:(NSInteger)slot;
- (void)startPair;
- (void)stopPair;
- (void)swapPair;
- (void)setPairRatio:(CGFloat)ratio;
@end
@interface SPPanel : NSObject
@property(nonatomic,weak) id<SPPanelActions> delegate;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UILabel *status;
- (void)install;
- (void)message:(NSString *)text;
- (void)hide;
@end
