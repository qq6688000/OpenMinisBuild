#import <UIKit/UIKit.h>

// 自建窗口统一登记 + 兜底回收。
// 唯一的用途：万一某条退出路径漏了，killAll 能把它收掉
// （只 hidden 不释放的窗口会在桌面上留隐形窗户挡点击）。
@interface SPWindowRegistry : NSObject
+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level;
+ (void)releaseWindow:(UIWindow *)w;
+ (void)killAll;
+ (NSUInteger)count;
@end
