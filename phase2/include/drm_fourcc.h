/*
 * Minimal stand-in for libdrm's <drm_fourcc.h>.
 *
 * The kernel/libdrm header pulls in a chain (drm.h -> drm_mode.h -> ...) that is
 * not worth vendoring for the fourteen constants gbm_mesa_wrapper.cpp actually
 * uses. Every one of them is defined here as an alias of the *same* fourcc in
 * Mesa's gbm.h, which the build fetches upstream.
 *
 * Aliasing rather than transcribing the fourcc literals is deliberate: the
 * wrapper's table is built with
 *     #define DRM_TO_GBM_FORMAT(A) { DRM_##A, GBM_##A }
 * so defining DRM_FORMAT_X as GBM_FORMAT_X makes each pair identical by
 * construction. There is no opportunity to fat-finger a fourcc, and it matches
 * the real headers, where both sides are the same DRM fourcc anyway.
 *
 * phase2/build.sh verifies the resulting table byte-for-byte against the table
 * in the shipped /vendor/lib64/libgbm_mesa_wrapper.so, so this is checked, not
 * merely asserted.
 */
#pragma once

#include <gbm.h>

#define DRM_FORMAT_R8             GBM_FORMAT_R8
#define DRM_FORMAT_GR88           GBM_FORMAT_GR88
#define DRM_FORMAT_ARGB1555       GBM_FORMAT_ARGB1555
#define DRM_FORMAT_RGB565         GBM_FORMAT_RGB565
#define DRM_FORMAT_XRGB8888       GBM_FORMAT_XRGB8888
#define DRM_FORMAT_ARGB8888       GBM_FORMAT_ARGB8888
#define DRM_FORMAT_XBGR8888       GBM_FORMAT_XBGR8888
#define DRM_FORMAT_ABGR8888       GBM_FORMAT_ABGR8888
#define DRM_FORMAT_XRGB2101010    GBM_FORMAT_XRGB2101010
#define DRM_FORMAT_XBGR2101010    GBM_FORMAT_XBGR2101010
#define DRM_FORMAT_ARGB2101010    GBM_FORMAT_ARGB2101010
#define DRM_FORMAT_ABGR2101010    GBM_FORMAT_ABGR2101010
#define DRM_FORMAT_XBGR16161616F  GBM_FORMAT_XBGR16161616F
#define DRM_FORMAT_ABGR16161616F  GBM_FORMAT_ABGR16161616F

#define DRM_FORMAT_MOD_LINEAR     0ULL
