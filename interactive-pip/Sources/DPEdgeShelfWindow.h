#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// 左侧竖向收纳卡。卡片内容直接嵌入外部 view（实时画面），非静态截图。
@interface DPEdgeShelfWindow : UIWindow
- (void)configureWithNames:(NSArray<NSString *> *)names
                     views:(nullable NSArray *)views
                   restore:(void (^)(NSUInteger index))restore
               cardLayout:(nullable void (^)(NSUInteger index, CGRect frame))cardLayout;
@end
NS_ASSUME_NONNULL_END
