#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// SpringBoard-style app grid picker for choosing the secondary app.
@interface DPAppPicker : NSObject

- (void)presentInView:(UIView *)parent
            favorites:(NSArray<NSString *> *)favorites
            blacklist:(NSArray<NSString *> *)blacklist
           completion:(void (^)(NSString * _Nullable bundleID))completion;

- (void)dismissAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
