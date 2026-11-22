#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 把目标 App 的画面嵌进 UIView。
/// 使用 iOS scene layer container / FBSceneHostManager 嵌入实时画面。
@interface DPSceneHost : NSObject

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly) UIView *view;
@property (nonatomic, assign, readonly, getter=isLive) BOOL live;
@property (nonatomic, copy, readonly, nullable) NSString *statusText;

+ (BOOL)isSceneHostingAvailable;

- (instancetype)initWithBundleID:(NSString *)bundleID;
- (void)setHostedFrame:(CGRect)frame;
- (void)commitHostedFrame;
- (void)prepareForInput;
- (nullable UIView *)keyboardRoutingView;
- (nullable id)keyboardRoutingScene;
- (int)keyboardRoutingPID;
@property (nonatomic, assign, readonly) BOOL keyboardHostIsSceneView;
@property (nonatomic, copy, readonly, nullable) NSString *hostViewDiag;
@property (nonatomic, copy, readonly, nullable) NSString *layerDiag;
@property (nonatomic, copy, readonly, nullable) NSString *layoutDiag;
- (void)setSuspended:(BOOL)suspended;
- (void)retryAttach;
- (void)invalidate;
// 0.7.115: force the reflow host to rebuild at the current pane size.
- (void)forceReflowRebuild;

@end

NS_ASSUME_NONNULL_END
