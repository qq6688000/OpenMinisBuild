// SPLog.h — 统一的真机日志：NSLog + 落盘 /var/mobile/Library/Logs/SplitPane.log
// 真机排查全靠它；写盘做了 0.4s 节流，不会拖慢 SpringBoard。
#import <Foundation/Foundation.h>

void SPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *SPLogPath(void);
void SPLogClear(void);