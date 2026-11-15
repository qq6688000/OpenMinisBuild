#include "NativeBuildMachOCore.h"

#include "NativeBuildMachOABI.h"
#include <stdio.h>
#include <string.h>

/* NativeBuildMachOABI.h declares payload-only structs, so sizeof is exactly the
 * command payload. These assertions fail the build if that ever stops being
 * true — the earlier bug (subtracting the 8-byte header twice) silently made
 * every LC_MAIN / LC_CODE_SIGNATURE / LC_BUILD_VERSION parse get skipped. */
#define NB_PAYLOAD_SIZE(t) (sizeof(struct t))
_Static_assert(sizeof(struct entry_point_command) == 16, "LC_MAIN payload must be 16");
_Static_assert(sizeof(struct linkedit_data_command) == 8, "LC_CODE_SIGNATURE payload must be 8");
_Static_assert(sizeof(struct build_version_command) == 16, "LC_BUILD_VERSION payload must be 16");
_Static_assert(sizeof(struct version_min_command) == 8, "LC_VERSION_MIN payload must be 8");
#define NB_PAYLOAD_OK(have, t) ((have) >= NB_PAYLOAD_SIZE(t))

static int nb_read(const unsigned char *data, size_t len, size_t off, void *dst, size_t n)
{
    if (off > len || n > len - off)
        return 0;
    memcpy(dst, data + off, n);
    return 1;
}

/* Code-signature superblock fields are big-endian, unlike the Mach-O headers
 * around them. */
static unsigned nb_be32(const unsigned char *p)
{
    return ((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | (unsigned)p[3];
}

static void nb_filetype(uint32_t t, char *out, size_t cap)
{
    const char *s = "other";
    switch (t) {
        case MH_OBJECT:      s = "object"; break;
        case MH_EXECUTE:     s = "executable"; break;
        case MH_DYLIB:       s = "dylib"; break;
        case MH_BUNDLE:      s = "bundle"; break;
        case MH_DYLINKER:    s = "dylinker"; break;
        case MH_KEXT_BUNDLE: s = "kext"; break;
        default: break;
    }
    snprintf(out, cap, "%s", s);
}

static void nb_fail(NBMachOInfo *o, const char *why)
{
    snprintf(o->error, sizeof(o->error), "%s", why);
    o->valid = false;
}

void NBMachOParse(const void *data, size_t len, NBMachOInfo *out)
{
    memset(out, 0, sizeof(*out));
    snprintf(out->arch, sizeof(out->arch), "unknown");
    snprintf(out->filetype, sizeof(out->filetype), "unknown");
    if (!data) { nb_fail(out, "unreadable"); return; }
    out->exists = true;
    out->size = (unsigned long long)len;

    const unsigned char *p = (const unsigned char *)data;
    struct mach_header_64 h;
    if (!nb_read(p, len, 0, &h, sizeof(h)) || h.magic != MH_MAGIC_64) {
        uint32_t magic = 0;
        if (nb_read(p, len, 0, &magic, sizeof(magic))) {
            if (magic == FAT_MAGIC || magic == FAT_CIGAM) nb_fail(out, "fat_binary_unsupported");
            else if (h.magic == MH_CIGAM_64) nb_fail(out, "big_endian_unsupported");
            else nb_fail(out, "not_macho64");
        } else {
            nb_fail(out, "truncated");
        }
        return;
    }
    snprintf(out->arch, sizeof(out->arch), "%s",
             h.cputype == CPU_TYPE_ARM64 ? "arm64" :
             h.cputype == CPU_TYPE_X86_64 ? "x86_64" : "other");
    nb_filetype(h.filetype, out->filetype, sizeof(out->filetype));
    out->pie = (h.flags & MH_PIE) != 0;

    size_t off = sizeof(h), cmds_end;
    if (h.sizeofcmds > len - off) { nb_fail(out, "load_commands_exceed_file"); return; }
    cmds_end = off + h.sizeofcmds;

    for (uint32_t i = 0; i < h.ncmds; i++) {
        struct load_command lc;
        if (off >= cmds_end || !nb_read(p, len, off, &lc, sizeof(lc))) { nb_fail(out, "bad_load_command"); return; }
        if (lc.cmdsize < sizeof(lc) || lc.cmdsize > cmds_end - off) { nb_fail(out, "bad_cmdsize"); return; }
        size_t body = off + sizeof(lc), body_len = lc.cmdsize - sizeof(lc);

        switch (lc.cmd) {
            case 0xCu: /* LC_LOAD_DYLIB */
            case 0x80000018u: /* LC_LOAD_WEAK_DYLIB */
            case 0x8000001Fu: /* LC_REEXPORT_DYLIB */
            case 0x20u: /* LC_LAZY_LOAD_DYLIB */
            case 0x80000023u: { /* LC_LOAD_UPWARD_DYLIB */
                uint32_t nameoff = 0;
                if (body_len < 16 || !nb_read(p, len, body, &nameoff, 4) ||
                    nameoff < 24 || nameoff >= lc.cmdsize) {
                    nb_fail(out, "bad_dylib_command"); return;
                }
                const unsigned char *name = p + off + nameoff;
                const unsigned char *end = memchr(name, 0, lc.cmdsize - nameoff);
                if (!end || end == name) {
                    nb_fail(out, "bad_dylib_name"); return;
                }
                if ((size_t)(end - name) >= sizeof(out->dependencies[0]) || out->dependency_count >= 32) {
                    out->dependencies_truncated = true;
                } else {
                    memcpy(out->dependencies[out->dependency_count++], name, (size_t)(end - name));
                }
                break;
            }
            case LC_MAIN: {
                struct entry_point_command ep;
                /* cmdsize counts load_command + struct: compare the payload. */
                if (NB_PAYLOAD_OK(body_len, entry_point_command) &&
                    nb_read(p, len, body, &ep, NB_PAYLOAD_SIZE(entry_point_command)))
                    out->has_main = true;
                break;
            }
            case LC_BUILD_VERSION: {
                struct build_version_command bv;
                if (NB_PAYLOAD_OK(body_len, build_version_command) &&
                    nb_read(p, len, body, &bv, NB_PAYLOAD_SIZE(build_version_command))) {
                    if (bv.platform == PLATFORM_IOS) { out->has_ios_build = true; out->min_ios = bv.minos; }
                }
                break;
            }
            case LC_VERSION_MIN_IPHONEOS: {
                struct version_min_command vm;
                if (NB_PAYLOAD_OK(body_len, version_min_command) &&
                    nb_read(p, len, body, &vm, NB_PAYLOAD_SIZE(version_min_command))) {
                    out->has_ios_build = true; out->min_ios = vm.version;
                }
                break;
            }
            case LC_CODE_SIGNATURE: {
                struct linkedit_data_command sg;
                if (NB_PAYLOAD_OK(body_len, linkedit_data_command) &&
                    nb_read(p, len, body, &sg, NB_PAYLOAD_SIZE(linkedit_data_command))) {
                    /* The header alone proves nothing: the named region must lie
                     * inside the file for the signature to be counted. */
                    out->has_code_signature = sg.datasize > 0 && sg.dataoff <= len &&
                                              sg.datasize <= len - sg.dataoff;
                    if (out->has_code_signature) {
                        out->signature_size = sg.datasize;
                        /* SuperBlob length is NOT CodeDirectory length. Walk
                         * the bounded index to primary slot 0 / CSMAGIC_CODEDIRECTORY.
                         * These observations do not verify signature trust. */
                        const unsigned char *sup = (const unsigned char *)data + sg.dataoff;
                        if (sg.datasize >= 12) {
                            unsigned magic = nb_be32(sup);
                            unsigned total = nb_be32(sup + 4);
                            unsigned count = nb_be32(sup + 8);
                            if (magic == 0xFADE0CC0u && total >= 12 && total <= sg.datasize &&
                                count < 64 && count <= (total - 12) / 8) {
                                unsigned directory = 0;
                                bool layout = true;
                                for (unsigned j = 0; j < count; j++) {
                                    unsigned kind = nb_be32(sup + 12 + j * 8);
                                    unsigned offset = nb_be32(sup + 16 + j * 8);
                                    if (offset < 12 + count * 8 || offset > total || total - offset < 8) {
                                        layout = false; break;
                                    }
                                    unsigned length = nb_be32(sup + offset + 4);
                                    if (length < 8 || length > total - offset) { layout = false; break; }
                                    if (kind == 0 && nb_be32(sup + offset) == 0xFADE0C02u)
                                        directory = length;
                                }
                                if (layout) {
                                    out->signature_blobs = count;
                                    out->code_directory_size = directory;
                                }
                            }
                        }
                    }
                }
                break;
            }
            default: break;
        }
        off += lc.cmdsize;
    }
    if (off != cmds_end) { nb_fail(out, "load_command_walk_mismatch"); return; }
    out->valid = true;
}

const char *NBMachOFieldValue(const NBMachOInfo *i, const char *f)
{
    if (!strcmp(f, "arch")) return i->arch;
    if (!strcmp(f, "filetype")) return i->filetype;
    if (!strcmp(f, "has_main")) return i->has_main ? "true" : "false";
    if (!strcmp(f, "has_code_signature")) return i->has_code_signature ? "true" : "false";
    if (!strcmp(f, "pie")) return i->pie ? "true" : "false";
    if (!strcmp(f, "has_ios_build")) return i->has_ios_build ? "true" : "false";
    if (!strcmp(f, "valid")) return i->valid ? "true" : "false";
    return NULL;
}

int NBMachOMatch(const NBMachOInfo *i, const char *f, const char *want)
{
    const char *got = NBMachOFieldValue(i, f);
    if (!got) return -1;
    return strcmp(got, want) == 0 ? 1 : 0;
}
