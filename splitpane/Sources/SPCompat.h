// SPCompat.h — 私有 API 安全调用层
// 每个私有类方法先校验真实 method（不是仅签名），再按精确 type encoding 调用。
// 任何一步不符 → 返回 NO / nil，调用方走降级路径。绝不猜 selector 签名。

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static inline BOOL SPType(const char *actual, const char *expected) {
    if (!actual || !expected) return NO;
    while (*actual && strchr("rnNoORV", *actual)) actual++;
    if (!strcmp(expected, "@")) return actual[0] == '@';
    if (!strcmp(expected, "#")) return !strcmp(actual, "#");
    if (!strcmp(expected, @encode(BOOL))) return !strcmp(actual, "B") || !strcmp(actual, "c");
    while (*actual || *expected) {
        if (*actual == '"') { actual++; while (*actual && *actual != '"') actual++; if (*actual) actual++; continue; }
        if (*expected == '"') { expected++; while (*expected && *expected != '"') expected++; if (*expected) expected++; continue; }
        if (*actual != *expected) return NO;
        if (!*actual) break;
        actual++; expected++;
    }
    return YES;
}

// 校验：方法真实存在 + 参数个数 + 返回类型 + 每个参数类型
static inline BOOL SPABI(id obj, NSString *name, const char *ret, NSUInteger count, ...) {
    SEL sel = NSSelectorFromString(name);
    if (!obj || ![obj respondsToSelector:sel]) return NO;
    Method method = class_getInstanceMethod(object_getClass(obj), sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if ((NSUInteger)sig.numberOfArguments != count + 2) return NO;
    if (!SPType(sig.methodReturnType, ret)) return NO;
    va_list args; va_start(args, count);
    BOOL ok = YES;
    for (NSUInteger i = 0; i < count; i++) {
        if (!SPType([sig getArgumentTypeAtIndex:i + 2], va_arg(args, const char *))) ok = NO;
    }
    va_end(args);
    return ok;
}

static inline BOOL SPClassABI(Class cls, NSString *name, const char *ret, NSUInteger count, ...) {
    SEL sel = NSSelectorFromString(name);
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    Method method = class_getClassMethod(cls, sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if ((NSUInteger)sig.numberOfArguments != count + 2) return NO;
    if (!SPType(sig.methodReturnType, ret)) return NO;
    va_list args; va_start(args, count);
    BOOL ok = YES;
    for (NSUInteger i = 0; i < count; i++) {
        if (!SPType([sig getArgumentTypeAtIndex:i + 2], va_arg(args, const char *))) ok = NO;
    }
    va_end(args);
    return ok;
}

static inline id SPMsg0(id obj, NSString *name) {
    if (!SPABI(obj, name, "@", 0)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name));
}
// copy family 返回 +1：先校验 ABI，再让编译器按原生消息的 ARC 所有权规则接管。
// 不可用 SPMsg0 的普通 id 函数指针调用 copy / mutableCopy（它被视为 +0）。
static inline id SPCopy0(id obj, BOOL mutableCopy) {
    if (!SPABI(obj, mutableCopy ? @"mutableCopy" : @"copy", "@", 0)) return nil;
    return mutableCopy ? [obj mutableCopy] : [obj copy];
}
static inline id SPMsg1(id obj, NSString *name, id a) {
    if (!SPABI(obj, name, "@", 1, "@")) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, NSSelectorFromString(name), a);
}
static inline id SPMsg2(id obj, NSString *name, id a, id b) {
    if (!SPABI(obj, name, "@", 2, "@", "@")) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(obj, NSSelectorFromString(name), a, b);
}
static inline id SPMsg1I(id obj, NSString *name, NSInteger a) {
    if (!SPABI(obj, name, "@", 1, @encode(NSInteger))) return nil;
    return ((id (*)(id, SEL, NSInteger))objc_msgSend)(obj, NSSelectorFromString(name), a);
}
static inline void SPVoid1(id obj, NSString *name, id a) {
    if (!SPABI(obj, name, "v", 1, "@")) return;
    ((void (*)(id, SEL, id))objc_msgSend)(obj, NSSelectorFromString(name), a);
}
static inline void SPVoid1B(id obj, NSString *name, BOOL a) {
    if (!SPABI(obj, name, "v", 1, @encode(BOOL))) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, NSSelectorFromString(name), a);
}
static inline void SPVoid2B(id obj, NSString *name, BOOL a, BOOL b) {
    if (!SPABI(obj, name, "v", 2, @encode(BOOL), @encode(BOOL))) return;
    ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(obj, NSSelectorFromString(name), a, b);
}
static inline void SPVoid1I(id obj, NSString *name, NSInteger a) {
    if (!SPABI(obj, name, "v", 1, @encode(NSInteger))) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(obj, NSSelectorFromString(name), a);
}
static inline void SPVoidRect1(id obj, NSString *name, CGRect r) {
    if (!SPABI(obj, name, "v", 1, @encode(CGRect))) return;
    ((void (*)(id, SEL, CGRect))objc_msgSend)(obj, NSSelectorFromString(name), r);
}
static inline BOOL SPBool0(id obj, NSString *name) {
    return SPABI(obj, name, @encode(BOOL), 0) &&
           ((BOOL (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name));
}
static inline NSInteger SPInt0(id obj, NSString *name) {
    if (!SPABI(obj, name, @encode(NSInteger), 0)) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name));
}
static inline CGRect SPRect0(id obj, NSString *name) {
    CGRect r = CGRectZero;
    if (!SPABI(obj, name, @encode(CGRect), 0)) return r;
    return ((CGRect (*)(id, SEL))objc_msgSend)(obj, NSSelectorFromString(name));
}
static inline id SPGetIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    const char *t = ivar_getTypeEncoding(iv);
    if (!t || t[0] != '@') return nil;
    return object_getIvar(obj, iv);
}

// 有序枚举：从 SpringBoard 的窗口栈里找最顶的、我们需要的 view controller
static inline UIViewController *SPFindAncestorVC(UIView *v) {
    UIResponder *r = v;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = [r nextResponder];
    }
    return nil;
}