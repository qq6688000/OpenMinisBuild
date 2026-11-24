// SPSettings.h / .m — 偏好读取（Carbon 共享域 com.82flex.xine，跟 PV 同口径）+ 运行时开关
#import <Foundation/Foundation.h>

extern NSString *const SPNotifyChanged;

@interface SPSettings : NSObject
@property (class, readonly) BOOL enabled;              // 总开关
@property (class, readonly) BOOL swapOnSecondSwipe;    // 分屏中再次上滑 → 换上面的 App
@property (class, readonly) BOOL haptics;
@property (class, readonly) BOOL keepSnapshots;
@property (class, readonly) double seamThickness;      // 接缝区厚度（pt）
@property (class, readonly) double parkThreshold;      // 挂起触发阈值（屏幕高度比例）
+ (void)startObserving;
@end