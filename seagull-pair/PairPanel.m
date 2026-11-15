#import "PairPanel.h"
@implementation SPContentWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
 UIView *hit=[super hitTest:point withEvent:event];
 return hit==self||hit==self.rootViewController.view?nil:hit;
}
@end
@interface SPPanelWindow : UIWindow
@property(nonatomic,strong) UIView *panel;
@end
@implementation SPPanelWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
 if (self.hidden || !CGRectContainsPoint(self.panel.frame,p)) return nil;
 return [super hitTest:p withEvent:event];
}
@end
@interface SPPanel ()
@property(nonatomic,strong) UIView *body;
@property(nonatomic) BOOL expanded;
@end
@implementation SPPanel
- (UIButton *)button:(NSString *)title action:(SEL)action frame:(CGRect)frame {
 UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.frame=frame;
 [b setTitle:title forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
 b.backgroundColor=[UIColor colorWithWhite:0.18 alpha:1]; b.layer.cornerRadius=7;
 [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
 [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; [self.body addSubview:b];return b;
}
- (void)install {
 if(self.window)return;
 UIWindowScene *scene=nil;
 for(UIScene *s in UIApplication.sharedApplication.connectedScenes) if([s isKindOfClass:UIWindowScene.class]&&s.activationState!=UISceneActivationStateUnattached){scene=(id)s;break;}
 if(!scene)return;
 SPPanelWindow *w=[[SPPanelWindow alloc]initWithWindowScene:scene];w.frame=UIScreen.mainScreen.bounds;w.windowLevel=UIWindowLevelAlert+10;
 UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.clearColor;w.rootViewController=vc;
 UIView *body=[[UIView alloc]initWithFrame:CGRectMake(12,100,290,200)];body.backgroundColor=[UIColor colorWithWhite:0.07 alpha:0.94];body.layer.cornerRadius=12;[vc.view addSubview:body];w.panel=body;self.body=body;self.window=w;self.expanded=YES;
 [self button:@"海鸥组合 · 收起" action:@selector(toggle) frame:CGRectMake(8,6,274,28)];
 [self button:@"当前 App → A" action:@selector(slotA) frame:CGRectMake(8,40,133,30)];
 [self button:@"当前 App → B" action:@selector(slotB) frame:CGRectMake(149,40,133,30)];
 [self button:@"组合" action:@selector(start) frame:CGRectMake(8,76,86,30)];
 [self button:@"交换" action:@selector(swap) frame:CGRectMake(102,76,86,30)];
 [self button:@"恢复" action:@selector(stop) frame:CGRectMake(196,76,86,30)];
 UISlider *slider=[[UISlider alloc]initWithFrame:CGRectMake(12,112,266,28)];slider.minimumValue=.3;slider.maximumValue=.7;slider.value=.5;[slider addTarget:self action:@selector(ratio:) forControlEvents:UIControlEventValueChanged];[body addSubview:slider];
 UILabel *label=[[UILabel alloc]initWithFrame:CGRectMake(10,146,270,46)];label.numberOfLines=3;label.font=[UIFont systemFontOfSize:11];label.textColor=UIColor.whiteColor;[body addSubview:label];self.status=label;
 [self message:@"实验单焦点：依次保存 A/B 与冻结画面。远程内容质量未验证。"];
 UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(move:)];[body addGestureRecognizer:pan];pan.maximumNumberOfTouches=2;pan.minimumNumberOfTouches=2;
 w.hidden=NO;
}
- (void)toggle {self.expanded=!self.expanded;CGRect f=self.body.frame;f.size.height=self.expanded?200:38;self.body.frame=f;self.body.clipsToBounds=YES;}
- (void)move:(UIPanGestureRecognizer *)g {CGPoint d=[g translationInView:self.window];CGRect f=self.body.frame;f.origin.x=MAX(0,MIN(self.window.bounds.size.width-f.size.width,f.origin.x+d.x));f.origin.y=MAX(50,MIN(self.window.bounds.size.height-45,f.origin.y+d.y));self.body.frame=f;[g setTranslation:CGPointZero inView:self.window];}
- (void)slotA {[self.delegate captureSlot:0];}
- (void)slotB {[self.delegate captureSlot:1];}
- (void)start {[self.delegate startPair];}
- (void)swap {[self.delegate swapPair];}
- (void)stop {[self.delegate stopPair];}
- (void)ratio:(UISlider *)slider {[self.delegate setPairRatio:slider.value];}
- (void)message:(NSString *)text {self.status.text=text;NSLog(@"[SeagullPair] %@",text);}
- (void)hide {self.window.hidden=YES;}
@end
