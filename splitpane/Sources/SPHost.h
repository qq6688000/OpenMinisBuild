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

+ (id)mainDisplaySceneManager;
+ (id)applicationProxyForBundleID:(NSString *)bundleID;
+ (id)fbSceneForBundleID:(NSString *)bundleID;
+ (id)sceneHandleForScene:(id)scene;
+ (BOOL)openAppAsync:(NSString *)bundleID completion:(void (^)(BOOL ok))completion;
+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL ok))completion;
+ (BOOL)activateApp:(NSString *)bundleID windowScene:(UIWindowScene *)scene completion:(void (^)(BOOL ok))completion;
+ (BOOL)homePress;
+ (NSString *)homePressDiag;
@end