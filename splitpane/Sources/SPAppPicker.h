// SPAppPicker.h — 选第二个 App
// 优先用 SpringBoard 自己的图标网格（跟主屏长得一模一样），拿不到就退回到自绘的 App 列表。
#import <UIKit/UIKit.h>

@interface SPAppPicker : NSObject
// 弹出选择面板。选择回调可为 nil（分屏进行中再次上滑，只想换上面的 App）
+ (void)presentFromWindowScene:(UIWindowScene *)scene bundleIDs:(NSArray *)extra
                        onPick:(void (^)(NSString *bundleID))onPick
                      onCancel:(void (^)(void))onCancel;
+ (BOOL)isPresenting;
+ (void)cancelIfPresent;
@end