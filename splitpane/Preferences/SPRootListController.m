#import "vendor/include/Preferences/PSListController.h"
#import "vendor/include/Preferences/PSSpecifier.h"
#import <notify.h>
#import <spawn.h>
#import <math.h>

extern char **environ;

// 设置面板：所有键写在 com.seagull.splitpane 域，改完发 Darwin 通知让 SpringBoard 立刻生效。

static NSString *const SPDomain = @"com.seagull.splitpane";
static NSString *const SPChangeNotification = @"SplitPaneSettingsDidChange";

// 仅接受本面板声明的键；损坏的 plist/偏好不能变成任意 CFPreferences 写入。
static id SPPanelDefault(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return nil;
    return @{@"enabled": @YES, @"statusTapEntry": @YES, @"hookHomeGesture": @NO,
             @"fallbackPanEntry": @NO, @"showBanner": @YES,
             @"parkThreshold": @45, @"haptics": @YES}[key];
}

static id SPPanelValue(id value, NSString *key) {
    id fallback = SPPanelDefault(key);
    if (!fallback) return nil;
    if ([key isEqualToString:@"parkThreshold"]) {
        double d = 45.0;
        if ([value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
            d = [value doubleValue];
        } else if ([value isKindOfClass:[NSString class]]) {
            NSScanner *scanner = [NSScanner scannerWithString:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            if (![scanner scanDouble:&d] || !scanner.isAtEnd) return fallback;
        }
        if (!isfinite(d) || d <= 0) return fallback;
        if (d <= 1.0) d *= 100.0; // 兼容运行时已支持的旧比例值
        return @(MIN(MAX(d, 20.0), 80.0));
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        double d = [value doubleValue];
        return d == 0 ? @NO : (d == 1 ? @YES : fallback);
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if ([@[@"1", @"true", @"yes"] containsObject:s]) return @YES;
        if ([@[@"0", @"false", @"no"] containsObject:s]) return @NO;
    }
    return fallback;
}

@interface SPRootListController : PSListController
@end

@implementation SPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SplitPane";
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!SPPanelDefault(key)) return [specifier propertyForKey:@"default"];
    CFPreferencesAppSynchronize((__bridge CFStringRef)SPDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)SPDomain);
    return SPPanelValue(v ? (__bridge_transfer id)v : nil, key);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id normalized = SPPanelValue(value, key);
    if (!normalized) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)normalized,
                             (__bridge CFStringRef)SPDomain);
    if (CFPreferencesAppSynchronize((__bridge CFStringRef)SPDomain))
        notify_post(SPChangeNotification.UTF8String);
}

- (void)repairScenes {
    // 设置面板跑在自己的进程里，调不到 SpringBoard 的 SPRepair，
    // 所以发 Darwin 通知，让 SpringBoard 那边执行修复
    notify_post("com.seagull.splitpane.repair");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已发送修复"
                                                              message:@"正在把被压小的 App 画面恢复成全屏。"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)respring {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"注销主屏幕"
                                                              message:@"让改动完全生效？"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        pid_t pid;
        const char *args[] = {"sbreload", NULL};
        posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, (char *const *)args, environ);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
