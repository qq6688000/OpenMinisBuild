// SPParkCard.h — 上滑后停在底部的「挂起卡片」
// 与 PV 的差别：PV 把当前 App 的活 scene 挂成一张卡；这台机器上后台 scene 会被系统收回
// （Duo 反复实测），所以这里只放冻结快照。点一下 → 拉起来进入分屏。
#import <UIKit/UIKit.h>

@class SPParkCard;

@protocol SPParkCardDelegate <NSObject>
- (void)parkCardDidTap:(SPParkCard *)card;
@end

@interface SPParkCard : UIView
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, weak) id<SPParkCardDelegate> delegate;
- (instancetype)initWithSnapshot:(UIImage *)image bundleID:(NSString *)bundleID name:(NSString *)name;
- (void)presentInWindowScene:(UIWindowScene *)scene fromRect:(CGRect)fromRect completion:(void (^)(void))completion;
- (void)dismissAnimated:(void (^)(void))completion;
// 立刻清理所有还活着的卡片窗口（不做动画）。分屏建立/退出时必调，
// 否则卡片的独立 window 会留在桌面上挡点击。
+ (void)dismissAll;
@end