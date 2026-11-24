#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "SPCompat.h"
#import "SPLog.h"

// 只探测、不修改：确认这台机器的切换器是否具备做「分屏卡片」的接口。
// 结果写进日志，用来决定下一步走哪条路（而不是凭猜写一大坨）。
void SPProbeSwitcherAPI(void) {
    NSMutableArray *rows = [NSMutableArray array];

    // 1) 内容视图提供者：切换器给每个 layout 生成画面的地方
    Class provider = NSClassFromString(@"SBFluidSwitcherPageContentViewProvider");
    if (provider) {
        SEL sel = NSSelectorFromString(@"pageContentViewForAppLayout:setActive:");
        [rows addObject:[NSString stringWithFormat:@"provider=Y pageContentViewForAppLayout=%@",
                         [provider instancesRespondToSelector:sel] ? @"Y" : @"n"]];
    } else {
        [rows addObject:@"provider=n"];
    }

    // 2) 切换器主控制器
    for (NSString *cls in @[@"SBFluidSwitcherViewController", @"SBMainSwitcherControllerCoordinator"]) {
        Class c = NSClassFromString(cls);
        if (!c) { [rows addObject:[NSString stringWithFormat:@"%@=n", cls]]; continue; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        free(ms);
        [rows addObject:[NSString stringWithFormat:@"%@=Y(%u)", cls, n]];
    }

    // 3) SBAppLayout 工厂
    Class layout = NSClassFromString(@"SBAppLayout");
    if (layout) {
        BOOL two = [layout respondsToSelector:NSSelectorFromString(@"initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:")];
        [rows addObject:[NSString stringWithFormat:@"SBAppLayout=Y twoItem=%d", two]];
    } else {
        [rows addObject:@"SBAppLayout=n"];
    }

    // 4) 页面视图
    for (NSString *cls in @[@"SBAppSwitcherPageView", @"SBHomeScreenController"]) {
        [rows addObject:[NSString stringWithFormat:@"%@=%@", cls, NSClassFromString(cls) ? @"Y" : @"n"]];
    }

    SPLog(@"switcher probe: %@", [rows componentsJoinedByString:@" | "]);
}
