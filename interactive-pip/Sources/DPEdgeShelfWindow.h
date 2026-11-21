#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// 左侧竖向收纳卡。两种内容模式：
/// 实时——卡片直接嵌入场景 view（画面流动）；
/// 截图——卡片显示隐藏前截取的缩略图（省渲染）。
@interface DPEdgeShelfWindow : UIWindow
- (void)configureWithNames:(NSArray<NSString *> *)names
                     views:(nullable NSArray *)views
                   restore:(void (^)(NSUInteger index))restore
               cardLayout:(nullable void (^)(NSUInteger index, CGRect frame))cardLayout;
/// 截图模式：卡片用静态缩略图（0.7.68 路线）。
- (void)configureWithNames:(NSArray<NSString *> *)names
                    images:(nullable NSArray *)images
                   restore:(void (^)(NSUInteger index))restore;
@end
NS_ASSUME_NONNULL_END
