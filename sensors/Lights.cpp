/*
 * Lights -- ILight@2.0 server.  See Lights.h for the disassembly this is
 * built from.
 */

#include "Lights.h"

#include <gutil_log.h>


namespace waydroid {

/* Transaction codes: HIDL numbers methods from 1 in .hal declaration order,
 * and ILight.hal declares setLight before getSupportedTypes. */
#define SET_LIGHT               (1)
#define GET_SUPPORTED_TYPES     (2)

/* android.hardware.light@2.0::Type */
#define TYPE_BACKLIGHT          (0)

/* android.hardware.light@2.0::Status */
#define STATUS_SUCCESS              (0)
#define STATUS_LIGHT_NOT_SUPPORTED  (1)
#define STATUS_UNKNOWN              (3)

/*
 * 20 bytes, per readBuffer(0x14) in BnHwLight::_hidl_setLight.  The
 * static_assert is the whole point of writing it out: if this ever stops
 * being 20, the reader below is silently misaligned and Android's brightness
 * arrives as garbage.
 */
struct LightState {
    guint32 color;
    gint32  flashMode;
    gint32  flashOnMs;
    gint32  flashOffMs;
    gint32  brightnessMode;
};
static_assert(sizeof(LightState) == 20,
              "LightState must match readBuffer(0x14) in the image's "
              "android.hardware.light@2.0.so");

/*
 * The conventional AOSP lights-HAL reduction.  LightsService sends grey --
 * LightImpl.setBrightness() builds 0xff000000 | v<<16 | v<<8 | v -- so for
 * every call we will actually see this returns v exactly: (77+150+29) == 256,
 * so (256 * v) >> 8 == v.  Kept in full anyway because it costs nothing and
 * is correct if a non-grey colour ever arrives.
 */
static int
rgb_to_brightness(guint32 color)
{
    const int r = (color >> 16) & 0xff;
    const int g = (color >>  8) & 0xff;
    const int b = (color      ) & 0xff;
    return (77 * r + 150 * g + 29 * b) >> 8;
}

static const char*
type_name(gint32 type)
{
    switch (type) {
    case 0: return "BACKLIGHT";
    case 1: return "KEYBOARD";
    case 2: return "BUTTONS";
    case 3: return "BATTERY";
    case 4: return "NOTIFICATIONS";
    case 5: return "ATTENTION";
    case 6: return "BLUETOOTH";
    case 7: return "WPS";
    default: return "?";
    }
}

static GBinderLocalReply*
lights_reply(
    GBinderLocalObject* obj,
    GBinderRemoteRequest* req,
    guint code,
    guint flags,
    int* status,
    void* user_data)
{
    Backlight* bl = (Backlight*) user_data;
    const char* iface = gbinder_remote_request_interface(req);
    GBinderLocalReply* reply = NULL;
    GBinderWriter writer;
    GBinderReader reader;

    if (g_strcmp0(iface, LIGHT_IFACE)) {
        GDEBUG("Unexpected interface \"%s\"", iface);
        return NULL;
    }

    gbinder_remote_request_init_reader(req, &reader);

    if (code == SET_LIGHT) {
        gint32 type = -1;
        gint32 result = STATUS_LIGHT_NOT_SUPPORTED;

        gbinder_reader_read_int32(&reader, &type);
        const LightState* st =
            gbinder_reader_read_hidl_struct(&reader, LightState);

        if (!st) {
            GWARN("setLight(%s): short LightState buffer", type_name(type));
            result = STATUS_UNKNOWN;
        } else if (type == TYPE_BACKLIGHT) {
            const int v = rgb_to_brightness(st->color);
            result = (bl->SetAndroidBrightness(v) >= 0) ?
                STATUS_SUCCESS : STATUS_UNKNOWN;
        } else {
            /* KEYBOARD, BATTERY, NOTIFICATIONS ... this machine has no LED
             * for any of them (/sys/class/leds holds only capslock, numlock,
             * scrolllock, hda::mute and the two radio LEDs), so declining is
             * the honest answer rather than silently succeeding. */
            GVERBOSE("setLight(%s): not supported here", type_name(type));
        }

        reply = gbinder_local_object_new_reply(obj);
        gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
        gbinder_local_reply_init_writer(reply, &writer);
        gbinder_writer_append_int32(&writer, result);
        *status = GBINDER_STATUS_OK;

    } else if (code == GET_SUPPORTED_TYPES) {
        /* vec<Type>, laid out the same way Sensors::getSensorsList lays out
         * its vec<sensor_t>: a GBinderHidlVec buffer object, then the payload
         * as a child buffer of it. */
        const gint32 supported[] = { TYPE_BACKLIGHT };
        const gsize count = bl->Available() ? G_N_ELEMENTS(supported) : 0;
        const gsize total = count * sizeof(supported[0]);

        reply = gbinder_local_object_new_reply(obj);
        gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
        gbinder_local_reply_init_writer(reply, &writer);

        GBinderParent vec_parent;
        GBinderHidlVec* vec = gbinder_writer_new0(&writer, GBinderHidlVec);
        gint32* types = count ?
            (gint32*) gbinder_writer_malloc0(&writer, total) : NULL;

        if (types)
            memcpy(types, supported, total);

        vec->data.ptr = types;
        vec->count = count;
        vec->owns_buffer = TRUE;

        vec_parent.index =
            gbinder_writer_append_buffer_object(&writer, vec, sizeof(*vec));
        vec_parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET;
        gbinder_writer_append_buffer_object_with_parent(&writer, types,
            total, &vec_parent);

        *status = GBINDER_STATUS_OK;

    } else {
        GDEBUG("Unhandled ILight transaction %u", code);
    }

    return reply;
}

GBinderLocalObject*
lights_new_object(GBinderServiceManager* sm, Backlight* bl)
{
    return gbinder_servicemanager_new_local_object(sm, LIGHT_IFACE,
        lights_reply, bl);
}

}  /* namespace waydroid */
