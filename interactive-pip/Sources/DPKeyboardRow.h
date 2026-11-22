#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A tiny self-drawn keyboard row. SpringBoard refuses to route the system
/// keyboard to third-party windows, so the app picker types with this instead.
@interface DPKeyboardRow : UIView

/// Called with the updated query string on every key press.
@property (nonatomic, copy, nullable) void (^onQueryChanged)(NSString *query);
@property (nonatomic, copy, readonly) NSString *query;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
