#import "SPRepair.h"
#import "SPCompat.h"
#import "SPLog.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import "SPHost.h"

static NSString *gReport = nil;

// 只有 SPHost 在首次改动前保存过的 scene 才有恢复资格；不再凭宽高猜全系统半屏。
// scene 弱引用，避免修复台账反过来使已失效的 scene 常驻。
static NSMapTable *SPRepairRecords(void) {
    static NSMapTable *records;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        records = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                       valueOptions:NSPointerFunctionsStrongMemory];
    });
    return records;
}

NSDictionary *SPRepairOriginalSettingsForScene(id scene) {
    if (!scene) return nil;
    NSMapTable *records = SPRepairRecords();
    @synchronized (records) { return [records objectForKey:scene]; }
}

void SPRepairRecordSceneSettings(id scene, NSDictionary *settings) {
    if (!scene || !settings[@"frame"]) return;
    NSMapTable *records = SPRepairRecords();
    @synchronized (records) {
        // 多 owner 共享同一 scene 时必须保留第一份基准，不能记录已被托管改过的设置。
        if (![records objectForKey:scene]) [records setObject:[settings copy] forKey:scene];
    }
}

void SPRepairForgetScene(id scene) {
    if (!scene) return;
    NSMapTable *records = SPRepairRecords();
    @synchronized (records) { [records removeObjectForKey:scene]; }
}

BOOL SPRepairRestoreSceneGeometry(id scene, NSDictionary *original, NSString **diag) {
    if (diag) *diag = @"not-restored";
    if (![NSThread isMainThread] || !scene || !original[@"frame"]) return NO;
    // 不允许迟到的旧 host 覆盖新 host 的 frame/orientation。
    if (SPHostSceneIsHosted(scene)) { if (diag) *diag = @"still-hosted"; return NO; }
    @try {
        CGRect frame = [original[@"frame"] CGRectValue];
        if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
            !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
            frame.size.width < 2 || frame.size.height < 2) return NO;
        id settings = SPMsg0(scene, @"settings");
        id desired = SPMsg0(settings, @"mutableCopy");
        if (!SPABI(desired, @"setFrame:", "v", 1, @encode(CGRect))) return NO;
        SPVoidRect1(desired, @"setFrame:", frame);
        NSNumber *orientation = original[@"orientation"];
        if (orientation) {
            if (!SPABI(desired, @"setInterfaceOrientation:", "v", 1, @encode(NSInteger))) return NO;
            SPVoid1I(desired, @"setInterfaceOrientation:", orientation.integerValue);
        }
        // 不写 foreground/backgrounded/deactivationReasons/deviceOrientation；由系统决定前后台。
        id immutable = SPMsg0(desired, @"copy");
        if (!immutable) return NO;
        NSString *three = @"updateSettings:withTransitionContext:completion:";
        NSString *two = @"updateSettings:withTransitionContext:";
        if (SPABI(scene, three, "v", 3, "@", "@", "@")) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, NSSelectorFromString(three), immutable, nil, nil);
            if (diag) *diag = @"sent3";
            return YES;
        }
        if (SPABI(scene, two, "v", 2, "@", "@")) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, NSSelectorFromString(two), immutable, nil);
            if (diag) *diag = @"sent2";
            return YES;
        }
        if (diag) *diag = @"no-update-ABI";
    } @catch (NSException *e) {
        if (diag) *diag = [NSString stringWithFormat:@"ex %@", e.reason];
    }
    return NO;
}

@implementation SPRepair

+ (NSString *)lastReport {
    @synchronized (self) { return gReport ?: @"(none)"; }
}

+ (void)restoreAllScenes {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self restoreAllScenes]; });
        return;
    }
    NSMapTable *records = SPRepairRecords();
    NSArray *scenes;
    @synchronized (records) { scenes = records.keyEnumerator.allObjects; }
    NSUInteger fixed = 0, skipped = 0;
    NSMutableArray *rows = [NSMutableArray array];
    for (id scene in scenes) {
        if (SPHostSceneIsHosted(scene)) { skipped++; continue; }
        NSDictionary *original = SPRepairOriginalSettingsForScene(scene);
        NSString *diag = nil;
        if (SPRepairRestoreSceneGeometry(scene, original, &diag)) {
            fixed++;
            SPRepairForgetScene(scene);
        }
        [rows addObject:[NSString stringWithFormat:@"%@:%@", NSStringFromClass([scene class]), diag ?: @"failed"]];
    }
    NSString *report = [NSString stringWithFormat:@"tracked=%lu fixed=%lu hosted-skipped=%lu %@",
                        (unsigned long)scenes.count, (unsigned long)fixed, (unsigned long)skipped,
                        [rows componentsJoinedByString:@" "]];
    @synchronized (self) { gReport = report; }
    SPLog(@"repair: %@", report);
}

@end

// 诊断：把每个 scene 的真实状态打出来（尺寸/是否有效/是否有呈现者）
// 用来确认「拆窗后 App 灰屏」到底卡在哪一环，而不是靠猜。
void SPDumpScenes(const char *tag) {
    @try {
        Class mgrCls = NSClassFromString(@"FBSceneManager");
        id mgr = mgrCls ? SPMsg0(mgrCls, @"sharedInstance") : nil;
        SEL enumSel = NSSelectorFromString(@"enumerateScenesWithBlock:");
        if (!mgr || ![mgr respondsToSelector:enumSel]) { SPLog(@"dump %s: no mgr", tag); return; }
        NSMutableArray *rows = [NSMutableArray array];
        void (^block)(id) = ^(id scene) {
            @try {
                NSString *cls = NSStringFromClass([scene class]);
                id proc = SPMsg0(scene, @"clientProcess");
                NSString *bid = SPMsg0(proc, @"bundleIdentifier");
                if (![bid isKindOfClass:[NSString class]]) bid = @"?";
                id settings = SPMsg0(scene, @"settings");
                CGRect f = CGRectZero;
                SEL fGet = NSSelectorFromString(@"frame");
                if (settings && [settings respondsToSelector:fGet])
                    f = ((CGRect (*)(id, SEL))objc_msgSend)(settings, fGet);
                BOOL valid = SPBool0(scene, @"isValid");
                BOOL active = SPBool0(scene, @"isActive");
                id handle = SPMsg0(scene, @"handle");
                id view = SPMsg0(handle, @"sceneView");
                BOOL hasView = (view != nil) && SPBool0(view, @"window") != 0;
                [rows addObject:[NSString stringWithFormat:@"%@ %@ %.0fx%.0f v%d a%d view%@",
                                 bid, cls, f.size.width, f.size.height,
                                 (int)valid, (int)active, hasView ? @"Y" : @"n"]];
            } @catch (__unused NSException *e) {}
        };
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, enumSel, block);
        SPLog(@"dump %s: %@", tag, [rows componentsJoinedByString:@" | "]);
    } @catch (NSException *e) { SPLog(@"dump %s ex %@", tag, e.reason); }
}
