#import <Foundation/Foundation.h>
#import "NativeBuildProvision.h"
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3 && argc != 4) return 2;
    NSString *root = [NSString stringWithUTF8String:argv[2]];
    NSArray *old = [[root stringByAppendingString:@"/"] pathComponents];
    NSString *oldSub = [[old subarrayWithRange:NSMakeRange(1, old.count-1)] componentsJoinedByString:@"/"];
    NSLog(@"ROOT REPRO components=%@ oldSub='%@' oldRejected=%d", old, oldSub, [oldSub hasPrefix:@"/"]);
    NSString *dest = argc == 4 ? [NSString stringWithUTF8String:argv[3]] :
        [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSDictionary *r = NBExtractArchive([NSString stringWithUTF8String:argv[1]], dest, root);
    NSLog(@"FOUNDATION EXTRACT %@", r);
    if (argc == 3) [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    return [r[@"ok"] boolValue] ? 0 : 1;
}}
