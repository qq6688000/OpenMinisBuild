/* [T-native-build] Objective-C wrapper over the pure-C core.
 *
 * The parsing rules live in NativeBuildMachOCore.c so the same code is executed
 * by the host regression (tests/native-build-macho). Do not re-implement them
 * here: a second copy is how a gate silently stops matching reality.
 */
#include "NativeBuildMachOCore.h"

NSDictionary *NBMachOInspect(NSString *path)
{
    NSMutableDictionary *out = [@{
        @"path": path ?: @"", @"exists": @NO, @"valid": @NO,
        @"size": @0, @"arch": @"unknown", @"filetype": @"unknown",
        @"pie": @NO, @"has_main": @NO, @"has_ios_build": @NO,
        @"min_ios": @"", @"has_code_signature": @NO, @"signature_size": @0,
        @"error": @""
    } mutableCopy];

    NSData *d = path.length ? [NSData dataWithContentsOfFile:path
                                                     options:NSDataReadingMappedIfSafe
                                                       error:nil] : nil;
    NBMachOInfo info;
    if (!d) {
        NBMachOParse(NULL, 0, &info);
    } else {
        NBMachOParse(d.bytes, (size_t)d.length, &info);
    }

    out[@"exists"] = @(info.exists);
    out[@"valid"] = @(info.valid);
    out[@"size"] = @(info.size);
    out[@"arch"] = @(info.arch);
    out[@"filetype"] = @(info.filetype);
    out[@"pie"] = @(info.pie);
    out[@"has_main"] = @(info.has_main);
    out[@"has_ios_build"] = @(info.has_ios_build);
    out[@"has_code_signature"] = @(info.has_code_signature);
    out[@"signature_size"] = @(info.signature_size);
    out[@"error"] = @(info.error);
    if (info.has_ios_build) {
        unsigned v = info.min_ios;
        out[@"min_ios"] = [NSString stringWithFormat:@"%u.%u", v >> 16, (v >> 8) & 0xFF];
    }
    return out;
}
