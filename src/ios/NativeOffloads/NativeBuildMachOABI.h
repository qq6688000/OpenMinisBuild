/* [T-native-build] Mach-O constants used by NativeBuildMachOCore.
 *
 * Defined locally instead of including <mach-o/loader.h> so the very same core
 * file compiles for iOS AND for the Linux host regression. Values are the
 * stable ABI constants from Apple's loader.h; a mismatch here would be a bug,
 * and tests/native-build-macho asserts the sizes against real artifacts.
 */
#ifndef NB_MACHO_ABI_H
#define NB_MACHO_ABI_H

#include <stdint.h>

#define MH_MAGIC_64   0xFEEDFACFu
#define MH_CIGAM_64   0xCFFAEDFEu
#define FAT_MAGIC     0xCAFEBABEu
#define FAT_CIGAM     0xBEBAFECAu

#define MH_OBJECT      0x1u
#define MH_EXECUTE     0x2u
#define MH_DYLIB       0x6u
#define MH_BUNDLE      0x8u
#define MH_DYLINKER    0x7u
#define MH_KEXT_BUNDLE 0xBu

#define CPU_TYPE_X86_64 0x01000007u
#define CPU_TYPE_ARM64  0x0100000Cu

#define MH_PIE 0x200000u

#define LC_REQ_DYLD            0x80000000u
#define LC_MAIN                (0x28u | LC_REQ_DYLD)
#define LC_CODE_SIGNATURE      0x1Du
#define LC_BUILD_VERSION       0x32u
#define LC_VERSION_MIN_IPHONEOS 0x25u

#define PLATFORM_IOS 2u

struct load_command {
    uint32_t cmd;
    uint32_t cmdsize;
};

struct mach_header_64 {
    uint32_t magic;
    uint32_t cputype;
    uint32_t cpusubtype;
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    uint32_t flags;
    uint32_t reserved;
};

/* Payload-only layouts: the 8-byte load_command header is NOT included, so
 * sizeof(struct X) is exactly the payload length of that command. */
/* LC_MAIN payload (16 bytes). */
struct entry_point_command {
    uint64_t entryoff;
    uint64_t stacksize;
};

/* LC_CODE_SIGNATURE payload (16 bytes). */
struct linkedit_data_command {
    uint32_t dataoff;
    uint32_t datasize;
};

/* LC_BUILD_VERSION payload (24 bytes including the 8-byte header). */
struct build_version_command {
    uint32_t platform;
    uint32_t minos;
    uint32_t sdk;
    uint32_t ntools;
};

/* LC_VERSION_MIN_IPHONEOS payload (16 bytes). */
struct version_min_command {
    uint32_t version;
    uint32_t sdk;
};

#endif
