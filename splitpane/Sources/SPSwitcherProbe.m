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

// 主屏图标长按菜单探针：拿到真实接口再写功能，不猜。
void SPProbeIconMenu(void) {
    NSMutableArray *rows = [NSMutableArray array];
    Class iv = NSClassFromString(@"SBIconView");
    if (!iv) { SPLog(@"icon menu probe: SBIconView=n"); return; }
    // 是否是 UIContextMenuInteraction 的 delegate
    for (NSString *sel in @[@"contextMenuInteraction:configurationForMenuAtLocation:",
                            @"contextMenuInteraction:configuration:highlightPreviewForItemWithIdentifier:",
                            @"_contextMenuInteraction:styleForMenuWithConfiguration:",
                            @"iconView:contextMenuConfigurationForIcon:",
                            @"providerForIconView:"]) {
        [rows addObject:[NSString stringWithFormat:@"%@=%@", sel,
                         [iv instancesRespondToSelector:NSSelectorFromString(sel)] ? @"Y" : @"n"]];
    }
    // 相关类
    for (NSString *cls in @[@"SBIconViewConfigurationOption", @"SBHIconManager",
                            @"SBIconViewContextMenuElement", @"SBIconViewAction"]) {
        [rows addObject:[NSString stringWithFormat:@"%@=%@", cls, NSClassFromString(cls) ? @"Y" : @"n"]];
    }
    SPLog(@"icon menu probe: %@", [rows componentsJoinedByString:@" | "]);
}
