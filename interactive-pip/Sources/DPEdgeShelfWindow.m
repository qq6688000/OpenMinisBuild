#import "DPEdgeShelfWindow.h"
#import "DPEdgeShelfGeometry.h"

// Visual/interaction reference: ZengNiu (曾牛分屏 v1.7.4), Sources/ZNSEdgeShelf.m
// Adapted for Duo. Two content modes:
//  live  - cards embed the scene views directly (real-time content);
//  image - cards show a thumbnail captured before hiding (0.7.68 route).
@interface DPEdgeShelfSurface : UIView
@property (nonatomic, copy) NSArray<UIButton *> *cards;
@property (nonatomic, copy) NSArray *liveViews;      // external views, live mode only
@property (nonatomic, copy) void (^restore)(NSUInteger index);
@property (nonatomic, copy) void (^cardLayout)(NSUInteger index, CGRect frame);
@end

@implementation DPEdgeShelfSurface
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return [hit isKindOfClass:UIButton.class] && [self.cards containsObject:(UIButton *)hit] ? hit : nil;
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets safe = self.safeAreaInsets;
    BOOL landscape = self.bounds.size.width > self.bounds.size.height;
    CGRect space = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(
        MAX(safe.top + 4, landscape ? 24 : 60), safe.left + 6, safe.bottom + 5, safe.right + 6));
    for (NSUInteger i = 0; i < self.cards.count; ++i) {
        UIButton *card = self.cards[i];
        DPEdgeCardRect r = DPEdgeCardFrame(space.origin.x, space.origin.y, space.size.width,
                                           space.size.height, (unsigned)self.cards.count, (unsigned)i);
        card.hidden = r.width < 1 || r.height < 1;
        card.frame = CGRectMake(r.x, r.y, r.width, r.height);
        UIView *content = card.subviews.firstObject;
        content.frame = card.bounds;
        content.layer.cornerRadius = MIN(11, r.width * .2);
        if (i < self.liveViews.count && self.liveViews[i] == content) {
            // Live embedded scene view: relayout its hosted frame to the card
            // size so the scene's cover-scale follows the card exactly.
            if (self.cardLayout) self.cardLayout(i, card.bounds);
        } else {
            // Static thumbnail (or label fallback): apply a slight perspective.
            CATransform3D camera = CATransform3DIdentity;
            if (!UIAccessibilityIsReduceMotionEnabled() && r.width >= 1) {
                camera.m34 = -1.0 / (3 * r.width);
                camera = CATransform3DScale(camera, .96, .96, 1);
                camera = CATransform3DRotate(camera, (landscape ? 18 : 12) * M_PI / 180, 0, 1, 0);
            }
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            content.layer.transform = camera;
            [CATransaction commit];
        }
    }
}
- (void)cardTapped:(UIButton *)sender {
    if ([self.cards containsObject:sender] && self.restore) self.restore((NSUInteger)sender.tag);
}
@end

@implementation DPEdgeShelfWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return [hit isKindOfClass:UIButton.class] ? hit : nil;
}
- (void)setupShellWithNames:(NSArray<NSString *> *)names restore:(void (^)(NSUInteger))restore {
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.windowLevel = UIWindowLevelNormal + 1;
    DPEdgeShelfSurface *surface = [[DPEdgeShelfSurface alloc] initWithFrame:self.bounds];
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.restore = restore;
    surface.cards = @[];
    UIViewController *controller = [UIViewController new];
    controller.view = surface;
    self.rootViewController = controller;
}
- (void)configureWithNames:(NSArray<NSString *> *)names views:(NSArray *)views
                   restore:(void (^)(NSUInteger))restore
               cardLayout:(void (^)(NSUInteger, CGRect))cardLayout {
    [self setupShellWithNames:names restore:restore];
    DPEdgeShelfSurface *surface = (DPEdgeShelfSurface *)self.rootViewController.view;
    surface.cardLayout = cardLayout;
    NSMutableArray *cards = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; ++i) {
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.tag = i;
        card.accessibilityLabel = names[i];
        card.accessibilityHint = @"恢复悬浮窗";
        [card addTarget:surface action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIView *content = nil;
        id candidate = (i < views.count) ? views[i] : nil;
        if ([candidate isKindOfClass:[UIView class]]) {
            content = candidate;                  // live scene view, embedded directly
            content.contentMode = UIViewContentModeScaleAspectFill;
        } else {
            content = [self fallbackLabelForName:names[i]];
        }
        [self dressContent:content];
        [card addSubview:content];
        [surface addSubview:card];
        [cards addObject:card];
    }
    surface.cards = cards;
    surface.liveViews = views;
}
- (void)configureWithNames:(NSArray<NSString *> *)names images:(NSArray *)images
                   restore:(void (^)(NSUInteger))restore {
    [self setupShellWithNames:names restore:restore];
    DPEdgeShelfSurface *surface = (DPEdgeShelfSurface *)self.rootViewController.view;
    NSMutableArray *cards = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; ++i) {
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.tag = i;
        card.accessibilityLabel = names[i];
        card.accessibilityHint = @"恢复悬浮窗";
        [card addTarget:surface action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIView *content = nil;
        id candidate = (i < images.count) ? images[i] : nil;
        if ([candidate isKindOfClass:[UIImage class]]) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:candidate];
            iv.contentMode = UIViewContentModeScaleAspectFill;
            content = iv;
        } else {
            content = [self fallbackLabelForName:names[i]];
        }
        [self dressContent:content];
        [card addSubview:content];
        [surface addSubview:card];
        [cards addObject:card];
    }
    surface.cards = cards;
    surface.liveViews = @[];   // no embedded views -> layoutSubviews applies perspective
}
- (UILabel *)fallbackLabelForName:(NSString *)name {
    UILabel *label = [UILabel new];
    label.text = name;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 3;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}
- (void)dressContent:(UIView *)content {
    content.backgroundColor = UIColor.blackColor;
    content.clipsToBounds = YES;
    content.userInteractionEnabled = NO;
    content.isAccessibilityElement = NO;
}
@end
