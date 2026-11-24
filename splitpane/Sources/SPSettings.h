// SPSettings.h / .m — 偏好读取（Carbon 共享域 com.82flex.xine，跟 PV 同口径）+ 运行时开关
#import <Foundation/Foundation.h>

extern NSString *const SPNotifyChanged;

@interface SPSettings : NSObject
@property (class, readonly) BOOL enabled;              // 总开关
@property (class, readonly) BOOL swapOnSecondSwipe;    // 分屏中再次上滑 → 换上面的 App
@property (class, readonly) BOOL haptics;
@property (class, readonly) BOOL keepSnapshots;
// 安全开关：出问题一格一格关，定位是哪层炸的
@property (class, readonly) BOOL bannerEnabled;      // 加载浮条
@property (class, readonly) BOOL hooksEnabled;       // hook 系统 home 手势（默认关）
@property (class, readonly) BOOL statusTapEnabled;   // 状态栏双击入口
@property (class, readonly) BOOL fallbackPanEnabled; // 自装 pan 备份入口
@property (class, readonly) double seamThickness;      // 接缝区厚度（pt）
@property (class, readonly) double parkThreshold;      // 挂起触发阈值（屏幕高度比例）
+ (void)startObserving;
@end