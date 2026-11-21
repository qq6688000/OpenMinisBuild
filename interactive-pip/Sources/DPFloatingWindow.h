#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPSceneHost;

/// Hosts a second app scene inside a draggable / resizable floating chrome.
@interface DPFloatingWindow : UIView

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly, nullable) DPSceneHost *sceneHost;
/// 场景 view 的原生挂载点（edge shelf 嵌入后按此挂回）。
@property (nonatomic, strong, readonly, nullable) UIView *contentContainer;
@property (nonatomic, assign) CGFloat contentOpacity;
@property (nonatomic, assign) CGFloat cornerRadiusValue;
@property (nonatomic, assign) BOOL showsBorder;
@property (nonatomic, assign, getter=isTiled) BOOL tiled;
@property (nonatomic, copy, nullable) void (^onSplit)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onClose)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFocus)(DPFloatingWindow *window);
@property (nonatomic, copy, nullable) void (^onFrameChanged)(DPFloatingWindow *window, CGRect frame);

- (instancetype)initWithBundleID:(NSString *)bundleID frame:(CGRect)frame;
- (void)attachSceneHost:(DPSceneHost *)host;
- (nullable DPSceneHost *)detachSceneHost;
- (void)commitSceneLayout;
/// Round the pane's own chrome + content container while in Duo split.
/// Never touches the hosted scene layer container's layer.
- (void)setSplitCardCornerRadius:(CGFloat)radius;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)bringToFront;
- (void)closeAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
