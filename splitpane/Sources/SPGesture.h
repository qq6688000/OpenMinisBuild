// SPGesture.h — 入口层：底部上滑挂起 / 状态栏双击兜底
#import <UIKit/UIKit.h>

@interface SPGesture : NSObject
@property (class, readonly) SPGesture *shared;
@property (nonatomic, assign) BOOL hooksAvailable;   // 系统手势钩子是否装上
- (void)installInWindowScene:(UIWindowScene *)scene;
- (void)handleHomePanBegan:(CGPoint)loc;
- (void)cancelTracking;
- (void)handleHomePanMoved:(CGPoint)loc;
- (BOOL)consumeHomePan:(UIPanGestureRecognizer *)pan translation:(CGPoint)translation velocity:(CGPoint)velocity;
@end
