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


// 让 App 的 scene 真正出画面，需要同时改两处：scene settings 的前台标记、
// 以及 App 进程自己的「我在前台」状态。先探测后者有没有可用接口。
void SPProbeForegroundAPI(void) {
    NSMutableArray *rows = [NSMutableArray array];
    Class appCls = NSClassFromString(@"SBApplication");
    if (appCls) {
        for (NSString *sel in @[@"setProcessState:", @"processState", @"isFrontmost",
                                @"setIsFrontmost:", @"_setProcessState:"]) {
            [rows addObject:[NSString stringWithFormat:@"%@=%@", sel,
                             [appCls instancesRespondToSelector:NSSelectorFromString(sel)] ? @"Y" : @"n"]];
        }
    } else {
        [rows addObject:@"SBApplication=n"];
    }
    Class proc = NSClassFromString(@"FBProcess");
    if (proc) {
        for (NSString *sel in @[@"setTaskState:", @"taskState", @"setVisibility:", @"visibility"]) {
            [rows addObject:[NSString stringWithFormat:@"FBProcess.%@=%@", sel,
                             [proc instancesRespondToSelector:NSSelectorFromString(sel)] ? @"Y" : @"n"]];
        }
    }
    SPLog(@"foreground probe: %@", [rows componentsJoinedByString:@" | "]);
}

// 0.5.4：真正的入口方法全量 dump —— 关键字匹配 shortcut / activate / launch / Menu / Tap
static void SPDumpIconMethods(Class cls, NSString *tag) {
    if (!cls) return;
    NSMutableArray *hits = [NSMutableArray array];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        if (!nm) continue;
        NSString *s = @(nm);
        for (NSString *k in @[@"hortcut", @"ctivate", @"aunch", @"Menu", @"Tap", @"Press"]) {
            if ([s rangeOfString:k].location != NSNotFound) { [hits addObject:s]; break; }
        }
    }
    free(ms);
    NSMutableArray *uniq = [NSMutableArray array];
    for (NSString *s in hits) if (![uniq containsObject:s]) [uniq addObject:s];
    SPLog(@"%@ methods(%lu): %@", tag, (unsigned long)uniq.count,
          [uniq componentsJoinedByString:@" | "]);
}

void SPDumpIconEntryPoints(void) {
    @try {
        SPDumpIconMethods(NSClassFromString(@"SBIconView"), @"SBIconView");
        SPDumpIconMethods(NSClassFromString(@"SBIconController"), @"SBIconController");
        SPDumpIconMethods(NSClassFromString(@"SBHIconManager"), @"SBHIconManager");
        SPDumpIconMethods(NSClassFromString(@"SBApplication"), @"SBApplication");
    } @catch (NSException *e) { SPLog(@"dump ex %@", e.reason); }
}
