#import "vendor/include/Preferences/PSListController.h"
#import "vendor/include/Preferences/PSSpecifier.h"
#import <notify.h>
#import <spawn.h>

extern char **environ;

// 设置面板：所有键写在 com.seagull.splitpane 域，改完发 Darwin 通知让 SpringBoard 立刻生效。

static NSString *const SPDomain = @"com.seagull.splitpane";
static NSString *const SPChangeNotification = @"SplitPaneSettingsDidChange";

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
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)SPDomain);
    if (!v) return [specifier propertyForKey:@"default"];
    return (__bridge_transfer id)v;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)SPDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)SPDomain);
    notify_post(SPChangeNotification.UTF8String);
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
