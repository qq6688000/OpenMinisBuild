#import "PairRuntime.h"
#import "PairPanel.m"
#import <QuartzCore/QuartzCore.h>
extern void MSHookMessageEx(Class,SEL,IMP,IMP*);
@interface SPObservedLayout : NSObject
@property(nonatomic,strong) id layout;
@property(nonatomic,weak) id switcher;
@property(nonatomic,weak) id overlay;
@property(nonatomic,strong) id item;
@end
@implementation SPObservedLayout @end
@interface SPCapture : NSObject
@property(nonatomic,strong) SPObservedLayout *observedLayout;
@property(nonatomic,weak) id controller;
@property(nonatomic,weak) id scene;
@property(nonatomic,strong) id item;
@property(nonatomic,copy) NSString *identity;
@property(nonatomic,strong) UIView *host;
@property(nonatomic,strong) UIView *snapshot; // UIKit replica; remote-content quality UNVERIFIED.
@property(nonatomic) NSInteger snapshotOrientation;
@property(nonatomic) CGRect originalSceneFrame;
@property(nonatomic) CGRect targetFrame;
@property(nonatomic) UIEdgeInsets originalSafeArea;
@property(nonatomic) BOOL originalEnhanced;
@property(nonatomic) BOOL settingsTouched;
@property(nonatomic) BOOL referenceTouched;
@property(nonatomic) BOOL applying;
@property(nonatomic,copy) NSString *cornerCurve;
@property(nonatomic) CACornerMask maskedCorners;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,strong) UIView *view;
@property(nonatomic,weak) UIView *parent;
@property(nonatomic) NSUInteger index;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) CGSize originalReferenceSize;
@property(nonatomic) CGFloat radius;
@property(nonatomic) BOOL clips;
@property(nonatomic) BOOL prepared;
@property(nonatomic) BOOL moved;
@end
@implementation SPCapture @end
@interface SPManager : NSObject <SPPanelActions>
@property(nonatomic,strong) SPPanel *panel;
@property(nonatomic,strong) NSHashTable *controllers;
@property(nonatomic,strong) NSMapTable *observedLayouts;
- (void)observeOverlay:(id)overlay layout:(id)layout switcher:(id)switcher;
@property(nonatomic,strong) SPCapture *a;
@property(nonatomic,strong) SPCapture *b;
@property(nonatomic,strong) UIWindow *pairWindow;
@property(nonatomic) CGFloat ratio;
@property(nonatomic) BOOL active;
@property(nonatomic,strong) SPCapture *focused;
@property(nonatomic,strong) SPCapture *pending;
@property(nonatomic,weak) id readyController;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL transitionFinished;
@property(nonatomic,strong) id transitionIdentifier;
@property(nonatomic) BOOL transitionHookAvailable;
- (void)observeTransition:(id)event;
@property(nonatomic,strong) NSTimer *deadline;
- (void)selectSlot:(NSInteger)slot;
- (void)considerPendingController:(id)controller generation:(NSUInteger)generation;
- (BOOL)restore:(SPCapture *)record;
@property(nonatomic) BOOL layoutQueued;
@property(nonatomic) BOOL applying;
@property(nonatomic,strong) NSTimer *timer;
- (void)observe:(id)controller;
- (void)layout;
- (void)abortForSystemEvent:(NSNotification *)note;
@end
static SPManager *manager;
static id SPScene(id controller){return SPGet(SPGet(controller,@"sceneHandle"),@"sceneIfExists");}
static BOOL SPReady(SPCapture *r) {
 id c=r.controller,handle=SPGet(c,@"sceneHandle"),item=SPGet(handle,@"displayItemRepresentation");
 UIView *v=SPGet(c,@"view");
 return c&&r.scene&&SPGet(handle,@"sceneIfExists")==r.scene&&[item isEqual:r.item]&&
  [SPGet(item,@"uniqueIdentifier") isEqual:r.identity]&&SPBool(handle,@"isContentReady")&&
  SPBool(SPGet(r.scene,@"settings"),@"isForeground")&&[v isKindOfClass:UIView.class]&&
  (!r.prepared||v==r.view)&&v.window&&!v.hidden&&CGAffineTransformIsIdentity(v.transform);
}
static CGSize SPOrientedSize(id controller,CGSize size) {
 return UIInterfaceOrientationIsLandscape(SPOrientation(controller))?CGSizeMake(size.height,size.width):size;
}
@implementation SPManager
- (instancetype)init {if((self=[super init])){_controllers=[NSHashTable weakObjectsHashTable];_observedLayouts=[NSMapTable weakToStrongObjectsMapTable];_ratio=.5;_panel=[SPPanel new];_panel.delegate=self;}return self;}
- (void)observe:(id)controller {
 if(!NSThread.isMainThread)return;
 if(SPABI(controller,@"sceneHandle","@",0)) [self.controllers addObject:controller];
 if(self.active&&self.pending){
  NSUInteger generation=self.generation;
  __weak id weakController=controller;
  dispatch_async(dispatch_get_main_queue(),^{[self considerPendingController:weakController generation:generation];});
 }
 // Original layout has returned. Only the single owned placement is reapplied.
 if(self.active&&!self.pending&&!self.applying&&controller==self.focused.controller){
  if(self.layoutQueued)return;self.layoutQueued=YES;
  dispatch_async(dispatch_get_main_queue(),^{self.layoutQueued=NO;if(self.active)[self layout];});
 }
}
- (void)observeOverlay:(id)overlay layout:(id)layout switcher:(id)switcher {
 if(!NSThread.isMainThread)return;
 Class cls=NSClassFromString(@"SBFullScreenSwitcherSceneLiveContentOverlay");
 if(!cls||![overlay isKindOfClass:cls])return;
 id controller=SPGet(overlay,@"deviceApplicationSceneViewController");
 id item=SPGet(SPGet(controller,@"sceneHandle"),@"displayItemRepresentation");
 Class switcherClass=NSClassFromString(@"SBFluidSwitcherViewController");
 if(!switcherClass||![switcher isKindOfClass:switcherClass]||!controller||!SPContains(layout,item))return;
 SPObservedLayout *record=[SPObservedLayout new];record.layout=layout;record.switcher=switcher;record.overlay=overlay;record.item=item;
 [self.observedLayouts setObject:record forKey:controller];
 // Observation only: neither a transition submission nor a focus/foreground assertion.
 for(SPCapture *r in @[self.a?:[NSNull null],self.b?:[NSNull null]])
  if([r isKindOfClass:SPCapture.class]&&r.controller==controller&&[r.item isEqual:item])r.observedLayout=record;
}
- (void)captureSlot:(NSInteger)slot {
 if(self.active){[self.panel message:@"请先恢复，再更换 App。"];return;}
 @try {
 id chosen=nil;
 for(id c in self.controllers.allObjects){
  id scene=SPScene(c); UIView *v=SPGet(c,@"view");
  if(scene&&[v isKindOfClass:UIView.class]&&v.window&&!v.hidden&&SPBool(SPGet(c,@"sceneHandle"),@"isContentReady")&&SPBool(SPGet(scene,@"settings"),@"isForeground")){
   if(chosen){[self.panel message:@"发现多个前台场景，无法可靠识别当前 App。"];return;}chosen=c;
  }
 }
 if(!chosen){[self.panel message:@"尚未捕获前台场景；打开 App 后再试。"];return;}
 SPCapture *r=[SPCapture new];r.controller=chosen;r.scene=SPScene(chosen);
 id item=SPGet(SPGet(chosen,@"sceneHandle"),@"displayItemRepresentation");
 r.item=item;r.identity=SPGet(item,@"uniqueIdentifier");r.name=SPGet(item,@"bundleIdentifier");
 if(![r.identity isKindOfClass:NSString.class]||!r.identity.length||![r.name isKindOfClass:NSString.class]||!r.name.length){[self.panel message:@"无法验证场景身份；未保存。"];return;}
 SPObservedLayout *observed=[self.observedLayouts objectForKey:chosen];
 if(observed.switcher&&observed.overlay&&[observed.item isEqual:item])r.observedLayout=observed;
 if(slot!=0&&slot!=1)return;
 if([(slot==0?self.b:self.a).identity isEqual:r.identity]){[self.panel message:@"A 和 B 必须是不同的应用场景。"];return;}
 if(!SPReady(r)){[self.panel message:@"场景已失去可见就绪状态，未保存。"];return;}
 UIView *source=SPGet(chosen,@"view");
 r.snapshot=[source snapshotViewAfterScreenUpdates:NO];
 if(!r.snapshot||!SPFiniteRect(source.bounds)){[self.panel message:@"冻结画面失败，未保存。"];return;}
 r.snapshot.userInteractionEnabled=NO;r.snapshotOrientation=SPOrientation(chosen);
 NSLog(@"[SeagullPair] UIKit snapshot %@: remote-content quality UNVERIFIED",r.identity);
 if(slot==0)self.a=r;else self.b=r;
 [self.panel message:[NSString stringWithFormat:@"A: %@\nB: %@",self.a.name?:@"未选择",self.b.name?:@"未选择"]];
 }@catch(NSException *e){[self.panel message:[@"捕获失败：" stringByAppendingString:e.reason?:e.name]];}
}
- (BOOL)prepare:(SPCapture *)r {
 if(!SPReady(r))return NO;
 UIView *v=SPGet(r.controller,@"view");if(!v.superview||!SPReferenceMode(r.controller))return NO;
 id settings=SPGet(r.scene,@"settings"),copy=SPGet(settings,@"mutableCopy");
 CGRect frame;UIEdgeInsets insets;
 if(!SPRect(settings,&frame)||!SPFiniteRect(frame)||!SPInsets(SPGet(r.scene,@"uiSettings"),&insets)||
    !SPABI(settings,@"enhancedWindowingEnabled",@encode(BOOL),0)||
    !SPABI(r.scene,@"updateSettings:withTransitionContext:completion:","v",3,"@","@","@")||!SPContext(r.scene)||
    !SPFrame(copy,frame)||!SPEnhanced(copy,YES)||!SPSafeArea(copy,insets))return NO;
 CGSize reference=((CGSize(*)(id,SEL))objc_msgSend)(r.controller,NSSelectorFromString(@"contentReferenceSize"));
 if(!SPFiniteRect((CGRect){CGPointZero,reference}))return NO;
 NSInteger orientation=SPOrientation(r.controller);if(orientation<1||orientation>4)return NO;
 r.originalSceneFrame=frame;r.originalReferenceSize=reference;r.originalSafeArea=insets;
 r.originalEnhanced=SPBool(settings,@"enhancedWindowingEnabled");
 r.view=v;r.parent=v.superview;r.index=[v.superview.subviews indexOfObjectIdenticalTo:v];
 r.originalFrame=v.frame;r.radius=v.layer.cornerRadius;r.cornerCurve=v.layer.cornerCurve;
 r.maskedCorners=v.layer.maskedCorners;r.clips=v.clipsToBounds;r.prepared=YES;return YES;
}
- (void)startPair {
 if(self.active)return;
 if(!self.a||!self.b){[self.panel message:@"先分别打开两个 App，选择 A 和 B。"];return;}
 @try {
 BOOL aReady=SPReady(self.a),bReady=SPReady(self.b);
 if(aReady==bReady||!self.a.snapshot||!self.b.snapshot){
  [self.panel message:@"需要恰好一个已选择场景在前台就绪，以及两份已保存冻结画面。"];return;
 }
 self.focused=aReady?self.a:self.b;
 if(![self prepare:self.focused]){self.focused=nil;[self.panel message:@"场景几何接口/ABI 不受支持，未启动。"];return;}
 self.generation++;
 UIWindowScene *ws=self.panel.window.windowScene;if(!ws)return;
 UIWindow *w=[[SPContentWindow alloc]initWithWindowScene:ws];w.frame=UIScreen.mainScreen.bounds;w.windowLevel=UIWindowLevelNormal+5;
 UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.blackColor;w.rootViewController=vc;self.pairWindow=w;self.active=YES;
 for(SPCapture *r in @[self.a,self.b]){
  r.host=[UIView new];r.host.clipsToBounds=YES;[vc.view addSubview:r.host];
  if(r==self.focused){r.moved=YES;[r.host addSubview:r.view];}
  else [r.host addSubview:r.snapshot];
  if(r!=self.focused){
   UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(selectFrozen:)];
   [r.host addGestureRecognizer:tap];
  }
 }
 w.hidden=NO;[self layout];
 if(self.active)[self.panel message:@"单焦点 + 冻结画面（远程内容未验证）。点击冻结侧请求切换；等待系统完成事件与目标就绪。"];
 }@catch(NSException *e){[self stopPair];[self.panel message:[@"组合失败：" stringByAppendingString:e.reason?:e.name]];}
}
- (void)selectFrozen:(UITapGestureRecognizer *)gesture {
 [self selectSlot:gesture.view==self.a.host?0:1];
}
- (void)selectSlot:(NSInteger)slot {
 if(!NSThread.isMainThread||!self.active||self.pending||(slot!=0&&slot!=1))return;
 SPCapture *target=slot==0?self.a:self.b,*old=self.focused;
 if(target==old)return;
 if(!self.transitionHookAvailable){[self.panel message:@"系统完成观察接口 ABI 不可用，未提交切换。"];return;}
 @try {
  SPObservedLayout *record=target.observedLayout;
  if(!record.switcher||!SPContains(record.layout,target.item)||![record.item isEqual:target.item]){
   [self.panel message:@"未观察到匹配的 SBAppLayout / switcher，不能提交激活。"];return;
  }
  if(!SPReady(old)||old.view.superview!=old.host){[self stopPair];return;}
  UIView *frozen=[old.view snapshotViewAfterScreenUpdates:NO];
  if(!frozen){[self.panel message:@"冻结失败，保持当前焦点。"];return;}
  frozen.userInteractionEnabled=NO;old.snapshot=frozen;old.snapshotOrientation=SPOrientation(old.controller);
  // Restore native ownership before activation; no alpha concealment remains to leak on failure.
  UIView *host=old.host;
  if(![self restore:old]){[self stopPair];[self.panel message:@"旧场景恢复失败，未提交切换。"];return;}
  old.host=host;[self.pairWindow.rootViewController.view addSubview:host];[host addSubview:frozen];
  self.focused=nil;self.pending=target;self.readyController=nil;self.transitionFinished=NO;self.transitionIdentifier=nil;
  NSUInteger generation=++self.generation;
  self.deadline=[NSTimer scheduledTimerWithTimeInterval:8 repeats:NO block:^(NSTimer *timer){
   (void)timer;
   if(!self.active||!self.pending||self.generation!=generation)return;
   BOOL ready=self.readyController!=nil;
   [self stopPair];
   [self.panel message:ready?@"已观察到目标就绪，但未满足同一 transition 完成门槛；已超时退出，未执行交接。":@"激活等待超时，未取得匹配的就绪场景；已退出。"];
  }];
  [self layout];
  if(!self.active||self.generation!=generation||self.pending!=target)return;
  if(!SPSubmit(record.switcher,record.layout,target.item)){
   [self stopPair];[self.panel message:@"激活 ABI 或请求无效；已退出。"];return;
  }
  [self.panel message:@"已提交单项激活，等待匹配 transition 完成及目标身份/就绪。"];
 }@catch(NSException *e){[self stopPair];[self.panel message:@"激活异常，已清理本地呈现。"];}
}
- (void)observeTransition:(id)event {
 if(!NSThread.isMainThread||!self.active||!self.pending||!event)return;
 if(!SPABI(event,@"phase",@encode(NSUInteger),0))return;
 NSUInteger raw=((NSUInteger(*)(id,SEL))objc_msgSend)(event,NSSelectorFromString(@"phase"));
 Class modifier=NSClassFromString(@"SBTransitionSwitcherModifier");
 NSUInteger offset=modifier&&class_getInstanceMethod(modifier,NSSelectorFromString(@"transitionWillPrepare"))?1:0;
 NSUInteger phase=raw>=offset?raw-offset:0;
 id identity=SPGet(event,@"transitionID");if(!identity)return;
 if(!self.transitionIdentifier){
  if(phase!=1||!SPABI(event,@"toEnvironmentMode",@encode(NSInteger),0)||SPInteger(event,@"toEnvironmentMode")!=3||
     !SPContains(SPGet(event,@"toAppLayout"),self.pending.item))return;
  self.transitionIdentifier=identity;
 }else if(![self.transitionIdentifier isEqual:identity])return;
 NSLog(@"[SeagullPair] generation=%lu transition=%@ raw=%lu offset=%lu phase=%lu",(unsigned long)self.generation,identity,(unsigned long)raw,(unsigned long)offset,(unsigned long)phase);
 if(phase!=3)return;
 self.transitionFinished=YES;
 NSUInteger generation=self.generation;
 // The original event factory has returned, but its caller may still own system layout.
 // Defer attaching until that stack unwinds; this is not a completion timer.
 dispatch_async(dispatch_get_main_queue(),^{
  if(self.generation!=generation||!self.active||!self.pending)return;
  if(self.readyController)[self considerPendingController:self.readyController generation:generation];
 });
}
- (void)considerPendingController:(id)controller generation:(NSUInteger)generation {
 if(!NSThread.isMainThread||!self.active||!self.pending||generation!=self.generation)return;
 SPCapture *r=self.pending;
 id handle=SPGet(controller,@"sceneHandle"),item=SPGet(handle,@"displayItemRepresentation");
 if(![item isEqual:r.item]||![SPGet(item,@"uniqueIdentifier") isEqual:r.identity])return;
 SPCapture *candidate=[SPCapture new];candidate.controller=controller;candidate.scene=SPScene(controller);
 candidate.item=r.item;candidate.identity=r.identity;
 if(!SPReady(candidate)){self.readyController=nil;return;}
 self.readyController=controller;
 // Only a bound transition's normalized phase 3 can open this gate.
 // Layout readiness and deadline expiry never synthesize completion.
 if(!self.transitionFinished||!self.transitionIdentifier)return;
 r.prepared=NO;r.controller=controller;r.scene=candidate.scene;
 if(![self prepare:r]){[self stopPair];return;}
 [r.snapshot removeFromSuperview];r.moved=YES;[r.host addSubview:r.view];
 for(UIGestureRecognizer *gesture in r.host.gestureRecognizers)[r.host removeGestureRecognizer:gesture];
 SPCapture *inactive=r==self.a?self.b:self.a;
 if(!inactive.host.gestureRecognizers.count)[inactive.host addGestureRecognizer:[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(selectFrozen:)]];
 self.focused=r;self.pending=nil;self.readyController=nil;
 [self.deadline invalidate];self.deadline=nil;[self layout];
}
- (void)layout {
 if(!self.active||self.applying)return;
 // Runtime state-machine guard, also active in release builds.
 NSUInteger owned=(self.a.moved?1U:0U)+(self.b.moved?1U:0U);
 BOOL valid=self.a&&self.b&&self.a!=self.b&&
  (self.pending?(!self.focused&&owned==0&&(self.pending==self.a||self.pending==self.b)):
   (self.focused&&owned==1&&self.focused.moved&&(self.focused==self.a||self.focused==self.b)));
 if(!valid){[self stopPair];[self.panel message:@"单焦点状态不一致，已清理。"];return;}
 self.applying=YES;
 @try {
 CGRect bounds=self.pairWindow.bounds;
 if(bounds.size.width>bounds.size.height){[self stopPair];[self.panel message:@"首版仅竖屏；已请求恢复场景。"];return;}
 CGFloat top=self.pairWindow.safeAreaInsets.top,bottom=self.pairWindow.safeAreaInsets.bottom;
 CGFloat h=bounds.size.height-top-bottom-8;CGFloat hA=floor(h*self.ratio);
 CGRect frames[2]={CGRectMake(0,top,bounds.size.width,hA),CGRectMake(0,top+hA+8,bounds.size.width,h-hA)};
 NSArray *records=@[self.a,self.b];
 for(NSUInteger i=0;i<2;i++){
  SPCapture *r=records[i];
  if(!SPFiniteRect(frames[i])){[self stopPair];return;}
  r.host.frame=frames[i];
  if(r!=self.focused){
   if(!r.snapshot||r.moved){[self stopPair];return;}
   r.snapshot.frame=r.host.bounds;
   continue;
  }
  if(!SPReady(r)||r.view.superview!=r.host){
   [self stopPair];[self.panel message:@"场景失去前台/就绪状态或托管所有权，已退出实验呈现。"];return;
  }
  if(r.applying)continue;r.applying=YES;
  @try {
   id current=SPGet(r.scene,@"settings");CGRect currentFrame;UIEdgeInsets currentInsets;
   if(!SPRect(current,&currentFrame)||!SPInsets(SPGet(r.scene,@"uiSettings"),&currentInsets))
    @throw [NSException exceptionWithName:@"SPGeometry" reason:@"无法读取当前场景几何" userInfo:nil];
   r.targetFrame=frames[i];
   if(!CGRectEqualToRect(currentFrame,r.targetFrame)||!SPBool(current,@"enhancedWindowingEnabled")||!UIEdgeInsetsEqualToEdgeInsets(currentInsets,r.originalSafeArea)){
    id settings=SPGet(current,@"mutableCopy");
    if(!SPBool(settings,@"isForeground")||!SPFrame(settings,r.targetFrame)||!SPEnhanced(settings,YES)||!SPSafeArea(settings,r.originalSafeArea))
     @throw [NSException exceptionWithName:@"SPGeometry" reason:@"场景 settings 不受支持" userInfo:nil];
    r.settingsTouched=YES;
    if(!SPUpdate(r.scene,settings))@throw [NSException exceptionWithName:@"SPGeometry" reason:@"缺少有效 transition context" userInfo:nil];
   }
   if(!SPReferenceMode(r.controller))@throw [NSException exceptionWithName:@"SPGeometry" reason:@"引用尺寸 ABI 改变" userInfo:nil];
   CGSize reference=((CGSize(*)(id,SEL))objc_msgSend)(r.controller,NSSelectorFromString(@"contentReferenceSize"));
   if(!CGSizeEqualToSize(reference,r.targetFrame.size)){
    r.referenceTouched=YES;if(!SPReference(r.controller,r.targetFrame.size))
     @throw [NSException exceptionWithName:@"SPGeometry" reason:@"无法适配引用尺寸" userInfo:nil];
   }
   CGRect local=(CGRect){CGPointZero,SPOrientedSize(r.controller,r.targetFrame.size)};
   if(!CGRectEqualToRect(r.host.frame,frames[i]))r.host.frame=frames[i];
   if(!CGRectEqualToRect(r.view.frame,local))r.view.frame=local;
   r.view.layer.cornerRadius=12;r.view.layer.cornerCurve=kCACornerCurveContinuous;
   r.view.layer.maskedCorners=0xf;r.view.clipsToBounds=YES;
  }@finally {r.applying=NO;}
 }
 }@catch(NSException *e){[self stopPair];[self.panel message:@"场景布局异常，已请求恢复。"];}
 @finally {self.applying=NO;}
}
- (BOOL)restore:(SPCapture *)r {
 if(!r.moved)return YES;BOOL ok=YES;
 @try {
  if(r.settingsTouched){
   id current=SPGet(r.scene,@"settings");CGRect frame;
   if(!SPRect(current,&frame)||!SPABI(current,@"enhancedWindowingEnabled",@encode(BOOL),0))ok=NO;
   else {
    BOOL sameFrame=CGRectEqualToRect(frame,r.targetFrame);
    BOOL undoEnhanced=SPBool(current,@"enhancedWindowingEnabled")&&!r.originalEnhanced;
    if(sameFrame||undoEnhanced){
     id copy=SPGet(current,@"mutableCopy");
     if(!copy||(sameFrame&&!SPFrame(copy,r.originalSceneFrame))||(undoEnhanced&&!SPEnhanced(copy,r.originalEnhanced))||!SPUpdate(r.scene,copy))ok=NO;
    }
   }
  }
 }@catch(NSException *e){ok=NO;NSLog(@"[SeagullPair] settings restore: %@",e);}
 @try {
  if(SPScene(r.controller)!=r.scene)ok=NO;
  else if(r.referenceTouched&&!SPReference(r.controller,r.originalReferenceSize))ok=NO;
 }@catch(NSException *e){ok=NO;NSLog(@"[SeagullPair] reference restore: %@",e);}
 @try {
  // Do not steal a view that the system has already reparented elsewhere.
  if(r.view.superview==r.host){
   if(r.parent){[r.parent insertSubview:r.view atIndex:MIN(r.index,r.parent.subviews.count)];r.view.frame=r.originalFrame;}
   else {[r.view removeFromSuperview];ok=NO;}
  }
  r.view.layer.cornerRadius=r.radius;r.view.layer.cornerCurve=r.cornerCurve;
  r.view.layer.maskedCorners=r.maskedCorners;r.view.clipsToBounds=r.clips;
  [r.host removeFromSuperview];r.host=nil;
 }@catch(NSException *e){ok=NO;NSLog(@"[SeagullPair] view restore: %@",e);}
 r.moved=NO;r.prepared=NO;r.settingsTouched=NO;r.referenceTouched=NO;return ok;
}
- (void)stopPair {
 self.active=NO;self.generation++;[self.deadline invalidate];self.deadline=nil;
 self.pending=nil;self.focused=nil;self.readyController=nil;self.transitionFinished=NO;self.transitionIdentifier=nil;
 BOOL aOK=[self restore:self.a],bOK=[self restore:self.b];self.pairWindow.hidden=YES;self.pairWindow=nil;
 [self.panel message:(aOK&&bOK)?@"本地视图已还原，场景条件恢复已请求（未确认系统完成）。":@"部分恢复失败：系统场景或原父容器已失效，请回到应用检查；详见日志。"];
 self.a=nil;self.b=nil;
}
- (void)swapPair {if(!self.active||self.pending)return;SPCapture *r=self.a;self.a=self.b;self.b=r;self.ratio=1-self.ratio;[self layout];}
- (void)setPairRatio:(CGFloat)ratio {self.ratio=MAX(.3,MIN(.7,ratio));[self layout];}
- (void)abortForSystemEvent:(NSNotification *)note {if(self.active)[self stopPair];}
@end
static void (*originalLayout)(id,SEL);
static void sceneLayout(id self,SEL cmd){
 originalLayout(self,cmd);
 @try {[manager observe:self];}@catch(NSException *e){NSLog(@"[SeagullPair] observe: %@",e);}
}
static id (*originalOverlay)(id,SEL,id);
static id switcherOverlay(id self,SEL cmd,id layout){
 id overlay=originalOverlay(self,cmd,layout);
 @try {[manager observeOverlay:overlay layout:layout switcher:self];}
 @catch(NSException *e){NSLog(@"[SeagullPair] overlay observation: %@",e);}
 return overlay;
}
static id (*originalTransition)(id,SEL,id,id,NSUInteger,BOOL);
static id transitionEvent(id self,SEL cmd,id context,id identifier,NSUInteger phase,BOOL animated){
 id event=originalTransition(self,cmd,context,identifier,phase,animated);
 @try {[manager observeTransition:event];}
 @catch(NSException *e){[manager stopPair];NSLog(@"[SeagullPair] transition observation: %@",e);}
 return event;
}
__attribute__((constructor)) static void SPStart(void){
 dispatch_async(dispatch_get_main_queue(),^{
  manager=[SPManager new];Class c=NSClassFromString(@"SBDeviceApplicationSceneViewController");
  SEL s=@selector(viewDidLayoutSubviews);
  Method method=c?class_getInstanceMethod(c,s):NULL;
  NSMethodSignature *signature=method?[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)]:nil;
  if(signature.numberOfArguments==2&&SPType(signature.methodReturnType,"v"))MSHookMessageEx(c,s,(IMP)sceneLayout,(IMP*)&originalLayout);
  else NSLog(@"[SeagullPair] scene layout hook unsupported; capture disabled");
  Class switcher=NSClassFromString(@"SBFluidSwitcherViewController");
  SEL overlaySelector=NSSelectorFromString(@"liveContentOverlayForAppLayout:");
  Method overlayMethod=switcher?class_getInstanceMethod(switcher,overlaySelector):NULL;
  NSMethodSignature *overlaySig=overlayMethod?[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(overlayMethod)]:nil;
  if(overlaySig.numberOfArguments==3&&SPType(overlaySig.methodReturnType,"@")&&SPType([overlaySig getArgumentTypeAtIndex:2],"@"))
   MSHookMessageEx(switcher,overlaySelector,(IMP)switcherOverlay,(IMP*)&originalOverlay);
  Class coordinator=NSClassFromString(@"SBMainSwitcherControllerCoordinator");
  SEL transitionSelector=NSSelectorFromString(@"transitionEventForContext:identifier:phase:animated:");
  Method transitionMethod=coordinator?class_getInstanceMethod(coordinator,transitionSelector):NULL;
  NSMethodSignature *transitionSig=transitionMethod?[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(transitionMethod)]:nil;
  if(transitionSig.numberOfArguments==6&&SPType(transitionSig.methodReturnType,"@")&&
     SPType([transitionSig getArgumentTypeAtIndex:2],"@")&&SPType([transitionSig getArgumentTypeAtIndex:3],"@")&&
     SPType([transitionSig getArgumentTypeAtIndex:4],@encode(NSUInteger))&&SPType([transitionSig getArgumentTypeAtIndex:5],@encode(BOOL))){
   MSHookMessageEx(coordinator,transitionSelector,(IMP)transitionEvent,(IMP*)&originalTransition);
   manager.transitionHookAvailable=originalTransition!=NULL;
  }
  [[NSNotificationCenter defaultCenter]addObserver:manager selector:@selector(abortForSystemEvent:) name:UIDeviceOrientationDidChangeNotification object:nil];
  [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
  manager.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){
   (void)t;
   @try {
    id lock=SPGet(NSClassFromString(@"SBLockScreenManager"),@"sharedInstance");
    BOOL lockKnown=SPABI(lock,@"isUILocked",@encode(BOOL),0);
    BOOL locked=!lockKnown||SPBool(lock,@"isUILocked");
    if(locked){if(manager.active||manager.a||manager.b)[manager stopPair];[manager.panel hide];return;}
    [manager.panel install];manager.panel.window.hidden=NO;
    if(manager.active&&!manager.pending&&!SPReady(manager.focused)){
     [manager stopPair];[manager.panel message:@"焦点场景失去前台/就绪状态，已退出。"];}
    else if(manager.active)[manager layout];
   }@catch(NSException *e){if(manager.active)[manager stopPair];NSLog(@"[SeagullPair] watchdog: %@",e);}
  }];
 });
}
