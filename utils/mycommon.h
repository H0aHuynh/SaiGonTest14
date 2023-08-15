//
//  mycommon.h
//  ios-fuzzer
//
//  Created by Quote on 2021/1/26.
//  Copyright © 2021 Quote. All rights reserved.
//

#ifndef mycommon_h
#define mycommon_h

#define __FILENAME__ (__builtin_strrchr(__FILE__, '/') ? __builtin_strrchr(__FILE__, '/') + 1 : __FILE__)
#define _assert(test, message, fatal) do \
if (!(test)) { \
int saved_errno = errno; \
LOG("__assert(%d:%s)@%s:%u[%s]", saved_errno, #test, __FILENAME__, __LINE__, __FUNCTION__); \
} \
while (false)


#include <stdint.h>
#include <stdbool.h>

#define arrayn(array) (sizeof(array)/sizeof((array)[0]))

typedef uint64_t kptr_t; // 64 bit CPU only

struct exploit_common_s {
    bool debug;
    bool has_PAC;
    const char *model;
    const char *osversion;
    const char *osproductversion;
    const char *machine;
    const char *kern_version;

    int64_t physmemsize;
    uint64_t pagesize;

    kptr_t kernel_base;
    kptr_t kernel_task;
    kptr_t kernel_map;
    kptr_t kernel_proc;
    kptr_t self_proc;
    kptr_t self_task;
    kptr_t self_ipc_space;
    kptr_t kernel_slide;
    kptr_t text_slide;
    kptr_t data_slide;
    kptr_t zone_array;
    uint32_t num_zones;
};

extern struct exploit_common_s g_exp;
void sys_init(void);
void print_os_details(void);

#endif /* mycommon_h */
