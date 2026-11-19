#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPSceneHost;

/// Hosts a second app scene inside a draggable / resizable floating chrome.
@interface DPFloatingWindow : UIView

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly, nullable) DPSceneHost *sceneHost;
@property (nonatomic, assign) CGFloat contentOpacity;
@property (nonatomic, assign) CGFloat cornerRadiusValue;
@property (nonatomic, assign) BOOL showsBorder;
@property (nonatomic, copy, nullable) void (^onClose)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFocus)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFrameChanged)(DPFloatingWindow *window, CGRect frame);

- (instancetype)initWithBundleID:(NSString *)bundleID frame:(CGRect)frame;
- (void)attachSceneHost:(DPSceneHost *)host;
- (nullable DPSceneHost *)detachSceneHost;
- (void)commitSceneLayout;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)bringToFront;
- (void)closeAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
