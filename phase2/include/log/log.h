/*
 * Minimal stand-in for AOSP's <log/log.h>, enough for gbm_mesa_wrapper.cpp.
 *
 * ALOGV is a no-op deliberately: the shipped /vendor/lib64/libgbm_mesa_wrapper.so
 * contains no ALOGV format strings (e.g. "fallback to gbm_bo_create without
 * modifiers" is absent), so it was built with LOG_NDEBUG at its default of 1.
 * Matching that keeps the rebuild faithful.
 *
 * ALOGE maps to __android_log_print at ANDROID_LOG_ERROR (6), which is exactly
 * what the shipped binary does -- its call sites load $0x6 into %edi.
 */
#pragma once

#include <android/log.h>

#ifndef LOG_TAG
#define LOG_TAG NULL
#endif

#define ALOGE(...) ((void)__android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__))
#define ALOGW(...) ((void)__android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__))
#define ALOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__))
#define ALOGD(...) ((void)__android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__))
#define ALOGV(...) ((void)0)
