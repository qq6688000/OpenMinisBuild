#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <string.h>
#include <math.h>

// Exact scalar/aggregate encodings, ignoring qualifiers and quoted field names.
static inline BOOL SPType(const char *actual,const char *expected) {
 if(!actual||!expected)return NO;
 while(*actual&&strchr("rnNoORV",*actual))actual++;
 if(!strcmp(expected,"@"))return actual[0]=='@'; // object/block: pointer ABI
 if(!strcmp(expected,"#"))return !strcmp(actual,"#");
 if(!strcmp(expected,@encode(BOOL)))return !strcmp(actual,"B")||!strcmp(actual,"c");
 while(*actual||*expected){
  if(*actual=='\"'){actual++;while(*actual&&*actual!='\"')actual++;if(*actual)actual++;continue;}
  if(*expected=='\"'){expected++;while(*expected&&*expected!='\"')expected++;if(*expected)expected++;continue;}
  if(*actual!=*expected)return NO;
  if(!*actual)break;actual++;expected++;
 }
 return YES;
}
static inline BOOL SPABI(id obj,NSString *name,const char *ret,NSUInteger count,...) {
 SEL sel=NSSelectorFromString(name);
 if(!obj||![obj respondsToSelector:sel])return NO;
 // Require an actual method, not a forwarding-only signature.
 Method method=class_getInstanceMethod(object_getClass(obj),sel);
 if(!method)return NO;
 NSMethodSignature *sig=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
 if(sig.numberOfArguments!=count+2||!SPType(sig.methodReturnType,ret))return NO;
 va_list args;va_start(args,count);BOOL ok=YES;
 for(NSUInteger i=0;i<count;i++)if(!SPType([sig getArgumentTypeAtIndex:i+2],va_arg(args,const char *)))ok=NO;
 va_end(args);return ok;
}
static inline id SPGet(id obj,NSString *name) {
 if(!SPABI(obj,name,"@",0))return nil;
 return ((id(*)(id,SEL))objc_msgSend)(obj,NSSelectorFromString(name));
}
static inline BOOL SPBool(id obj,NSString *name) {
 return SPABI(obj,name,@encode(BOOL),0)&&((BOOL(*)(id,SEL))objc_msgSend)(obj,NSSelectorFromString(name));
}
static inline NSInteger SPInteger(id obj,NSString *name) {
 if(!SPABI(obj,name,@encode(NSInteger),0))return 0;
 return ((NSInteger(*)(id,SEL))objc_msgSend)(obj,NSSelectorFromString(name));
}
static inline NSInteger SPReferenceMode(id obj) {
 if(!SPABI(obj,@"contentReferenceSize",@encode(CGSize),0))return 0;
 if(SPABI(obj,@"contentOrientation",@encode(NSInteger),0)&&SPABI(obj,@"containerOrientation",@encode(NSInteger),0)&&
    SPABI(obj,@"setContentReferenceSize:withContentOrientation:andContainerOrientation:","v",3,@encode(CGSize),@encode(NSInteger),@encode(NSInteger)))return 1;
 if(SPABI(obj,@"contentInterfaceOrientation",@encode(NSInteger),0)&&
    SPABI(obj,@"setContentReferenceSize:withInterfaceOrientation:","v",2,@encode(CGSize),@encode(NSInteger)))return 2;
 return 0;
}
static inline NSInteger SPOrientation(id obj) {
 return SPInteger(obj,SPReferenceMode(obj)==1?@"contentOrientation":@"contentInterfaceOrientation");
}
static inline BOOL SPReference(id obj,CGSize size) {
 NSInteger mode=SPReferenceMode(obj);
 if(mode==1)((void(*)(id,SEL,CGSize,NSInteger,NSInteger))objc_msgSend)(obj,NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:"),size,SPInteger(obj,@"contentOrientation"),SPInteger(obj,@"containerOrientation"));
 else if(mode==2)((void(*)(id,SEL,CGSize,NSInteger))objc_msgSend)(obj,NSSelectorFromString(@"setContentReferenceSize:withInterfaceOrientation:"),size,SPInteger(obj,@"contentInterfaceOrientation"));
 return mode!=0;
}
static inline BOOL SPRect(id obj,CGRect *out) {
 if(!SPABI(obj,@"frame",@encode(CGRect),0))return NO;
 *out=((CGRect(*)(id,SEL))objc_msgSend)(obj,NSSelectorFromString(@"frame"));return YES;
}
static inline BOOL SPInsets(id obj,UIEdgeInsets *out) {
 if(!SPABI(obj,@"safeAreaInsetsPortrait",@encode(UIEdgeInsets),0))return NO;
 *out=((UIEdgeInsets(*)(id,SEL))objc_msgSend)(obj,NSSelectorFromString(@"safeAreaInsetsPortrait"));return YES;
}
static inline BOOL SPFrame(id obj,CGRect f) {
 if(!SPABI(obj,@"setFrame:","v",1,@encode(CGRect)))return NO;
 ((void(*)(id,SEL,CGRect))objc_msgSend)(obj,NSSelectorFromString(@"setFrame:"),f);return YES;
}
static inline BOOL SPEnhanced(id obj,BOOL value) {
 if(!SPABI(obj,@"setEnhancedWindowingEnabled:","v",1,@encode(BOOL)))return NO;
 ((void(*)(id,SEL,BOOL))objc_msgSend)(obj,NSSelectorFromString(@"setEnhancedWindowingEnabled:"),value);return YES;
}
static inline BOOL SPSafeArea(id obj,UIEdgeInsets value) {
 if(!SPABI(obj,@"setSafeAreaInsetsPortrait:","v",1,@encode(UIEdgeInsets)))return NO;
 ((void(*)(id,SEL,UIEdgeInsets))objc_msgSend)(obj,NSSelectorFromString(@"setSafeAreaInsetsPortrait:"),value);return YES;
}
static inline id SPContext(id scene) {
 id context=SPGet(scene,@"_createTransitionContext");if(context)return context;
 id spec=SPGet(scene,@"specification");
 if(!SPABI(spec,@"transitionContextClass","#",0))return nil;
 Class cls=((Class(*)(id,SEL))objc_msgSend)(spec,NSSelectorFromString(@"transitionContextClass"));
 return SPGet(cls,@"transitionContext");
}
static inline BOOL SPUpdate(id scene,id settings) {
 if(!settings||!SPABI(scene,@"updateSettings:withTransitionContext:completion:","v",3,"@","@","@"))return NO;
 id context=SPContext(scene);if(!context)return NO;
 ((void(*)(id,SEL,id,id,id))objc_msgSend)(scene,NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"),settings,context,nil);return YES;
}
// Static evidence: ACTIVATION-IMPLEMENTATION.md. Runtime encoding checks remain mandatory.
static inline BOOL SPContains(id layout,id item) {
 Class cls=NSClassFromString(@"SBAppLayout");
 return cls&&[layout isKindOfClass:cls]&&item&&SPABI(layout,@"containsItem:",@encode(BOOL),1,"@")&&
  ((BOOL(*)(id,SEL,id))objc_msgSend)(layout,NSSelectorFromString(@"containsItem:"),item);
}
static inline BOOL SPSubmit(id switcher,id layout,id item) {
 Class cls=NSClassFromString(@"SBFluidSwitcherViewController");
 Class requests=NSClassFromString(@"SBSwitcherTransitionRequest");
 if(!NSThread.isMainThread||!cls||![switcher isKindOfClass:cls]||!SPContains(layout,item)||
    !SPABI(requests,@"requestForActivatingAppLayout:","@",1,"@"))return NO;
 id coordinator=SPGet(NSClassFromString(@"SBMainSwitcherControllerCoordinator"),@"sharedInstance");
 if(!SPABI(coordinator,@"switcherContentController:performTransitionWithRequest:gestureInitiated:","v",3,"@","@",@encode(BOOL)))return NO;
 id request=((id(*)(id,SEL,id))objc_msgSend)(requests,NSSelectorFromString(@"requestForActivatingAppLayout:"),layout);
 if(!request)return NO;
 ((void(*)(id,SEL,id,id,BOOL))objc_msgSend)(coordinator,NSSelectorFromString(@"switcherContentController:performTransitionWithRequest:gestureInitiated:"),switcher,request,NO);
 return YES; // Submission only, never transition completion.
}
static inline BOOL SPFiniteRect(CGRect f) {
 return isfinite(f.origin.x)&&isfinite(f.origin.y)&&isfinite(f.size.width)&&isfinite(f.size.height)&&f.size.width>0&&f.size.height>0;
}
