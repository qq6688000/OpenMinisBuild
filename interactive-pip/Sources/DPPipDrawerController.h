#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 0.7.212: 照 PanoramicView 的上滑挂起机制 —— 系统 PiP 容器 + 贴边抽屉。
///
/// PV 的真实做法（从 1.0.16 dylib 挖出）：
///   SBPIPContainerViewController   ← 系统画中画容器，PV 用它托管挂起的 App
///   pictureInPictureContainerViewController / contentViewController
///   SBSlideOverTongueView          ← 贴边小条（拖动切换）
///   PVDrawerHomeGrabber            ← 从 Home 指示条抓取
///   drawerPanHandler / drawerCanBegin / trackingFullscreenDrawer
///
/// 本类只做「贴边抽屉」这一层：把挂起的 App 视图容器缩成一条贴在屏幕边缘的
/// 小条，点/拖它展开。是否真的用系统 PiP 容器由 DPSceneHost 决定（见 pipContainer）。
@interface DPPipDrawerController : NSObject

+ (instancetype)shared;

/// 抽屉是否已挂起
@property (nonatomic, readonly, getter=isParked) BOOL parked;

/// 挂起：把 contentView 收进抽屉，贴到 edge（1=右侧 2=左侧 3=顶部）
- (BOOL)parkContentView:(UIView *)contentView
              inHostView:(UIView *)hostView
                   edge:(NSInteger)edge
             bundleID:(nullable NSString *)bundleID;

/// 展开抽屉（恢复到正常尺寸）
- (void)unparkAnimated:(BOOL)animated;

/// 完全移除
- (void)tearDown;

/// 抽屉贴边条视图（便于外部布局/命中测试）
@property (nonatomic, readonly, nullable) UIView *tongueView;

/// 0.7.213: 系统 PiP 容器接管路径（PV 的 PVPIPEmbedding 等价物）
/// 返回 nil 表示本机/iOS 版本不支持，调用方回退到自有 window 托管。
- (nullable id)makeSystemPiPContainerForBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
