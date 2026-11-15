#ifndef MINIS_NATIVE_BUILD_OFFLOAD_H
#define MINIS_NATIVE_BUILD_OFFLOAD_H

/* Registers the `minis-native-build` command with the iSH kernel. Called once
 * at kernel init (ISHKernel.m). Declared extern "C" so an Objective-C++ or C++
 * translation unit can include this header without mangling the symbol. */
#ifdef __cplusplus
extern "C" {
#endif

void native_build_offload_register(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, NBLocalToolchainOperation) {
    NBLocalToolchainOperationInspect = 0,
    NBLocalToolchainOperationProvision = 1,
    NBLocalToolchainOperationProbe = 2
};
@interface MinisNativeLocalToolchain : NSObject
- (void)performOperation:(NBLocalToolchainOperation)operation
              completion:(void (^)(NSDictionary *result))completion NS_SWIFT_NAME(perform(operation:completion:));
@end
// Structured UI adapter to the same NBPRun backend as minis-native-build.
// Input is an already validated, immutable ObjC template source snapshot.
@interface MinisNativeCLICompile : NSObject
- (void)compileSource:(NSData *)source
              output:(void (^)(NSData *chunk))output
          completion:(void (^)(NSDictionary *result))completion NS_SWIFT_NAME(compile(source:output:completion:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
#endif

#endif /* MINIS_NATIVE_BUILD_OFFLOAD_H */
