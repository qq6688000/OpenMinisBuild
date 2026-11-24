#import <Foundation/Foundation.h>

void SPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *SPLogPath(void);
void SPLogClear(void);

// 加载探针：SpringBoard 里弹一条两秒半的浮条。装完注销后应该看得见，
// 看不见就说明 dylib 压根没被注入，别再猜手势。
void SPShowLoadBanner(NSString *text);