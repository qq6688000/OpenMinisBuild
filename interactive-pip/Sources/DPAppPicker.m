#import "DPAppPicker.h"
#import "DPSettings.h"

static id DPAppValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

@interface DPAppItem : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) UIImage *icon;
@property (nonatomic, assign) BOOL favorite;
@end

@implementation DPAppItem
@end

@interface DPAppPickerCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIView *favBadge;
- (void)configureWithItem:(DPAppItem *)item;
@end

@implementation DPAppPickerCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(12, 4, 52, 52)];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.layer.cornerRadius = 12;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [self.contentView addSubview:self.iconView];

        self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 58, frame.size.width, 28)];
        self.nameLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        self.nameLabel.textColor = [UIColor whiteColor];
        self.nameLabel.textAlignment = NSTextAlignmentCenter;
        self.nameLabel.numberOfLines = 2;
        [self.contentView addSubview:self.nameLabel];

        self.favBadge = [[UIView alloc] initWithFrame:CGRectMake(50, 2, 14, 14)];
        self.favBadge.backgroundColor = [UIColor systemYellowColor];
        self.favBadge.layer.cornerRadius = 7;
        self.favBadge.hidden = YES;
        [self.contentView addSubview:self.favBadge];
    }
    return self;
}

- (void)configureWithItem:(DPAppItem *)item {
    self.nameLabel.text = item.name;
    self.iconView.image = item.icon;
    self.favBadge.hidden = !item.favorite;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = MIN(self.contentView.bounds.size.width - 16, 56);
    self.iconView.frame = CGRectMake((self.contentView.bounds.size.width - side) / 2.0, 6, side, side);
    self.iconView.layer.cornerRadius = side * 0.2237; // iOS icon radius ratio
    self.nameLabel.frame = CGRectMake(2, CGRectGetMaxY(self.iconView.frame) + 4,
                                      self.contentView.bounds.size.width - 4, 28);
    self.favBadge.frame = CGRectMake(CGRectGetMaxX(self.iconView.frame) - 10,
                                     self.iconView.frame.origin.y - 2, 14, 14);
}

@end

@interface DPAppPicker () <UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) NSArray<DPAppItem *> *allItems;
@property (nonatomic, strong) NSArray<DPAppItem *> *filteredItems;
@property (nonatomic, copy) NSArray<NSString *> *favorites;
@property (nonatomic, copy) NSArray<NSString *> *blacklist;
@property (nonatomic, copy, nullable) void (^completion)(NSString * _Nullable);
@property (nonatomic, assign) NSUInteger loadGeneration;
@end

@implementation DPAppPicker

- (void)presentInView:(UIView *)parent
            favorites:(NSArray<NSString *> *)favorites
            blacklist:(NSArray<NSString *> *)blacklist
           completion:(void (^)(NSString * _Nullable))completion {

    self.favorites = favorites ?: @[];
    self.blacklist = blacklist ?: @[];
    self.completion = completion;

    self.container = [[UIView alloc] initWithFrame:parent.bounds];
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent addSubview:self.container];

    self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    self.blur.frame = self.container.bounds;
    self.blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blur.alpha = 0;
    [self.container addSubview:self.blur];

    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelTapped)];
    [self.blur.contentView addGestureRecognizer:dimTap];

    CGFloat sheetH = MIN(parent.bounds.size.height * 0.72, 560);
    self.sheet = [[UIView alloc] initWithFrame:CGRectMake(0, parent.bounds.size.height, parent.bounds.size.width, sheetH)];
    self.sheet.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.sheet.backgroundColor = [UIColor colorWithRed:0.11 green:0.12 blue:0.16 alpha:0.96];
    self.sheet.layer.cornerRadius = 20;
    if (@available(iOS 13.0, *)) {
        self.sheet.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.sheet.clipsToBounds = YES;
    [self.container addSubview:self.sheet];

    // Grabber
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectMake((parent.bounds.size.width - 36) / 2.0, 8, 36, 5)];
    grabber.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    grabber.layer.cornerRadius = 2.5;
    grabber.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.sheet addSubview:grabber];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, parent.bounds.size.width - 100, 24)];
    self.titleLabel.text = @"选择应用";
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.sheet addSubview:self.titleLabel];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.cancelButton.frame = CGRectMake(parent.bounds.size.width - 80, 16, 64, 32);
    self.cancelButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    self.cancelButton.tintColor = [UIColor systemBlueColor];
    [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:self.cancelButton];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(12, 52, parent.bounds.size.width - 24, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = @"搜索应用";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.delegate = self;
    self.searchBar.barStyle = UIBarStyleBlack;
    [self.sheet addSubview:self.searchBar];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.itemSize = CGSizeMake(76, 96);
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 24, 16);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 100, parent.bounds.size.width, sheetH - 100)
                                             collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.collectionView registerClass:[DPAppPickerCell class] forCellWithReuseIdentifier:@"cell"];
    [self.sheet addSubview:self.collectionView];

    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.color = [UIColor whiteColor];
    self.loadingIndicator.center = CGPointMake(CGRectGetMidX(self.collectionView.bounds),
                                                CGRectGetMidY(self.collectionView.bounds));
    self.loadingIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                             UIViewAutoresizingFlexibleRightMargin |
                                             UIViewAutoresizingFlexibleTopMargin |
                                             UIViewAutoresizingFlexibleBottomMargin;
    [self.collectionView addSubview:self.loadingIndicator];

    [self loadApps];

    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.4 options:0 animations:^{
        self.blur.alpha = 1;
        CGRect f = self.sheet.frame;
        f.origin.y = parent.bounds.size.height - sheetH;
        self.sheet.frame = f;
    } completion:nil];
}

- (void)loadApps {
    NSUInteger generation = ++self.loadGeneration;
    [self.loadingIndicator startAnimating];
    self.allItems = @[];
    self.filteredItems = @[];
    [self.collectionView reloadData];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        NSArray<DPAppItem *> *items = [self2 buildAppItems];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self3 = weakSelf;
            if (!self3 || generation != self3.loadGeneration || !self3.container) return;
            UIImage *placeholder = [self3 placeholderIcon];
            for (DPAppItem *item in items) {
                if (!item.icon) item.icon = placeholder;
            }
            self3.allItems = items;
            self3.filteredItems = items;
            [self3.loadingIndicator stopAnimating];
            [self3.collectionView reloadData];
        });
    });
}

- (NSArray<DPAppItem *> *)buildAppItems {
    NSMutableArray<DPAppItem *> *items = [NSMutableArray array];
    NSSet *black = [NSSet setWithArray:self.blacklist];
    NSSet *favs = [NSSet setWithArray:self.favorites];

    // Enumerate installed user apps via LSApplicationWorkspace
    NSArray *apps = [self installedUserApplications];
    for (id proxy in apps) {
        NSString *bid = DPAppValue(proxy, @"applicationIdentifier") ?: DPAppValue(proxy, @"bundleIdentifier");
        if (!bid.length) continue;
        if ([black containsObject:bid]) continue;
        // Skip SpringBoard / system hidden
        if ([bid hasPrefix:@"com.apple.springboard"]) continue;
        if ([DPAppValue(proxy, @"appTags") containsObject:@"hidden"]) continue;

        DPAppItem *item = [[DPAppItem alloc] init];
        item.bundleID = bid;
        item.name = DPAppValue(proxy, @"localizedName") ?: bid;
        item.favorite = [favs containsObject:bid];
        item.icon = [self iconForProxy:proxy];
        [items addObject:item];
    }

    // Sort: favorites first, then alpha
    [items sortUsingComparator:^NSComparisonResult(DPAppItem *a, DPAppItem *b) {
        if (a.favorite != b.favorite) return a.favorite ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    // If enumeration failed (headers missing), seed with common apps so UI is usable
    if (items.count == 0) {
        NSArray *fallback = @[
            @"com.apple.mobilesafari", @"com.apple.mobilemail", @"com.apple.MobileSMS",
            @"com.apple.mobilecal", @"com.apple.mobilenotes", @"com.apple.Maps",
            @"com.apple.Music", @"com.apple.camera", @"com.apple.Preferences",
            @"com.apple.AppStore", @"com.apple.MobileAddressBook", @"com.apple.DocumentsApp"
        ];
        for (NSString *bid in fallback) {
            if ([black containsObject:bid]) continue;
            DPAppItem *item = [[DPAppItem alloc] init];
            item.bundleID = bid;
            NSString *last = [[bid componentsSeparatedByString:@"."] lastObject];
            item.name = last.length ? last.capitalizedString : bid;
            item.favorite = [favs containsObject:bid];
            [items addObject:item];
        }
    }

    return [items copy];
}

- (NSArray *)installedUserApplications {
    Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (!LSApplicationWorkspace) return @[];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [LSApplicationWorkspace performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop
    if ([workspace respondsToSelector:NSSelectorFromString(@"allInstalledApplications")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id result = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
#pragma clang diagnostic pop
        if ([result isKindOfClass:[NSArray class]]) return result;
    }
    if ([workspace respondsToSelector:NSSelectorFromString(@"allApplications")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id result = [workspace performSelector:NSSelectorFromString(@"allApplications")];
#pragma clang diagnostic pop
        if ([result isKindOfClass:[NSArray class]]) return result;
    }
    return @[];
}

- (UIImage *)iconForProxy:(id)proxy {
    // Best-effort; many icon APIs need private headers
    if ([proxy respondsToSelector:NSSelectorFromString(@"icon")]) {
        id icon = DPAppValue(proxy, @"icon");
        if ([icon isKindOfClass:[UIImage class]]) return icon;
    }
    return nil;
}

- (UIImage *)placeholderIcon {
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

#pragma mark - Collection

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView; (void)section;
    return self.filteredItems.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    DPAppPickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:indexPath];
    [cell configureWithItem:self.filteredItems[indexPath.item]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    DPAppItem *item = self.filteredItems[indexPath.item];
    void (^done)(NSString *) = self.completion;
    self.completion = nil;
    [self dismissAnimated:YES];
    if (done) done(item.bundleID);
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    if (searchText.length == 0) {
        self.filteredItems = self.allItems;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(DPAppItem *item, NSDictionary *bindings) {
            (void)bindings;
            return [item.name rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound
                || [item.bundleID rangeOfString:searchText options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        self.filteredItems = [self.allItems filteredArrayUsingPredicate:p];
    }
    [self.collectionView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - Dismiss

- (void)cancelTapped {
    void (^done)(NSString *) = self.completion;
    self.completion = nil;
    [self dismissAnimated:YES];
    if (done) done(nil);
}

- (void)dismissAnimated:(BOOL)animated {
    self.loadGeneration += 1;
    [self.loadingIndicator stopAnimating];
    void (^cleanup)(void) = ^{
        [self.container removeFromSuperview];
        self.container = nil;
    };
    if (!self.container) return;
    if (animated) {
        [UIView animateWithDuration:0.22 animations:^{
            self.blur.alpha = 0;
            CGRect f = self.sheet.frame;
            f.origin.y = self.container.bounds.size.height;
            self.sheet.frame = f;
        } completion:^(BOOL finished) {
            (void)finished;
            cleanup();
        }];
    } else {
        cleanup();
    }
}

@end
