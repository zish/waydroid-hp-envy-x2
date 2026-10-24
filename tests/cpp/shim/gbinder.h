/*
 * Stand-in for libgbinder's header, for tests that compile daemon code which
 * includes sensors/hybrisbindertypes.h only for its enums.  Nothing here is
 * marshalled, so the layout does not have to match the real one -- and a test
 * that starts needing the real one should link libgbinder, not grow this file.
 */
#pragma once
#include <stdint.h>

#define GBINDER_FIRST_CALL_TRANSACTION 1

typedef struct gbinder_hidl_string {
    const char* data_str;
    uint32_t len;
    uint8_t owns_buffer;
} gbinder_hidl_string;
