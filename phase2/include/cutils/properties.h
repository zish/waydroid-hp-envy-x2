/*
 * Minimal stand-in for AOSP's <cutils/properties.h>. gbm_mesa_wrapper.cpp uses
 * only property_get() and PROPERTY_VALUE_MAX, to read waydroid.modifiers.*.
 * Resolved at load time from the device's real libcutils.so.
 */
#pragma once

#define PROPERTY_VALUE_MAX 92

#ifdef __cplusplus
extern "C" {
#endif

int property_get(const char *key, char *value, const char *default_value);

#ifdef __cplusplus
}
#endif
