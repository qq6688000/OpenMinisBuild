#import <UIKit/UIKit.h>
#import "SPCompat.h"

// scene view 工厂要的 requester：FrontBoard 会回调这两个方法。
// 传字符串会让工厂 100% 失败（Duo 0.7.79 实证），必须给真实对象。
@interface SPHostRequester : NSObject
@property (nonatomic, copy) NSString *presentationIdentifier;
@end

@interface SPHost : NSObject
@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, weak, readonly) UIView *containerView;
@property (nonatomic, assign, readonly) BOOL live;
@property (nonatomic, assign) BOOL snapshotActive;
@property (nonatomic, copy) NSString *lastDiag;

- (instancetype)initWithBundleID:(NSString *)bundleID;
- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene;
- (void)attachWhenReady:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                attempts:(NSInteger)attempts interval:(NSTimeInterval)interval;
- (void)installSnapshot:(UIImage *)snapshot;
- (void)setFrameSize:(CGSize)size;
- (BOOL)refreshLiveness;
- (void)detach;
// 把 scene 的 settings 恢复成接管之前的样子（退出分屏时必做，否则 App 保持半屏尺寸→黑屏）
- (void)restoreOriginalSceneSettings;

+ (id)mainDisplaySceneManager;
+ (id)applicationProxyForBundleID:(NSString *)bundleID;
+ (id)fbSceneForBundleID:(NSString *)bundleID;
+ (id)sceneHandleForScene:(id)scene;
+ (BOOL)openAppAsync:(NSString *)bundleID completion:(void (^)(BOOL ok))completion;
// 把 App 退到后台（不杀进程）
+ (BOOL)suspendAppToBackground:(NSString *)bundleID;
+ (BOOL)homePress;
// 只做激活（毫秒级，不启动进程），用来让 App 自己重排成全屏
+ (void)reactivateApp:(NSString *)bundleID;
+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL ok))completion;
+ (BOOL)activateApp:(NSString *)bundleID windowScene:(UIWindowScene *)scene completion:(void (^)(BOOL ok))completion;
+ (BOOL)homePress;
+ (NSString *)homePressDiag;
@end