#import "DPPipNativeBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 复用 DPWindowManager 的日志通道（同一文件，避免循环依赖）
extern void DPPipLog(NSString *line);

static id DPCall(id obj, NSString *selName, NSArray *args) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count; i++) {
        NSUInteger idx = i + 2;
        if (idx >= sig.numberOfArguments) break;
        const char *t = [sig getArgumentTypeAtIndex:idx];
        id a = args[i];
        if (a == [NSNull null]) continue;
        if (t[0] == '@') { id v = a; [inv setArgument:&v atIndex:idx]; }
        else if (t[0] == 'q' || t[0] == 'l') { long v = [a longValue]; [inv setArgument:&v atIndex:idx]; }
        else if (t[0] == 'i') { int v = [a intValue]; [inv setArgument:&v atIndex:idx]; }
        else if (t[0] == 'Q' || t[0] == 'L') { unsigned long v = [a unsignedLongValue]; [inv setArgument:&v atIndex:idx]; }
        else if (t[0] == 'B') { BOOL v = [a boolValue]; [inv setArgument:&v atIndex:idx]; }
        else { id v = a; [inv setArgument:&v atIndex:idx]; }
    }
    @try { [inv invoke]; } @catch (NSException *e) {
        DPPipLog([NSString stringWithFormat:@"PIP CALL EX -%@ -> %@: %@", selName, e.name, e.reason]);
        return nil;
    }
    const char *rt = sig.methodReturnType;
    if (rt[0] != 'v' && rt[0] != '@') return @(1);
    if (rt[0] == '@') { id out = nil; [inv getReturnValue:&out]; return out; }
    return nil;
}

@implementation DPPipNativeBridge

+ (instancetype)shared {
    static DPPipNativeBridge *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [DPPipNativeBridge new]; });
    return inst;
}

- (id)resolvePipController {
    Class coordCls = NSClassFromString(@"SBPIPControllerCoordinator");
    Class pipCls = NSClassFromString(@"SBPIPController");
    Class containerCls = NSClassFromString(@"SBPIPContainerViewController");
    DPPipLog([NSString stringWithFormat:@"PIP classes: coordinator=%d controller=%d container=%d",
              coordCls != Nil, pipCls != Nil, containerCls != Nil]);
    if (!coordCls) return nil;

    // 0.7.217: 把 coordinator / controller 的类方法名全部打进日志，找真实访问器
    for (Class c in @[coordCls, pipCls ?: NSObject.class]) {
        if (!c) continue;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(object_getClass(c), &n);
        NSMutableString *names = [NSMutableString string];
        for (unsigned int i = 0; i < n && i < 40; i++) {
            [names appendFormat:@"%@,", NSStringFromSelector(method_getName(ms[i]))];
        }
        free(ms);
        DPPipLog([NSString stringWithFormat:@"PIP %@ class-methods: %@",
                  NSStringFromClass(c), names]);
    }

    // 1) 拿 coordinator 单例（PV 也走 sharedInstance）
    id coord = nil;
    for (NSString *n in @[@"sharedInstance", @"sharedCoordinator", @"shared",
                          @"sharedInstanceIfExists", @"defaultCoordinator"]) {
        coord = DPCall(coordCls, n, @[]);
        if (coord) { DPPipLog([NSString stringWithFormat:@"PIP coordinator via +%@ -> %@", n,
                              NSStringFromClass(object_getClass(coord))]); break; }
    }
    // coordinator 可能是实例方法
    if (!coord && [coordCls instancesRespondToSelector:NSSelectorFromString(@"sharedInstance")]) {
        coord = DPCall([coordCls new], @"sharedInstance", @[]);
    }
    if (!coord) { DPPipLog(@"PIP coordinator NOT FOUND"); }
    // 0.7.217: 即使拿不到 coordinator，也直接从 SBPIPController 类本身试单例
    if (!coord && pipCls) {
        for (NSString *n in @[@"sharedInstance", @"shared", @"defaultController",
                              @"sharedInstanceIfExists"]) {
            id c = DPCall(pipCls, n, @[]);
            if (c) {
                DPPipLog([NSString stringWithFormat:@"PIP controller direct +%@ -> %@",
                          n, NSStringFromClass(object_getClass(c))]);
                return c;
            }
        }
        DPPipLog(@"PIP controller direct: all nil");
    }
    if (!coord) return nil;

    // 2) controllerForType:  (参数类型 q)
    // SBWindowingItemPIPControllerType / SBPIPControllerType 常见取值 0/1/2 都试
    for (NSNumber *type in @[@0, @1, @2]) {
        id c = DPCall(coord, @"controllerForType:", @[type]);
        if (c && [c isKindOfClass:NSObject.class]) {
            DPPipLog([NSString stringWithFormat:@"PIP controllerForType:%@ -> %@",
                      type, NSStringFromClass(object_getClass(c))]);
            return c;
        }
    }
    DPPipLog(@"PIP controllerForType: all nil");
    return nil;
}

- (void)dumpPipControllerCapabilities:(id)controller {
    if (!controller) { DPPipLog(@"PIP dump: controller nil"); return; }
    Class cls = object_getClass(controller);
    DPPipLog([NSString stringWithFormat:@"PIP dump class=%@", NSStringFromClass(cls)]);
    for (NSString *n in @[@"addContainerViewController:dataSource:",
                          @"removeContainerViewController:",
                          @"contentViewController",
                          @"pictureInPictureContainerViewController",
                          @"activeContainerViewController",
                          @"containers"]) {
        SEL sel = NSSelectorFromString(n);
        BOOL inst = [controller respondsToSelector:sel];
        NSString *enc = @"?";
        if (inst) {
            NSMethodSignature *sig = [controller methodSignatureForSelector:sel];
            if (sig) {
                NSMutableString *s = [NSMutableString stringWithFormat:@"(%s)", sig.methodReturnType];
                for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
                    [s appendFormat:@"%s", [sig getArgumentTypeAtIndex:i]];
                }
                enc = s;
            }
        } else if ([cls respondsToSelector:sel]) {
            enc = @"class-method";
        }
        DPPipLog([NSString stringWithFormat:@"PIP sel %@ exists=%d enc=%@", n, inst, enc]);
    }
}

- (BOOL)attachContentViewController:(UIViewController *)vc
                        toContainer:(id)container
                           bundleID:(NSString *)bundleID {
    if (!vc || !container) return NO;
    NSString *cn = NSStringFromClass(object_getClass(container));
    DPPipLog([NSString stringWithFormat:@"PIP attach vc=%@ container=%@ bundle=%@",
              NSStringFromClass(object_getClass(vc)), cn, bundleID]);
    // PV 用 addContainerViewController:dataSource: —— 但我们没有系统认的 dataSource，
    // 贸然传 nil 可能崩。这里只做能力确认，真正接管留给下一步。
    if ([container respondsToSelector:NSSelectorFromString(@"addContainerViewController:dataSource:")]) {
        DPPipLog(@"PIP attach: addContainerViewController:dataSource: available (not invoked yet)");
        return YES;
    }
    DPPipLog(@"PIP attach: selector missing");
    return NO;
}

@end