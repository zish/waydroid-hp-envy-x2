/*
 * Lights -- an android.hardware.light@2.0::ILight server, served from the host.
 *
 * bigtab01-waydroid.  See Backlight.h for why Android's brightness reaches
 * this interface at all, and build.sh for why it lives inside a binary called
 * waydroid-sensord.
 *
 * THE WIRE FORMAT IS DISASSEMBLED, NOT REMEMBERED
 *
 * Every constant below was read out of the image's own
 * /vendor/lib64/android.hardware.light@2.0.so rather than recalled from AOSP.
 * BnHwLight::_hidl_setLight is, in order:
 *
 *     Parcel::enforceInterface("android.hardware.light@2.0::ILight")
 *     Parcel::readInt32(&type)                    <- Type is int32
 *     Parcel::readBuffer(0x14, &handle, &ptr)     <- sizeof(LightState) == 20
 *     ... call ...
 *     writeToParcel(Status::ok(), reply)          <- the HIDL status header
 *     Parcel::writeInt32(status)                  <- the Status return value
 *
 * The 0x14 is what pins LightState: 20 bytes for five fields means all three
 * enums are 32-bit, which is the detail worth getting from the binary rather
 * than from memory.
 */

#ifndef WAYDROID_LIGHTS_H
#define WAYDROID_LIGHTS_H

#include <gbinder.h>

#include "Backlight.h"

#define LIGHT_IFACE     "android.hardware.light@2.0::ILight"
#define LIGHT_NAME      "default"

namespace waydroid {

/*
 * Creates the ILight local object.  The caller owns it and registers it with
 * the service manager; `bl` must outlive the returned object.
 */
GBinderLocalObject* lights_new_object(GBinderServiceManager* sm, Backlight* bl);

}  /* namespace waydroid */

#endif /* WAYDROID_LIGHTS_H */
