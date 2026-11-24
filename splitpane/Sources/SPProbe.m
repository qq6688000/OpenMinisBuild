#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "SPLog.h"
#import "SPCompat.h"
#import "SPHost.h"
#import "SPGesture.h"

// 开机自检：把「这个环境长什么样」一次性写进日志。
// 之后用户只要把日志发过来，不用再猜是哪一层断的。

static NSString *SPClassProbe(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) return @"-";
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    free(ms);
    return [NSString stringWithFormat:@"+%u", n];
}

static NSString *SPSelProbe(Class c, NSString *sel) {
    if (!c) return @"-";
    return [c instancesRespondToSelector:NSSelectorFromString(sel)] ? @"Y" : @"n";
}

void SPWriteEnvironmentProbe(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"env uid=%d home=%@ arch=", getuid(), NSHomeDirectory()];
#if defined(__arm64e__)
    [s appendString:@"arm64e"];
#else
    [s appendString:@"arm64"];
#endif
    [s appendFormat:@" sysname=%@", [[NSProcessInfo processInfo] operatingSystemVersionString]];

    NSMutableArray *found = [NSMutableArray array];
    for (NSString *n in @[@"SBHomeGesturePanGestureRecognizer",
                          @"SBSceneManagerCoordinator", @"SBMainDisplaySceneManager",
                          @"SBApplicationController", @"SBSceneView", @"SBDeviceApplicationSceneHandle",
                          @"SBMainSwitcherControllerCoordinator", @"SBUIController",
                          @"SBFluidSwitcherViewController", @"SBIconController"]) {
        [found addObject:[NSString stringWithFormat:@"%@%@", n, SPClassProbe(n)]];
    }
    SPLog(@"env classes: %@", [found componentsJoinedByString:@" "]);

    Class handle = NSClassFromString(@"SBDeviceApplicationSceneHandle");
    Class sbscene = NSClassFromString(@"SBSceneView");
    SPLog(@"env sceneView factories: newSceneViewWithReferenceSize=%@ createSceneView...=%@ initViewWithScene=%@",
          SPSelProbe(handle, @"newSceneViewWithReferenceSize:"),
          SPSelProbe(handle, @"createSceneViewWithReferenceSize:withContentOrientation:andContainerOrientation:configuration:"),
          SPSelProbe(sbscene, @"initWithScene:"));

    id mgr = [SPHost mainDisplaySceneManager];
    SPLog(@"env mainDisplaySceneManager=%@ (%@)", mgr ? NSStringFromClass([mgr class]) : @"nil",
          mgr ? @"ok" : @"FAIL");

    if (mgr) {
        NSArray *scenes = SPMsg0(mgr, @"allScenes");
        SPLog(@"env allScenes count=%lu", (unsigned long)([scenes isKindOfClass:[NSArray class]] ? scenes.count : 0));
    }

    Class ac = NSClassFromString(@"SBApplicationController");
    id ctrl = ac ? SPMsg0(ac, @"sharedInstance") : nil;
    NSArray *apps = SPMsg0(ctrl, @"allApplications");
    SPLog(@"env SBApplicationController=%@ allApplications=%lu", ctrl ? @"ok" : @"nil",
          (unsigned long)([apps isKindOfClass:[NSArray class]] ? apps.count : 0));

    NSMutableArray *wins = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [wins addObject:[NSString stringWithFormat:@"%.0f:%@", w.windowLevel,
                         NSStringFromClass(w.class)]];
    }
    SPLog(@"env windows: %@", [wins componentsJoinedByString:@", "]);

    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    SPLog(@"env homePress=%@", (ui && [ui respondsToSelector:NSSelectorFromString(@"handleHomeButtonSinglePressUp")]) ? @"Y" : @"n");
}