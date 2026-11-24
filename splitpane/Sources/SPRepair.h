#import <Foundation/Foundation.h>

// 一键修复：把所有被我们改过尺寸的 scene 恢复成全屏。
// 用在「退出分屏后 App 黑屏/灰屏、桌面也点不了」这种残留状态上。
@interface SPRepair : NSObject
+ (void)restoreAllScenes;
+ (NSString *)lastReport;
@end

// 诊断函数
void SPDumpScenes(const char *tag);
