//
//  patchfinder64.c
//  extra_recipe
//
//  Created by xerub on 06/06/2017.
//  Copyright © 2017 xerub. All rights reserved.
//

#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <TargetConditionals.h>

#define USE_KREAD 0

static bool auth_ptrs = false;
static bool auth_ptrv2 = false;
typedef unsigned long long addr_t;
static addr_t kerndumpbase = -1;
static addr_t xnucore_base = 0;
static addr_t xnucore_size = 0;
static addr_t prelink_base = 0;
static addr_t prelink_size = 0;
static addr_t kernel_entry = 0;
static void *kernel_mh = 0;
static addr_t kernel_delta = 0;
bool monolithic_kernel = false;

#define IS64(image) (*(uint8_t *)(image) & 1)

#define MACHO(p) ((*(unsigned int *)(p) & ~1) == 0xfeedface)

/* generic stuff *************************************************************/

#define UCHAR_MAX 255

/* these operate on VA ******************************************************/

#define INSN_CALL 0x94000000, 0xFC000000
#define INSN_B    0x14000000, 0xFC000000
#define INSN_ADRP 0x90000000, 0x9F000000

/* patchfinder ***************************************************************/

static addr_t
step64(const uint8_t *buf, addr_t start, size_t length, uint32_t what, uint32_t mask)
{
    addr_t end = start + length;
    while (start < end) {
        uint32_t x = *(uint32_t *)(buf + start);
        if ((x & mask) == what) {
            return start;
        }
        start += 4;
    }
    return 0;
}

static addr_t
step64_back(const uint8_t *buf, addr_t start, size_t length, uint32_t what, uint32_t mask)
{
    addr_t end = start - length;
    while (start >= end) {
        uint32_t x = *(uint32_t *)(buf + start);
        if ((x & mask) == what) {
            return start;
        }
        start -= 4;
    }
    return 0;
}

static addr_t
calc64(const uint8_t *buf, addr_t start, addr_t end, int which)
{
    addr_t i;
    uint64_t value[32];
    
    memset(value, 0, sizeof(value));
    
    end &= ~3;
    for (i = start & ~3; i < end; i += 4) {
        uint32_t op = *(uint32_t *)(buf + i);
        unsigned reg = op & 0x1F;
        if ((op & 0x9F000000) == 0x90000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADRP X%d, 0x%llx\n", i, reg, ((long long)adr << 1) + (i & ~0xFFF));
            value[reg] = ((long long)adr << 1) + (i & ~0xFFF);
            /*} else if ((op & 0xFFE0FFE0) == 0xAA0003E0) {
             unsigned rd = op & 0x1F;
             unsigned rm = (op >> 16) & 0x1F;
             //printf("%llx: MOV X%d, X%d\n", i, rd, rm);
             value[rd] = value[rm];*/
        } else if ((op & 0xFF000000) == 0x91000000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned shift = (op >> 22) & 3;
            unsigned imm = (op >> 10) & 0xFFF;
            if (shift == 1) {
                imm <<= 12;
            } else {
                //assert(shift == 0);
                if (shift > 1) continue;
            }
            //printf("%llx: ADD X%d, X%d, 0x%x\n", i, reg, rn, imm);
            value[reg] = value[rn] + imm;
        } else if ((op & 0xF9C00000) == 0xF9400000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 3;
            //printf("%llx: LDR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
            if (!imm) continue;            // XXX not counted as true xref
            value[reg] = value[rn] + imm;    // XXX address, not actual value
        } else if ((op & 0xF9C00000) == 0xF9000000) {
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 3;
            //printf("%llx: STR X%d, [X%d, 0x%x]\n", i, reg, rn, imm);
            if (!imm) continue;            // XXX not counted as true xref
            value[rn] = value[rn] + imm;    // XXX address, not actual value
        } else if ((op & 0x9F000000) == 0x10000000) {
            signed adr = ((op & 0x60000000) >> 18) | ((op & 0xFFFFE0) << 8);
            //printf("%llx: ADR X%d, 0x%llx\n", i, reg, ((long long)adr >> 11) + i);
            value[reg] = ((long long)adr >> 11) + i;
        } else if ((op & 0xFF000000) == 0x58000000) {
            unsigned adr = (op & 0xFFFFE0) >> 3;
            //printf("%llx: LDR X%d, =0x%llx\n", i, reg, adr + i);
            value[reg] = adr + i;        // XXX address, not actual value
        } else if ((op & 0xF9C00000) == 0xb9400000) { // 32bit
            unsigned rn = (op >> 5) & 0x1F;
            unsigned imm = ((op >> 10) & 0xFFF) << 2;
            if (!imm) continue;            // XXX not counted as true xref
            value[reg] = value[rn] + imm;    // XXX address, not actual value
        }
    }
    return value[which];
}

static addr_t
find_call64(const uint8_t *buf, addr_t start, size_t length)
{
    return step64(buf, start, length, INSN_CALL);
}

static addr_t
follow_call64(const uint8_t *buf, addr_t call)
{
    long long w;
    w = *(uint32_t *)(buf + call) & 0x3FFFFFF;
    w <<= 64 - 26;
    w >>= 64 - 26 - 2;
    return call + w;
}

/* kernel iOS10 **************************************************************/

#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef NOT_DARWIN
#include <mach-o/loader.h>
#else
#include "mach-o_loader.h"
#endif

#if USE_KREAD
#include <mach/mach.h>
size_t kread(uint64_t where, void *p, size_t size);
#endif

#ifdef VFS_H_included
#define INVALID_HANDLE NULL
static FHANDLE
OPEN(const char *filename, int oflag)
{
    // XXX use sub_reopen() to handle FAT
    return img4_reopen(file_open(filename, oflag), NULL, 0);
}
#define CLOSE(fd) (fd)->close(fd)
#define READ(fd, buf, sz) (fd)->read(fd, buf, sz)
static ssize_t
PREAD(FHANDLE fd, void *buf, size_t count, off_t offset)
{
    ssize_t rv;
    //off_t pos = fd->lseek(FHANDLE fd, 0, SEEK_CUR);
    fd->lseek(fd, offset, SEEK_SET);
    rv = fd->read(fd, buf, count);
    //fd->lseek(FHANDLE fd, pos, SEEK_SET);
    return rv;
}
#else
#define FHANDLE int
#define INVALID_HANDLE -1
#define OPEN open
#define CLOSE close
#define READ read
#define PREAD pread
#endif

#define NUM_DEADZONES 4
struct tfp0_read_deadzone {
    addr_t start;
    addr_t end;
};

static uint8_t *kernel = NULL;
static size_t kernel_size = 0;

int
init_kernel(addr_t kernel_base, const char *filename)
{
    size_t rv;
    uint8_t buf[0x4000];
    unsigned i;
    const struct mach_header *hdr = (struct mach_header *)buf;
    FHANDLE fd = INVALID_HANDLE;
    const uint8_t *q;
    addr_t min = -1;
    addr_t max = 0;
    int is64 = 0;
    
    struct tfp0_read_deadzone deadzones[NUM_DEADZONES];
    int deadzone_idx = 0;
    
#if USE_KREAD
    if (!kernel_base) {
        return -1;
    }
#else    /* USE_KREAD */
    if (!filename) {
        return -1;
    }
#endif    /* USE_KREAD */
    
    if (filename == NULL) {
#if USE_KREAD
        rv = kread(kernel_base, buf, sizeof(buf));
        if (rv != sizeof(buf) || !MACHO(buf)) {
            return -1;
        }
#else
        return -1;
#endif
    } else {
        fd = OPEN(filename, O_RDONLY);
        if (fd == INVALID_HANDLE) {
            return -1;
        }
        rv = READ(fd, buf, sizeof(buf));
        if (rv != sizeof(buf) || !MACHO(buf)) {
            CLOSE(fd);
            return -1;
        }
    }
    
    if (IS64(buf)) {
        if (hdr->cputype == CPU_TYPE_ARM64 && (hdr->cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) {
            auth_ptrs = true;
            if (hdr->cpusubtype != (hdr->cpusubtype & ~CPU_SUBTYPE_MASK)){
                auth_ptrv2 = true;
            }
        }
        is64 = 4;
    }
    
    q = buf + sizeof(struct mach_header) + is64;
    for (i = 0; i < hdr->ncmds; i++) {
        const struct load_command *cmd = (struct load_command *)q;
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (struct segment_command_64 *)q;
            if (min > seg->vmaddr) {
                if (seg->vmsize > 0) {
                    min = seg->vmaddr;
                } else {
                    // printf("dudmin: %s\n", seg->segname);
                }
            }
            if (max < seg->vmaddr + seg->vmsize) {
                if (seg->vmsize > 0) {
                    max = seg->vmaddr + seg->vmsize;
                } else {
                    // printf("dudmax: %s\n", seg->segname);
                }
            }
            if (!strcmp(seg->segname, "__TEXT_EXEC")) {
                xnucore_base = seg->vmaddr;
                xnucore_size = seg->filesize;
            }
            if (!strcmp(seg->segname, "__PLK_TEXT_EXEC")) {
                prelink_base = seg->vmaddr;
                prelink_size = seg->filesize;
            }
            if (!strcmp(seg->segname, "__KLD") || !strcmp(seg->segname, "__BOOTDATA") || !strcmp(seg->segname, "__PRELINK_INFO") || (!strcmp(seg->segname, "__LINKEDIT") && prelink_size == 0)) {
                deadzones[deadzone_idx].start = seg->vmaddr;
                deadzones[deadzone_idx++].end = seg->vmaddr + seg->vmsize;
                // printf("have deadzone #%d 0x%016llx - 0x%016llx\n", deadzone_idx, seg->vmaddr, seg->vmaddr + seg->vmsize);
            }
        }
        if (cmd->cmd == LC_UNIXTHREAD) {
            uint32_t *ptr = (uint32_t *)(cmd + 1);
            uint32_t flavor = ptr[0];
            struct {
                uint64_t x[29];    /* General purpose registers x0-x28 */
                uint64_t fp;    /* Frame pointer x29 */
                uint64_t lr;    /* Link register x30 */
                uint64_t sp;    /* Stack pointer x31 */
                uint64_t pc;     /* Program counter */
                uint32_t cpsr;    /* Current program status register */
            } *thread = (void *)(ptr + 2);
            if (flavor == 6) {
                kernel_entry = thread->pc;
            }
        }
        q = q + cmd->cmdsize;
    }
    
    if (prelink_size == 0) {
        monolithic_kernel = true;
        prelink_base = xnucore_base;
        prelink_size = xnucore_size;
    }
    
    kerndumpbase = min;
    xnucore_base -= kerndumpbase;
    prelink_base -= kerndumpbase;
    kernel_size = max - min;
    
    if (filename == NULL) {
#if USE_KREAD
#define VALIDATE_KREAD(expect_size) do { if (rv != expect_size) { free(kernel); return -1; } } while(0)
        kernel = calloc(kernel_size, 1);
        if (!kernel) {
            return -1;
        }
        if (deadzone_idx != 0) {
            addr_t final_dz_end = deadzones[deadzone_idx - 1].end - kerndumpbase;
            addr_t outer_sz = deadzones[0].start - kerndumpbase;
            rv = kread(kerndumpbase, kernel, outer_sz);
            VALIDATE_KREAD(outer_sz);
            //fprintf(stderr, "breathe deeply of the poison\n");
            for (int i = 1; i < deadzone_idx; ++i) {
                addr_t adjusted_dz_s = deadzones[i].start - kerndumpbase;
                addr_t adjusted_dz_e = deadzones[i - 1].end - kerndumpbase;
                rv = kread(kerndumpbase + adjusted_dz_e, kernel + adjusted_dz_e, adjusted_dz_s - adjusted_dz_e);
                //fprintf(stderr, "breathe deeply of the poison\n");
                VALIDATE_KREAD(adjusted_dz_s - adjusted_dz_e);
            }
            outer_sz = kernel_size - final_dz_end;
            rv = kread(kerndumpbase + final_dz_end, kernel + final_dz_end, outer_sz);
            //fprintf(stderr, "we survived!\n");
            VALIDATE_KREAD(outer_sz);
        } else {
            rv = kread(kerndumpbase, kernel, kernel_size);
            VALIDATE_KREAD(kernel_size);
        }
        
        kernel_mh = kernel + kernel_base - min;
#undef VALIDATE_KREAD
#endif
    } else {
        kernel = calloc(1, kernel_size);
        if (!kernel) {
            CLOSE(fd);
            return -1;
        }
        
        q = buf + sizeof(struct mach_header) + is64;
        for (i = 0; i < hdr->ncmds; i++) {
            const struct load_command *cmd = (struct load_command *)q;
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (struct segment_command_64 *)q;
                size_t sz = PREAD(fd, kernel + seg->vmaddr - min, seg->filesize, seg->fileoff);
                if (sz != seg->filesize) {
                    CLOSE(fd);
                    free(kernel);
                    return -1;
                }
                if (!kernel_mh) {
                    kernel_mh = kernel + seg->vmaddr - min;
                }
                if (!strcmp(seg->segname, "__LINKEDIT")) {
                    kernel_delta = seg->vmaddr - min - seg->fileoff;
                }
            }
            q = q + cmd->cmdsize;
        }
        
        CLOSE(fd);
    }
    return 0;
}

void
term_kernel(void)
{
    if (kernel != NULL) {
        free(kernel);
        kernel = NULL;
    }
}

addr_t find_cs_blob_reset_cache_armv8(void)
{
    //ldxr w9, [x8]
    //add w9, w9, #0x2
    //stxr w10, w9, [x8]

    addr_t off;
    uint32_t* k;
    k = (uint32_t*)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] == 0x885F7D09 && k[1] == 0x11000929 && k[2] == 0x880A7D09) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t*)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] == 0x885F7D09 && k[1] == 0x11000929 && k[2] == 0x880A7D09) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}

addr_t find_cs_blob_reset_cache_armv81(void)
{
    //orr w9, wzr, #0x2
    //stadd w9, [x8]
    //ret
#define STADDINSTR 0xB829011F

    addr_t off;
    uint32_t* k;
    k = (uint32_t*)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] == 0x321F03E9 && k[1] == STADDINSTR && k[2] == 0xD65F03C0) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t*)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] == 0x321F03E9 && k[1] == STADDINSTR && k[2] == 0xD65F03C0) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}

addr_t find_cs_blob_reset_cache_armv81_2(void)
{
    //movz w9, #0x2
    //ldadd w9, w8, [x8]
    //ret
#define LDADDINSTR 0xB8290108
    
    addr_t off;
    uint32_t* k;
    k = (uint32_t*)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] == 0x52800049 && k[1] == LDADDINSTR && k[2] == 0xD65F03C0) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t*)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] == 0x52800049 && k[1] == LDADDINSTR && k[2] == 0xD65F03C0) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}

addr_t find_cs_blob_generation_count_fallback_adrpfunc(){
    if (!auth_ptrs || !auth_ptrv2){
        // ldr x8, [x19, #0x78]
        // arbitrary (movz w20, #0x51)
        // arbitrary (cbz x8, <offset>)
        // ldr w8, [x8, #0x2c]
        
        addr_t off;
        uint32_t* k;
        k = (uint32_t*)(kernel + xnucore_base);
        for (off = 0; off < xnucore_size - 4; off += 4, k++) {
            if (k[0] == 0xF9403E68 && k[3] == 0xB9402D08) {
                return off + xnucore_base + kerndumpbase + (4 * 4);
            }
        }
        k = (uint32_t*)(kernel + prelink_base);
        for (off = 0; off < prelink_size - 4; off += 4, k++) {
            if (k[0] == 0xF9403E68 && k[3] == 0xB9402D08) {
                return off + prelink_base + kerndumpbase + (4 * 4);
            }
        }
        return 0;
    } else {
        uint32_t instrs[12] = {
            0xF8478D10, // ldr x16, [x8, #0x78]!
            0x0, // arbitrary (cbz x16, <offset to next movz>)
            0xF2E45BC8, // movk x8, #0x22de, lsl #48
            0xAA1003F1, // mov x17, x16
            0xDAC11910, // autda x17, x8
            0xDAC147F1, // xpacd x17
            0xEB11021F, // cmp x16, x17
            0x0, //0x45000040, // b.eq #8
            0xD4388E40, // brk #0xc472
            0x0, // arbitrary (movz w20, #0x51)
            0x0, // arbitrary (cbz x16, <offset>)
            0xB9402E08 // ldr w8, [x16, #0x2c]
        };
        
        addr_t off;
        uint32_t *k;
        k = (uint32_t*)(kernel + xnucore_base);
        for (off = 0; off < xnucore_size - 12; off += 4, k++) {
            bool matched = true;
            for (int i = 0; i < 12; i++){
                if (instrs[i] != 0 && k[i] != instrs[i]){
                    matched = false;
                }
            }
            if (matched){
                return off + xnucore_base + kerndumpbase + (12 * 4);
            }
        }
        k = (uint32_t*)(kernel + prelink_base);
        for (off = 0; off < prelink_size - 12; off += 4, k++) {
            bool matched = true;
            for (int i = 0; i < 12; i++){
                if (instrs[i] != 0 && k[i] != instrs[i]){
                    matched = false;
                }
            }
            if (matched){
                return off + prelink_base + kerndumpbase + (12 * 4);
            }
        }
        return 0;
    }
}

addr_t find_cs_blob_generation_count_fallback(){
    addr_t adrp_func = find_cs_blob_generation_count_fallback_adrpfunc();
    if (!adrp_func){
        return 0;
    }
    addr_t adrp_ins = step64(kernel, adrp_func - kerndumpbase, 4, INSN_ADRP);
    addr_t csblob_reset_cache = calc64(kernel, adrp_ins, adrp_ins + 8, 9);
    return csblob_reset_cache + kerndumpbase;
}

addr_t find_cs_blob_generation_count()
{
    addr_t func = find_cs_blob_reset_cache_armv8(); // A7 -> A10 (12.0 -> 13.5)
    if (!func)
        func = find_cs_blob_reset_cache_armv81(); // A11 -> A13 (12.0 -> 13.3)
    if (!func)
        func = find_cs_blob_reset_cache_armv81_2(); // A11 -> A14 (13.4 -> 14.3)
    if (!func)
        return find_cs_blob_generation_count_fallback(); // 13.0 - 14.3
    addr_t load_gencount = step64_back(kernel, func - kerndumpbase, 5 * 4, INSN_ADRP);
    addr_t csblob_reset_cache = calc64(kernel, load_gencount, load_gencount + 8, 8);
    return csblob_reset_cache + kerndumpbase;
}

addr_t find_vm_remap_kernel_func(void)
{
    addr_t off = 0;
    uint32_t* k;
    k = (uint32_t*)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] ==  0xD10143FF && k[1] == 0xA9034FF4 && k[2] == 0xA9047BFD && k[3] == 0x910103FD && k[4] ==  0xF81E83BF && k[5] == 0x5297F2CA) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t*)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] ==  0xD10143FF && k[1] == 0xA9034FF4 && k[2] == 0xA9047BFD && k[3] == 0x910103FD && k[4] ==  0xF81E83BF && k[5] == 0x5297F2CA) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}

addr_t find_vm_map_remap(void) {
    addr_t vm_remap_kernel_func = find_vm_remap_kernel_func();
    if(!vm_remap_kernel_func) return 0;
    addr_t bl_ins = find_call64(kernel, vm_remap_kernel_func - kerndumpbase, 0x70);
    addr_t vm_map_remap = follow_call64(kernel, bl_ins) + kerndumpbase;
    return vm_map_remap;
}

addr_t find_add_x0_x0_0x40_ret(void) {
    addr_t off;
    uint32_t *k;
    k = (uint32_t *)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] == 0x91010000 && k[1] == 0xD65F03C0) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t *)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] == 0x91010000 && k[1] == 0xD65F03C0) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}

addr_t find_bcopy(void) {
    // Jumps straight into memmove after switching x0 and x1 around
    // Guess we just find the switch and that's it
    addr_t off;
    uint32_t *k;
    k = (uint32_t *)(kernel + xnucore_base);
    for (off = 0; off < xnucore_size - 4; off += 4, k++) {
        if (k[0] == 0xAA0003E3 && k[1] == 0xAA0103E0 && k[2] == 0xAA0303E1 && k[3] == 0xd503201F) {
            return off + xnucore_base + kerndumpbase;
        }
    }
    k = (uint32_t *)(kernel + prelink_base);
    for (off = 0; off < prelink_size - 4; off += 4, k++) {
        if (k[0] == 0xAA0003E3 && k[1] == 0xAA0103E0 && k[2] == 0xAA0303E1 && k[3] == 0xd503201F) {
            return off + prelink_base + kerndumpbase;
        }
    }
    return 0;
}
#if !TARGET_OS_IPHONE
int
main(int argc, char **argv)
{
    if (argc < 2) {
        printf("Usage: patchfinder64 _decompressed_kernel_image_\n");
        printf("iOS ARM64 kernel patchfinder\n");
        exit(EXIT_FAILURE);
    }
    addr_t kernel_base = 0;
    if (init_kernel(kernel_base, argv[1]) != 0) {
        printf("Failed to prepare kernel\n");
        exit(EXIT_FAILURE);
    }
    printf("cs_blob_generation_count: 0x%llx\n", find_cs_blob_generation_count());
    printf("find_cs_blob_generation_count_fallback: 0x%llx\n", find_cs_blob_generation_count_fallback());
    printf("find_vm_remap_kernel_func: 0x%llx\n", find_vm_remap_kernel_func());
    printf("find_vm_map_remap: 0x%llx\n", find_vm_map_remap());
    printf("find_add_x0_x0_0x40_ret: 0x%llx\n", find_add_x0_x0_0x40_ret());
    printf("find_bcopy: 0x%llx\n", find_bcopy());
    return 0;
}
#endif
