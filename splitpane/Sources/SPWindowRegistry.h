#import <UIKit/UIKit.h>

// 所有自建 UIWindow 统一登记。任何一个漏掉释放都会在桌面上挡点击，
// 所以统一收口：建的时候登记，销毁时注销，另有 killAll 兜底。
@interface SPWindowRegistry : NSObject
+ (UIWindow *)makeWindowWithScene:(UIWindowScene *)scene level:(CGFloat)level keyable:(BOOL)keyable;
+ (void)releaseWindow:(UIWindow *)w;
+ (void)killAll;
+ (NSUInteger)count;
@end
