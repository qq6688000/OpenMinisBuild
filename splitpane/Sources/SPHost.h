// SPHost.h — 一个 App 的宿主：拿到它的活 scene，放进给定容器里渲染
// 路线按 PV 的口径排序，每一层都用 SPABI 校验真实 method 签名，拿不到就降级，绝不猜。
#import <UIKit/UIKit.h>
#import "SPCompat.h"

@interface SPHost : NSObject
@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, weak, readonly) UIView *containerView;
@property (nonatomic, assign, readonly) BOOL live;          // 活 scene 是否已经接上
@property (nonatomic, assign) BOOL snapshotActive;          // 是否退到了冻结快照

- (instancetype)initWithBundleID:(NSString *)bundleID;

// 把 scene 接进容器。失败返回 NO
- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene;

// 用一张已经冻结的画面垫底（系统收走后台 scene 时顶上，防黑屏）
- (void)installSnapshot:(UIImage *)snapshot;

// 容器尺寸变了：把参考尺寸推给远端 scene，让 App 真的重排
- (void)setFrameSize:(CGSize)size;

// 探活：活画面还在不在。掉了就叫 snapshotActive=YES
- (BOOL)refreshLiveness;

- (void)detach;

// --- SpringBoard 入口（多试几层） ---
+ (id)mainDisplaySceneManager;
+ (id)sceneHandleForBundleID:(NSString *)bundleID;
+ (id)applicationProxyForBundleID:(NSString *)bundleID;
+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL ok))completion;
+ (BOOL)activateApp:(NSString *)bundleID windowScene:(UIWindowScene *)scene completion:(void (^)(BOOL ok))completion;
@end