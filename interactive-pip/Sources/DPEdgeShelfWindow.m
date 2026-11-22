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
        id candidate = (i < images.count) ? images[i] : nil;
        UIImage *img = [candidate isKindOfClass:[UIImage class]] ? (UIImage *)candidate : nil;
        UIView *content = [self cardContentForImage:img name:names[i]];
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
    // 0.7.151: the cards used to render as flat blue blocks - the placeholder image
    // (an SF Symbol) was tinted by the default button colour. Give every card a dark
    // rounded surface plus a hairline border, and only draw the icon when we really
    // have one.
    content.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    content.clipsToBounds = YES;
    content.userInteractionEnabled = NO;
    content.isAccessibilityElement = NO;
    content.layer.cornerRadius = 9;
    content.layer.cornerCurve = kCACornerCurveContinuous;
    content.layer.borderWidth = 0.5;
    content.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
}

- (UIView *)cardContentForImage:(nullable UIImage *)image name:(NSString *)name {
    UIView *box = [[UIView alloc] initWithFrame:CGRectZero];

    // dark backdrop so a transparent/missing icon still reads as a card
    UIView *bg = [[UIView alloc] initWithFrame:CGRectZero];
    bg.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [box addSubview:bg];

    if (image) {
        // 0.7.152: a window thumbnail fills the card (ZengNiu look). Only a small
        // App icon would have been inset; tell them apart by aspect ratio.
        CGFloat ratio = image.size.height / MAX(image.size.width, 1.0);
        BOOL isShot = ratio > 1.4;
        UIImageView *iv = [[UIImageView alloc] initWithImage:image];
        iv.backgroundColor = [UIColor clearColor];
        iv.contentMode = isShot ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
        iv.clipsToBounds = YES;
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [box addSubview:iv];
        if (isShot) {
            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
                [iv.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
                [iv.topAnchor constraintEqualToAnchor:box.topAnchor],
                [iv.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
            ]];
        } else {
            [NSLayoutConstraint activateConstraints:@[
                [iv.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
                [iv.centerYAnchor constraintEqualToAnchor:box.centerYAnchor constant:-6],
                [iv.widthAnchor constraintEqualToAnchor:box.widthAnchor multiplier:0.56],
                [iv.heightAnchor constraintEqualToAnchor:iv.widthAnchor],
            ]];
        }
    }

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = name;
    label.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    label.font = [UIFont systemFontOfSize:7.5 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 2;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:2],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-2],
        [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-5],
    ]];
    return box;
}
@end
