#import "DPKeyboardRow.h"

// 0.7.128: SpringBoard never routes the system keyboard into our overlay/presented
// windows (the caret shows up, no keyboard). Instead of fighting it, the picker
// types through this self-drawn keyboard: a-z + 0-9 grid + delete, updating the
// filter as you go.

@interface DPKeyboardRow ()
@property (nonatomic, copy, readwrite) NSString *query;
@property (nonatomic, strong) NSMutableArray<UIButton *> *keyButtons;
@property (nonatomic, strong) UILabel *queryLabel;
@end

@implementation DPKeyboardRow

static NSString *const kLetters = @"abcdefghijklmnopqrstuvwxyz0123456789";

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _query = @"";
        _keyButtons = [NSMutableArray array];
        self.backgroundColor = [UIColor clearColor];
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    self.queryLabel = [[UILabel alloc] init];
    self.queryLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
    self.queryLabel.textColor = [UIColor whiteColor];
    self.queryLabel.textAlignment = NSTextAlignmentCenter;
    self.queryLabel.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10];
    self.queryLabel.layer.cornerRadius = 8;
    self.queryLabel.clipsToBounds = YES;
    [self addSubview:self.queryLabel];

    for (NSUInteger i = 0; i < kLetters.length; i++) {
        NSString *ch = [kLetters substringWithRange:NSMakeRange(i, 1)];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:ch forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
        b.layer.cornerRadius = 6;
        b.tag = 1000 + (NSInteger)i;
        [b addTarget:self action:@selector(keyTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:b];
        [self.keyButtons addObject:b];
    }

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    [del setTitle:@"⌫" forState:UIControlStateNormal];
    del.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    del.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
    del.layer.cornerRadius = 6;
    del.tag = 999;
    [del addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:del];
    [self.keyButtons addObject:del];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 10 || h < 10) return;

    // four rows of 10 keys, plus the query strip on top
    CGFloat stripH = 26;
    CGFloat gap = 4;
    CGFloat cols = 10;
    CGFloat rows = 4;
    CGFloat keyW = (w - gap * (cols + 1)) / cols;
    CGFloat keyH = (h - stripH - gap * (rows + 1)) / rows;
    keyW = MIN(keyW, 34);
    keyH = MIN(keyH, 34);

    CGFloat totalW = keyW * cols + gap * (cols - 1);
    CGFloat startX = (w - totalW) / 2.0;

    self.queryLabel.frame = CGRectMake(startX, 2, MIN(totalW, w - 12), stripH - 4);

    CGFloat y0 = stripH + gap;
    NSInteger n = (NSInteger)kLetters.length;
    for (NSInteger i = 0; i < n; i++) {
        NSInteger row = i / (NSInteger)cols;
        NSInteger col = i % (NSInteger)cols;
        UIButton *b = self.keyButtons[i];
        b.frame = CGRectMake(startX + col * (keyW + gap), y0 + row * (keyH + gap), keyW, keyH);
    }
    UIButton *del = self.keyButtons.lastObject;
    CGFloat delW = keyW * 1.6;
    del.frame = CGRectMake(startX + totalW - delW, y0 + (rows - 1) * (keyH + gap), delW, keyH);
    // the last few letter keys sit under the delete key; shrink that row's tail
    for (NSInteger i = n - 2; i < n; i++) {
        UIButton *b = self.keyButtons[i];
        CGRect f = b.frame;
        f.size.width = MAX(0, f.size.width - delW * 0.6);
        b.frame = f;
    }
}

- (void)keyTapped:(UIButton *)sender {
    NSInteger idx = sender.tag - 1000;
    if (idx < 0 || idx >= (NSInteger)kLetters.length) return;
    NSString *ch = [kLetters substringWithRange:NSMakeRange((NSUInteger)idx, 1)];
    self.query = [self.query stringByAppendingString:ch];
    [self notifyChange];
}

- (void)deleteTapped {
    if (self.query.length == 0) return;
    self.query = [self.query substringToIndex:self.query.length - 1];
    [self notifyChange];
}

- (void)notifyChange {
    self.queryLabel.text = self.query;
    if (self.onQueryChanged) self.onQueryChanged(self.query);
}

- (void)reset {
    self.query = @"";
    [self notifyChange];
}

@end
