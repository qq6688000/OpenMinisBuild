#import "DPKeyboardRow.h"

// 0.7.129: proper QWERTY layout: 3 letter rows (qwertyuiop / asdfghjkl / shift+zxcvbnm+⌫),
// a bottom row with a space bar, and a 中英 toggle for pinyin suggestions.
// SpringBoard will not route the system keyboard here, so this is hand-drawn.

@interface DPKeyboardRow ()
@property (nonatomic, copy, readwrite) NSString *query;
@property (nonatomic, strong) NSMutableArray<UIButton *> *letterButtons;
@property (nonatomic, strong) UIButton *shiftButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UIButton *spaceButton;
@property (nonatomic, strong) UIButton *langButton;
@property (nonatomic, strong) UILabel *queryLabel;
@property (nonatomic, assign) BOOL shifted;
@property (nonatomic, assign) BOOL pinyinMode;
@end

@implementation DPKeyboardRow

static NSString *const kRow1 = @"qwertyuiop";
static NSString *const kRow2 = @"asdfghjkl";
static NSString *const kRow3 = @"zxcvbnm";

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _query = @"";
        _letterButtons = [NSMutableArray array];
        self.backgroundColor = [UIColor clearColor];
        [self buildUI];
    }
    return self;
}

- (UIButton *)makeKey:(NSString *)title {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.30];
    b.layer.cornerRadius = 5;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    b.layer.shadowRadius = 0;
    return b;
}

- (void)buildUI {
    self.queryLabel = [[UILabel alloc] init];
    self.queryLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.queryLabel.textColor = [UIColor whiteColor];
    self.queryLabel.textAlignment = NSTextAlignmentLeft;
    self.queryLabel.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.queryLabel.layer.cornerRadius = 6;
    self.queryLabel.clipsToBounds = YES;
    [self addSubview:self.queryLabel];

    for (NSString *row in @[kRow1, kRow2, kRow3]) {
        for (NSUInteger i = 0; i < row.length; i++) {
            NSString *ch = [row substringWithRange:NSMakeRange(i, 1)];
            UIButton *b = [self makeKey:ch];
            b.tag = 2000 + (NSInteger)self.letterButtons.count;
            b.accessibilityIdentifier = ch;   // true character, case-independent
            b.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightRegular];
            [b addTarget:self action:@selector(letterTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
            [self.letterButtons addObject:b];
        }
    }

    self.shiftButton = [self makeKey:@"⇧"];
    self.shiftButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
    [self.shiftButton addTarget:self action:@selector(shiftTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.shiftButton];

    self.deleteButton = [self makeKey:@"⌫"];
    self.deleteButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
    [self.deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.deleteButton];

    self.langButton = [self makeKey:@"中"];
    self.langButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.langButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.16];
    [self.langButton addTarget:self action:@selector(langTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.langButton];

    self.spaceButton = [self makeKey:@"空格"];
    self.spaceButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    [self.spaceButton addTarget:self action:@selector(spaceTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.spaceButton];
}

- (CGFloat)keyGap { return 6.0; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 40 || h < 60) return;
    CGFloat gap = [self keyGap];
    CGFloat stripH = 30;
    CGFloat usableH = h - stripH - gap * 4;
    CGFloat rowH = MAX(28, MIN(48, usableH / 4.0));
    CGFloat y = stripH + gap / 2.0;

    self.queryLabel.frame = CGRectMake(gap, 2, w - gap * 2, stripH - 4);

    // row 1: 10 keys full width
    CGFloat unit = (w - gap * 11) / 10.0;   // one key width
    [self layoutRowFrom:0 count:10 unit:unit rowH:rowH y:y x0:gap gap:gap];
    y += rowH + gap;

    // row 2: 9 keys, indented half a key each side
    [self layoutRowFrom:10 count:9 unit:unit rowH:rowH y:y x0:gap + unit / 2.0 + gap / 2.0 gap:gap];
    y += rowH + gap;

    // row 3: shift + 7 letters + delete
    CGFloat shiftW = unit * 1.35;
    self.shiftButton.frame = CGRectMake(gap, y, shiftW, rowH);
    CGFloat x = gap + shiftW + gap;
    for (NSInteger i = 0; i < kRow3.length; i++) {
        UIButton *b = self.letterButtons[17 + i];
        b.frame = CGRectMake(x, y, unit, rowH);
        x += unit + gap;
    }
    CGFloat delW = w - x - gap;
    self.deleteButton.frame = CGRectMake(x, y, MAX(unit * 1.2, delW), rowH);
    y += rowH + gap;

    // row 4: 中英 + space + return-to-filter
    CGFloat langW = unit * 1.3;
    self.langButton.frame = CGRectMake(gap, y, langW, rowH);
    CGFloat spaceX = gap + langW + gap;
    CGFloat spaceW = w - spaceX - gap;
    self.spaceButton.frame = CGRectMake(spaceX, y, MAX(unit * 3, spaceW), rowH);

}

- (void)layoutRowFrom:(NSInteger)startIndex count:(NSInteger)count
                 unit:(CGFloat)unit rowH:(CGFloat)rowH y:(CGFloat)y x0:(CGFloat)x0 gap:(CGFloat)gap {
    CGFloat x = x0;
    for (NSInteger i = 0; i < count; i++) {
        UIButton *b = self.letterButtons[startIndex + i];
        b.frame = CGRectMake(x, y, unit, rowH);
        x += unit + gap;
    }
}

#pragma mark - Actions

- (void)applyShift:(BOOL)shifted {
    self.shifted = shifted;
    for (UIButton *b in self.letterButtons) {
        NSString *ch = b.accessibilityIdentifier ?: @"";
        [b setTitle:shifted ? ch.uppercaseString : ch forState:UIControlStateNormal];
    }
    self.shiftButton.backgroundColor = shifted
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.62]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.16];
}

- (void)shiftTapped {
    // double-tap-free: single tap toggles caps for the next letter only
    [self applyShift:!self.shifted];
}

- (void)letterTapped:(UIButton *)sender {
    NSString *ch = sender.accessibilityIdentifier ?: @"";
    if (self.shifted) {
        ch = ch.uppercaseString;
        [self applyShift:NO];
    }
    self.query = [self.query stringByAppendingString:ch];
    [self notifyChange];
}

- (void)spaceTapped {
    if (self.query.length == 0) return;
    self.query = [self.query stringByAppendingString:@" "];
    [self notifyChange];
}

- (void)deleteTapped {
    if (self.query.length == 0) return;
    self.query = [self.query substringToIndex:self.query.length - 1];
    [self notifyChange];
}

- (void)langTapped {
    // Toggle between latin filtering and the pinyin hint (the app list is sorted
    // by English bundle ids as well, so pinyin only swaps the query display).
    self.pinyinMode = !self.pinyinMode;
    [self.langButton setTitle:self.pinyinMode ? @"拼" : @"中" forState:UIControlStateNormal];
    self.queryLabel.text = self.pinyinMode
        ? [NSString stringWithFormat:@"拼音：%@", self.query]
        : self.query;
}

- (void)notifyChange {
    if (!self.pinyinMode) self.queryLabel.text = self.query;
    if (self.query.length == 0) self.queryLabel.text = @"";
    if (self.onQueryChanged) self.onQueryChanged(self.query);
}

- (void)reset {
    self.query = @"";
    self.pinyinMode = NO;
    [self.langButton setTitle:@"中" forState:UIControlStateNormal];
    [self applyShift:NO];
    [self notifyChange];
}

@end
