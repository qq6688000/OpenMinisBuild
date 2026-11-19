#import "vendor/include/Preferences/PSListController.h"
#import "vendor/include/Preferences/PSSpecifier.h"
#import <spawn.h>
#import <notify.h>
#import <roothide.h>

static BOOL DPValueForGestureKey(NSString *key, BOOL fallback) {
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.dualpane.tweak"));
    if (!val) return fallback;
    BOOL result = fallback;
    if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue(val);
    } else if ([(__bridge id)val respondsToSelector:@selector(boolValue)]) {
        result = [(__bridge id)val boolValue];
    }
    CFRelease(val);
    return result;
}

@interface DPRootListController : PSListController
@end

@implementation DPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"分屏助手";
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销"
                                                                   message:@"立即注销主屏幕？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        pid_t pid;
        const char *args[] = { "sbreload", NULL };
        NSString *sbreloadPath = jbroot(@"/usr/bin/sbreload");
        if (posix_spawn(&pid, sbreloadPath.fileSystemRepresentation, NULL, NULL, (char *const *)args, NULL) != 0) {
            const char *args2[] = { "killall", "-9", "SpringBoard", NULL };
            NSString *killallPath = jbroot(@"/usr/bin/killall");
            posix_spawn(&pid, killallPath.fileSystemRepresentation, NULL, NULL, (char *const *)args2, NULL);
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetSettings {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置设置"
                                                                   message:@"恢复所有设置为默认值？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSString *domain = @"com.dualpane.tweak";
        CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)domain,
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
        if (keys) {
            CFPreferencesSetMultiple(NULL, keys,
                                     (__bridge CFStringRef)domain,
                                     kCFPreferencesCurrentUser,
                                     kCFPreferencesAnyHost);
            CFRelease(keys);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        notify_post("com.dualpane.tweak/settings.changed");
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/blueskycrb/DualPane"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    NSArray *gestureKeys = @[
        @"gestureEdgeSwipe", @"gestureThreeFinger", @"gestureStatusBar",
        @"gestureHomeIndicator", @"gestureIconSwipeUp", @"gestureIconLongPress"
    ];
    if ([gestureKeys containsObject:key]) {
        BOOL edge = DPValueForGestureKey(@"gestureEdgeSwipe", NO);
        BOOL three = DPValueForGestureKey(@"gestureThreeFinger", NO);
        BOOL status = DPValueForGestureKey(@"gestureStatusBar", NO);
        BOOL home = DPValueForGestureKey(@"gestureHomeIndicator", NO);
        BOOL iconSwipe = DPValueForGestureKey(@"gestureIconSwipeUp", YES);
        BOOL iconLong = DPValueForGestureKey(@"gestureIconLongPress", YES);

        if ([key isEqualToString:@"gestureEdgeSwipe"]) edge = [value boolValue];
        if ([key isEqualToString:@"gestureThreeFinger"]) three = [value boolValue];
        if ([key isEqualToString:@"gestureStatusBar"]) status = [value boolValue];
        if ([key isEqualToString:@"gestureHomeIndicator"]) home = [value boolValue];
        if ([key isEqualToString:@"gestureIconSwipeUp"]) iconSwipe = [value boolValue];
        if ([key isEqualToString:@"gestureIconLongPress"]) iconLong = [value boolValue];

        NSMutableArray *enabled = [NSMutableArray array];
        if (edge) [enabled addObject:@0];
        if (three) [enabled addObject:@1];
        if (status) [enabled addObject:@2];
        if (home) [enabled addObject:@3];
        if (iconSwipe) [enabled addObject:@4];
        if (iconLong) [enabled addObject:@5];

        CFPreferencesSetAppValue(CFSTR("enabledGestures"),
                                 (__bridge CFPropertyListRef)enabled,
                                 CFSTR("com.dualpane.tweak"));
        CFPreferencesAppSynchronize(CFSTR("com.dualpane.tweak"));
        notify_post("com.dualpane.tweak/settings.changed");
    }
}

@end
