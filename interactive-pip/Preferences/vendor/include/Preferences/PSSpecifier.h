// Minimal PSSpecifier stub for public-SDK builds.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell,
    PSLinkCell,
    PSLinkListCell,
    PSListItemCell,
    PSTitleValueCell,
    PSSliderCell,
    PSSwitchCell,
    PSStaticTextCell,
    PSEditTextCell,
    PSSegmentCell,
    PSGiantIconCell,
    PSGiantCell,
    PSSecureEditTextCell,
    PSButtonCell,
    PSEditTextViewCell,
};

@interface PSSpecifier : NSObject
@property (nonatomic, retain) id target;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *identifier;
@property (nonatomic) SEL getter;
@property (nonatomic) SEL setter;
@property (nonatomic) SEL action;
@property (nonatomic) Class detailControllerClass;
@property (nonatomic) PSCellType cellType;
@property (nonatomic, retain) Class editPaneClass;
@property (nonatomic, retain) NSMutableDictionary *properties;
@property (nonatomic, retain) NSDictionary *userInfo;
@property (nonatomic, retain) NSArray *values;
@property (nonatomic, retain) NSArray *titleDictionary;
@property (nonatomic, retain) NSArray *shortTitleDictionary;

+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cellType
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)deleteButtonSpecifierWithName:(NSString *)name target:(id)target action:(SEL)action;

- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)removePropertyForKey:(NSString *)key;
@end
