#import "SPSettings.h"

NSString *const SPNotifyChanged = @"SplitPaneSettingsDidChange";
static NSString *const SPDomain = @"com.seagull.splitpane";

static void SPSettingsDarwinCallback(CFNotificationCenterRef center, void *observer,
                                    CFNotificationName name, const void *object,
                                    CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SPNotifyChanged object:nil];
    });
}

@implementation SPSettings

static id SPPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)SPDomain);
    if (!v) return nil;
    id obj = (__bridge_transfer id)v;
    return obj;
}

static BOOL SPBoolValue(NSString *key, BOOL fallback) {
    id v = SPPref(key);
    if (!v) return fallback;
    if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
        return CFBooleanGetValue((__bridge CFBooleanRef)v);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

static double SPPrefDouble(NSString *key, double fallback) {
    id v = SPPref(key);
    if (!v) return fallback;
    double d = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
    return d > 0 ? d : fallback;
}

+ (BOOL)enabled { return SPBoolValue(@"enabled", YES); }
+ (BOOL)swapOnSecondSwipe { return SPBoolValue(@"swapOnSecondSwipe", YES); }
+ (BOOL)haptics { return SPBoolValue(@"haptics", YES); }
+ (BOOL)keepSnapshots { return SPBoolValue(@"keepSnapshots", YES); }
+ (double)seamThickness { return SPPrefDouble(@"seamThickness", 34.0); }
+ (BOOL)bannerEnabled { return SPBoolValue(@"showBanner", YES); }
+ (BOOL)hooksEnabled { return SPBoolValue(@"hookHomeGesture", NO); }
+ (BOOL)statusTapEnabled { return SPBoolValue(@"statusTapEntry", YES); }
+ (BOOL)fallbackPanEnabled { return SPBoolValue(@"fallbackPanEntry", NO); }
+ (double)parkThreshold {
    // 设置面板的滑杆写的是 20..80 的整数（百分比），这里统一归一到 0.20..0.80
    double v = SPPrefDouble(@"parkThreshold", 45.0);
    if (v > 1.0) v /= 100.0;
    return MIN(MAX(v, 0.20), 0.85);
}

+ (void)startObserving {
    NSNotificationCenter *__weak wc = [NSNotificationCenter defaultCenter];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        [wc postNotificationName:SPNotifyChanged object:nil];
    }];

    // 设置面板改完 → Darwin 通知跨进程送到 SpringBoard
    static char token;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    &token, SPSettingsDarwinCallback,
                                    (__bridge CFStringRef)SPNotifyChanged,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

@end