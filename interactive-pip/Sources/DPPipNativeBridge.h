#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 0.7.215: 严格照 PanoramicView 的 PiP 方式挂起 App。
///
/// PV 1.0.16 二进制里的真实链路（cstring 交叉验证）：
///   SBPIPControllerCoordinator  -controllerForType:
///   SBPIPController             -addContainerViewController:dataSource:
///                               -removeContainerViewController:
///                               -contentViewController
///   SBPIPContainerViewController  ← 真正托管 App 的容器
///
/// 本类只做一件事：探测这条链在本机（iOS 16.4.1）是否可用，并把每一步
/// 的真实结果打进 split.txt。探测清楚再决定接哪一步，不猜。
@interface DPPipNativeBridge : NSObject

+ (instancetype)shared;

/// 走 PV 的 coordinator → controllerForType: → controller 链路
/// 返回 SDK 侧拿到的 SBPIPController 对象（拿不到 nil）
- (nullable id)resolvePipController;

/// 探测 controller 上所有与容器相关的方法签名（不调用会崩的那些）
- (void)dumpPipControllerCapabilities:(nullable id)controller;

/// 尝试按 PV 的方式把自己的内容交给 PiP 容器
/// container 必须是 SBPIPContainerViewController 实例，否则返回 NO
- (BOOL)attachContentViewController:(UIViewController *)vc
                       toContainer:(id)container
                          bundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END