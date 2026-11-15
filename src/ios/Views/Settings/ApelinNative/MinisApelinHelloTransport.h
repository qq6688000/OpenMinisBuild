#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Adapted from Apelin's MIT-licensed XPCEnvelope/AppProtocol; see LICENSE.
// A bounded, one-shot hello probe. Completion runs on the main queue.
@interface MinisApelinHelloTransport : NSObject
- (void)probeWithCompletion:(void (^)(NSData * _Nullable payload, NSError * _Nullable error))completion NS_SWIFT_NAME(probe(completion:));
// Fixed read-only operations; no caller-supplied op, payload, path or descriptor.
- (void)listSDKsWithCompletion:(void (^)(NSData * _Nullable payload, NSError * _Nullable error))completion NS_SWIFT_NAME(listSDKs(completion:));
- (void)toolchainStatusWithCompletion:(void (^)(NSData * _Nullable payload, NSError * _Nullable error))completion NS_SWIFT_NAME(toolchainStatus(completion:));
// SDK naming alias; same fixed request.
- (void)sdkListWithCompletion:(void (^)(NSData * _Nullable payload, NSError * _Nullable error))completion NS_SWIFT_NAME(sdkList(completion:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
