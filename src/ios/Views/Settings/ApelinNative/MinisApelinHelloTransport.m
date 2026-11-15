// Adapted from Apelin (Copyright 2026 OwnGoal Studio), MIT; see LICENSE.
#import "MinisApelinHelloTransport.h"
#import "MinisApelinXPCPrivate.h"

@implementation MinisApelinHelloTransport {
    dispatch_queue_t _queue;
    xpc_connection_t _connection;
    void (^_completion)(NSData *, NSError *);
    NSUInteger _generation;
}
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("com.openminis.apelin.hello", DISPATCH_QUEUE_SERIAL);
    return self;
}
static NSError *HelloError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MinisApelinHello" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}
- (void)finish:(NSData *)data error:(NSError *)error {
    // All state, including the timeout/reply race, is confined to _queue.
    if (!_completion) return;
    void (^completion)(NSData *, NSError *) = _completion;
    _completion = nil;
    if (_connection) { xpc_connection_cancel(_connection); _connection = nil; }
    dispatch_async(dispatch_get_main_queue(), ^{ completion(data, error); });
}
- (void)cancel {
    dispatch_async(_queue, ^{
        self->_generation++;
        [self finish:nil error:HelloError(6, @"检查已取消")];
    });
}
- (void)probeWithCompletion:(void (^)(NSData *, NSError *))completion {
    dispatch_async(_queue, ^{
        [self finish:nil error:HelloError(6, @"检查已替换")];
        NSUInteger generation = ++self->_generation;
        self->_completion = [completion copy];
        self->_connection = xpc_connection_create_mach_service("wiki.qaq.apelin.service", self->_queue, 0);
        if (!self->_connection) {
            [self finish:nil error:HelloError(1, @"服务不可用：无法创建连接")];
            return;
        }
        // Reply errors are classified below; no Swift XPC overlay dependency.
        xpc_connection_set_event_handler(self->_connection, ^(xpc_object_t event) {});
        xpc_connection_activate(self->_connection);
        NSString *requestID = NSUUID.UUID.UUIDString;
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, "op", "hello");
        xpc_dictionary_set_int64(request, "protocolVersion", 2);
        xpc_dictionary_set_string(request, "requestID", requestID.UTF8String);
        xpc_dictionary_set_data(request, "payload", "{}", 2);
        xpc_connection_send_message_with_reply(self->_connection, request, self->_queue, ^(xpc_object_t reply) {
            if (generation != self->_generation || !self->_completion) return;
            if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
                [self finish:nil error:HelloError(1, @"服务不可用或连接被拒绝；XPC 无法区分未安装、沙盒限制与 peer 认证失败")];
                return;
            }
            if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
                [self finish:nil error:HelloError(3, @"服务响应不是 XPC 字典")]; return;
            }
            xpc_object_t ok = xpc_dictionary_get_value(reply, "ok");
            const char *rid = xpc_dictionary_get_string(reply, "requestID");
            if (!ok || xpc_get_type(ok) != XPC_TYPE_BOOL || !rid) {
                [self finish:nil error:HelloError(3, @"服务响应缺少请求标识或布尔状态")]; return;
            }
            BOOL success = xpc_bool_get_value(ok);
            // Upstream version rejection is produced before it decodes requestID.
            xpc_object_t detail = xpc_dictionary_get_value(reply, "error");
            const char *code = detail && xpc_get_type(detail) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_string(detail, "code") : NULL;
            BOOL versionFailure = !success && code && strcmp(code, "unsupportedVersion") == 0 && rid[0] == '\0';
            if (strcmp(rid, requestID.UTF8String) != 0 && !versionFailure) {
                [self finish:nil error:HelloError(3, @"服务响应的 requestID 不匹配")]; return;
            }
            if (!success) {
                if (!code) { [self finish:nil error:HelloError(3, @"服务错误响应缺少 code")]; return; }
                const char *message = xpc_dictionary_get_string(detail, "message");
                const char *reason = xpc_dictionary_get_string(detail, "reason");
                NSInteger status = strcmp(code, "denied") == 0 ? 4 : (strcmp(code, "unsupportedVersion") == 0 ? 5 : 7);
                NSString *text = [NSString stringWithFormat:@"服务返回 %s：%s%s%s", code, message ?: "", reason ? " / " : "", reason ?: ""];
                [self finish:nil error:HelloError(status, text)]; return;
            }
            size_t length = 0;
            const void *bytes = xpc_dictionary_get_data(reply, "payload", &length);
            xpc_object_t fds = xpc_dictionary_get_value(reply, "fds");
            if (!bytes || length == 0 || length > 262144 || (fds && (xpc_get_type(fds) != XPC_TYPE_ARRAY || xpc_array_get_count(fds) != 0))) {
                [self finish:nil error:HelloError(3, @"hello payload 缺失、超限或含意外描述符")]; return;
            }
            [self finish:[NSData dataWithBytes:bytes length:length] error:nil];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self->_queue, ^{
            if (generation == self->_generation) [self finish:nil error:HelloError(2, @"hello 等待超时（5 秒）；未确认服务身份或能力")];
        });
    });
}
@end
