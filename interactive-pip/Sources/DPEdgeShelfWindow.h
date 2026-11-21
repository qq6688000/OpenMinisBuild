#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface DPEdgeShelfWindow : UIWindow
- (void)configureWithNames:(NSArray<NSString *> *)names
                    images:(nullable NSArray *)images
                   restore:(void (^)(NSUInteger index))restore;
@end
NS_ASSUME_NONNULL_END
