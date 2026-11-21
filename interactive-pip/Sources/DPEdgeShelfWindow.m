#import "DPEdgeShelfWindow.h"
#import "DPEdgeShelfGeometry.h"

// Visual/interaction reference: ZengNiu (曾牛分屏 v1.7.4), Sources/ZNSEdgeShelf.m
// and ZNSWindowManagerPart02/03.inc. Adapted to Duo's paired cached previews.
@interface DPEdgeShelfSurface : UIView
@property (nonatomic, copy) NSArray<UIButton *> *cards;
@property (nonatomic, copy) void (^restore)(NSUInteger index);
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
        UIView *preview = card.subviews.firstObject;
        preview.bounds = card.bounds;
        preview.center = CGPointMake(r.width / 2, r.height / 2);
        preview.layer.cornerRadius = MIN(11, r.width * .2);
        CATransform3D camera = CATransform3DIdentity;
        if (!UIAccessibilityIsReduceMotionEnabled() && r.width >= 1) {
            camera.m34 = -1.0 / (3 * r.width);
            camera = CATransform3DScale(camera, .96, .96, 1);
            camera = CATransform3DRotate(camera, (landscape ? 18 : 12) * M_PI / 180, 0, 1, 0);
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        preview.layer.transform = camera;
        [CATransaction commit];
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
- (void)configureWithNames:(NSArray<NSString *> *)names images:(NSArray *)images
                   restore:(void (^)(NSUInteger))restore {
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.windowLevel = UIWindowLevelNormal + 1;
    DPEdgeShelfSurface *surface = [[DPEdgeShelfSurface alloc] initWithFrame:self.bounds];
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.restore = restore;
    NSMutableArray *cards = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; ++i) {
        UIButton *card = [UIButton buttonWithType:UIButtonTypeCustom];
        card.tag = i;
        card.accessibilityLabel = names[i];
        card.accessibilityHint = @"恢复双应用分屏";
        [card addTarget:surface action:@selector(cardTapped:) forControlEvents:UIControlEventTouchUpInside];
        id image = i < images.count ? images[i] : nil;
        UIView *preview;
        if ([image isKindOfClass:UIImage.class]) {
            UIImageView *thumb = [[UIImageView alloc] initWithImage:image];
            thumb.contentMode = UIViewContentModeScaleAspectFill;
            preview = thumb;
        } else {
            UILabel *label = [UILabel new];
            label.text = names[i];
            label.textColor = UIColor.whiteColor;
            label.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
            label.textAlignment = NSTextAlignmentCenter;
            label.numberOfLines = 3;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            preview = label;
        }
        preview.backgroundColor = UIColor.blackColor;
        preview.clipsToBounds = YES;
        preview.userInteractionEnabled = NO;
        preview.isAccessibilityElement = NO;
        [card addSubview:preview];
        [surface addSubview:card];
        [cards addObject:card];
    }
    surface.cards = cards;
    // No transparent button/control covering gaps or the rest of SpringBoard.
    UIViewController *controller = [UIViewController new];
    controller.view = surface;
    self.rootViewController = controller;
}
@end
