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
// 0.7.93: FBSceneManager enumerate diagnostics (enum=scan=N match=M/<class>).
@property (nonatomic, copy, readonly, nullable) NSString *reflowEnumDiag;
// 0.7.94: trace of the scene-handle reverse lookup (which manager resolved it).
@property (nonatomic, copy, readonly, nullable) NSString *reflowHandleDiag;
// 0.7.95: selector surface of the scene / resolved handle (real APIs available).
@property (nonatomic, copy, readonly, nullable) NSString *reflowMethodsDiag;
// 0.7.102: whether the growing pane was re-submitted to FBScene.settings.
@property (nonatomic, copy, readonly, nullable) NSString *reflowCanvasDiag;
@property (nonatomic, copy, readonly, nullable) NSString *layerDiag;
@property (nonatomic, copy, readonly, nullable) NSString *layoutDiag;
- (void)setSuspended:(BOOL)suspended;
/// 实时重排：按当前窗格尺寸重设 host referenceSize（设置开关控制）。
- (void)tryLiveReflow;
/// 设置切换后重置 reflow 状态并重新尝试。
- (void)resetLiveReflow;
/// 静态侧栏模式停/复场景音频（不动进程断言）。
- (void)setSceneAudible:(BOOL)audible;
- (void)retryAttach;
- (void)invalidate;
/// App 大图标（edge shelf 卡片占位用）。
- (nullable UIImage *)iconImageLarge;

@end

NS_ASSUME_NONNULL_END
