// Minimal Preferences.framework stubs for compiling PreferenceBundles
// against a public iOS SDK (CI / clean Theos). On device the real
// Preferences.framework is loaded by Settings.app.

#import <UIKit/UIKit.h>

@class PSSpecifier;

@interface PSViewController : UIViewController
- (void)pushController:(id)controller;
@end

@interface PSListController : PSViewController {
    NSArray *_specifiers;
}
@property (nonatomic, retain) NSArray *specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target bundle:(NSBundle *)bundle;
- (PSSpecifier *)specifierForID:(NSString *)identifier;
- (PSSpecifier *)specifierAtIndex:(NSInteger)index;
- (NSInteger)indexOfSpecifier:(PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)reloadSpecifierAtIndex:(NSInteger)index;
- (void)reloadSpecifierID:(NSString *)identifier;
- (void)reloadSpecifiers;
- (void)removeSpecifier:(PSSpecifier *)specifier;
- (void)removeSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)removeSpecifierAtIndex:(NSInteger)index;
- (void)removeSpecifierID:(NSString *)identifier;
- (void)addSpecifier:(PSSpecifier *)specifier;
- (void)addSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index;
- (void)insertSpecifier:(PSSpecifier *)specifier afterSpecifier:(PSSpecifier *)after;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (UITableView *)table;
- (PSSpecifier *)specifier;
@end
