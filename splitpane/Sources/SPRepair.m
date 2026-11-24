#import "SPRepair.h"
#import "SPCompat.h"
#import "SPLog.h"
#import <UIKit/UIKit.h>
#import <math.h>

static NSString *gReport = nil;

// 只修「宽度等于屏幕宽、但高度不到屏幕一半」的 scene ——
// 这是我们半屏分屏留下的特征，横屏/合法小窗不会命中，避免误伤。
@implementation SPRepair

+ (NSString *)lastReport { return gReport ?: @"(none)"; }

+ (void)restoreAllScenes {
    NSMutableString *r = [NSMutableString string];
    @try {
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        id mgr = mgrCls ? SPMsg0(mgrCls, @"sharedInstance") : nil;
        SEL enumSel = NSSelectorFromString(@"enumerateScenesWithBlock:");
        if (!mgr || ![mgr respondsToSelector:enumSel]) {
            gReport = @"no FBSceneManager";
            return;
        }
        CGRect screen = [UIScreen mainScreen].bounds;
        __block NSUInteger fixed = 0, scanned = 0;
        void (^block)(id) = ^(id scene) {
            @try {
                scanned++;
                if (!scene) return;
                id settings = SPMsg0(scene, @"settings");
                if (!settings) return;
                SEL fGet = NSSelectorFromString(@"frame");
                if (![settings respondsToSelector:fGet]) return;
                CGRect f = ((CGRect (*)(id, SEL))objc_msgSend)(settings, fGet);
                // 特征匹配：宽度≈屏幕宽，高度只有屏幕的 25%~60%（半屏分屏的痕迹）
                if (f.size.width < 2) return;
                if (fabs(f.size.width - screen.size.width) > 40) return;
                CGFloat ratio = f.size.height / screen.size.height;
                if (ratio >= 0.75 || ratio < 0.20) return;
                id desired = SPMsg0(settings, @"mutableCopy");
                if (!desired) return;
                SEL setF = NSSelectorFromString(@"setFrame:");
                if (![desired respondsToSelector:setF]) return;
                ((void (*)(id, SEL, CGRect))objc_msgSend)(desired, setF,
                    CGRectMake(0, 0, screen.size.width, screen.size.height));
                SEL ioGet = NSSelectorFromString(@"interfaceOrientation");
                if ([settings respondsToSelector:ioGet]) {
                    NSInteger ori = ((NSInteger (*)(id, SEL))objc_msgSend)(settings, ioGet);
                    SEL setIO = NSSelectorFromString(@"setInterfaceOrientation:");
                    if ([desired respondsToSelector:setIO])
                        ((void (*)(id, SEL, NSInteger))objc_msgSend)(desired, setIO, ori);
                }
                // 同样不动前台状态：修复只修尺寸
                id imm = SPMsg0(desired, @"copy");
                SEL upd = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
                SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
                if (imm && [scene respondsToSelector:upd]) {
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd, imm, nil, nil);
                    fixed++;
                } else if (imm && [scene respondsToSelector:upd2]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(scene, upd2, imm, nil);
                    fixed++;
                }
                [r appendFormat:@"%@ %.0fx%.0f→full ", NSStringFromClass([scene class]),
                 f.size.width, f.size.height];
            } @catch (__unused NSException *e) {}
        };
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, enumSel, block);
        SPLog(@"repair: scanned=%lu fixed=%lu %@", (unsigned long)scanned, (unsigned long)fixed, r);
        gReport = [NSString stringWithFormat:@"scanned=%lu fixed=%lu %@", (unsigned long)scanned, (unsigned long)fixed, r];
    } @catch (NSException *e) {
        gReport = [NSString stringWithFormat:@"ex %@", e.reason];
        SPLog(@"repair ex %@", e.reason);
    }
}

@end
