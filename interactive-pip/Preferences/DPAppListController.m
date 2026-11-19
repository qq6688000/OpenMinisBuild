#import "vendor/include/Preferences/PSListController.h"
#import "vendor/include/Preferences/PSSpecifier.h"
#import <notify.h>

@interface DPAppListController : PSListController
@property (nonatomic, copy) NSString *listType;
@property (nonatomic, strong) NSMutableArray<NSString *> *bundleIDs;
@end

@implementation DPAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.listType = [self.specifier propertyForKey:@"listType"] ?: @"favorites";
    self.title = [self.listType isEqualToString:@"favorites"] ? @"收藏" : @"黑名单";

    NSArray *stored = (NSArray *)CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)self.listType, CFSTR("com.dualpane.tweak")));
    self.bundleIDs = [stored isKindOfClass:[NSArray class]] ? [stored mutableCopy] : [NSMutableArray array];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(addBundleID)];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:
                              ([self.listType isEqualToString:@"favorites"]
                               ? @"收藏的应用会优先显示在选择器中。"
                               : @"黑名单中的应用无法用悬浮窗打开。")
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:Nil
                                                              cell:PSGroupCell
                                                              edit:Nil];
        [specs addObject:group];

        for (NSString *bid in self.bundleIDs) {
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:bid
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:Nil
                                                                 cell:PSTitleValueCell
                                                                 edit:Nil];
            [spec setProperty:bid forKey:@"bundleID"];
            [specs addObject:spec];
        }

        if (self.bundleIDs.count == 0) {
            PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"（空 — 点右上角 + 添加）"
                                                                target:self
                                                                   set:NULL
                                                                   get:NULL
                                                                detail:Nil
                                                                  cell:PSStaticTextCell
                                                                  edit:Nil];
            [specs addObject:empty];
        }

        _specifiers = specs;
    }
    return _specifiers;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.row < (NSInteger)self.bundleIDs.count) {
        return UITableViewCellEditingStyleDelete;
    }
    return UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.row < (NSInteger)self.bundleIDs.count) {
        [self.bundleIDs removeObjectAtIndex:indexPath.row];
        [self persist];
        [self reloadSpecifiers];
    }
}

- (void)addBundleID {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加应用"
                                                                   message:@"输入应用 Bundle ID\n例如：com.apple.mobilesafari"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"com.example.app";
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        NSString *bid = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bid.length == 0) return;
        if (![self.bundleIDs containsObject:bid]) {
            [self.bundleIDs addObject:bid];
            [self persist];
            [self reloadSpecifiers];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)persist {
    CFPreferencesSetAppValue((__bridge CFStringRef)self.listType,
                             (__bridge CFPropertyListRef)self.bundleIDs,
                             CFSTR("com.dualpane.tweak"));
    CFPreferencesAppSynchronize(CFSTR("com.dualpane.tweak"));
    notify_post("com.dualpane.tweak/settings.changed");
}

@end
