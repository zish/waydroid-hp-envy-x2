/*
 * Copyright © 2021 Waydroid Project.
 * Copyright © 2026 bigtab01-waydroid project (SensorFW -> SensorIIO,
 *                  plus ORIENTATION and ROTATION_VECTOR).
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3,
 * as published by the Free Software Foundation.  See LICENSE.
 *
 * Authored by: Erfan Abdi <erfangplus@gmail.com>
 */

#include "Sensors.h"

#include <pthread.h>
#include <string.h>

namespace waydroid {
namespace sensors {
namespace implementation {

/* return the current time in nanoseconds */
static int64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

/* Pick up one pending sensor event. On success, this returns the sensor
 * id, and sets |*event| accordingly. On failure, i.e. if there are no
 * pending events, return -EINVAL.
 *
 * Note: The device's lock must be acquired.
 */
static int sensor_device_pick_pending_event_locked(SensorDevice *d,
                                                   sensors_event_t *event)
{
    uint32_t mask = SUPPORTED_SENSORS & d->pendingSensors;

    if (mask) {
        uint32_t i = 31 - __builtin_clz(mask);
        d->pendingSensors &= ~(1U << i);
        *event = d->sensors[i];

        if (d->sensors[i].sensorType == SENSOR_TYPE_META_DATA) {
            if (d->flush_count[i] > 0) {
                /* Another 'flush' is queued after this one: don't clear the
                 * event, just decrement the count and re-mark it pending. */
                (d->flush_count[i])--;
                d->pendingSensors |= (1U << i);
            } else {
                /* Done flushing.  Set |type| to something other than
                 * META_DATA so sensor_event_cb() can continue. */
                d->sensors[i].sensorType = SENSOR_TYPE_ACCELEROMETER;
            }
        } else {
            event->sensorHandle = i;
        }

        return i;
    }
    GERR("No sensor to return!!! pendingSensors=0x%08x", d->pendingSensors);
    /* we may end up in a busy loop, slow things down, just in case. */
    usleep(1000);
    return -EINVAL;
}

/*
 * Called by SensorIIO::PollOnce() for each enabled sensor that produced a
 * fresh, post-warm-up sample.  Converts it into a HIDL sensors_event_t and
 * marks it pending, then wakes poll() if it is blocked.
 */
static void sensor_event_cb(void *userdata, int id)
{
    SensorDevice *dev = (SensorDevice *)userdata;
    uint32_t new_sensors = 0U;
    sensors_event_t *events = dev->sensors;
    SensorIIO *iio = dev->mIioDevice;

    uint64_t ts;
    float x, y, z, w;

    switch (id) {
    case ID_ACCELEROMETER:
        if (iio->GetAccelerometerEvent(&ts, &x, &y, &z) == 0 &&
            ts != dev->last_TimeStamp[ID_ACCELEROMETER]) {
            new_sensors |= (1U << ID_ACCELEROMETER);
            events[ID_ACCELEROMETER].u.vec3.x = x;
            events[ID_ACCELEROMETER].u.vec3.y = y;
            events[ID_ACCELEROMETER].u.vec3.z = z;
            events[ID_ACCELEROMETER].u.vec3.status = ACCURACY_HIGH;
            events[ID_ACCELEROMETER].sensorType = SENSOR_TYPE_ACCELEROMETER;
            dev->last_TimeStamp[ID_ACCELEROMETER] = ts;
        }
        break;

    case ID_GYROSCOPE:
        if (iio->GetGyroscopeEvent(&ts, &x, &y, &z) == 0 &&
            ts != dev->last_TimeStamp[ID_GYROSCOPE]) {
            new_sensors |= (1U << ID_GYROSCOPE);
            events[ID_GYROSCOPE].u.vec3.x = x;
            events[ID_GYROSCOPE].u.vec3.y = y;
            events[ID_GYROSCOPE].u.vec3.z = z;
            events[ID_GYROSCOPE].u.vec3.status = ACCURACY_HIGH;
            events[ID_GYROSCOPE].sensorType = SENSOR_TYPE_GYROSCOPE;
            dev->last_TimeStamp[ID_GYROSCOPE] = ts;
        }
        break;

    case ID_MAGNETIC_FIELD:
        if (iio->GetMagnetometerEvent(&ts, &x, &y, &z) == 0 &&
            ts != dev->last_TimeStamp[ID_MAGNETIC_FIELD]) {
            new_sensors |= (1U << ID_MAGNETIC_FIELD);
            events[ID_MAGNETIC_FIELD].u.vec3.x = x;
            events[ID_MAGNETIC_FIELD].u.vec3.y = y;
            events[ID_MAGNETIC_FIELD].u.vec3.z = z;
            /* The hub does its own hard/soft-iron correction -- this is the
             * calibrated node, and it also feeds the hub's own
             * tilt-compensated heading. */
            events[ID_MAGNETIC_FIELD].u.vec3.status = ACCURACY_HIGH;
            events[ID_MAGNETIC_FIELD].sensorType = SENSOR_TYPE_MAGNETIC_FIELD;
            dev->last_TimeStamp[ID_MAGNETIC_FIELD] = ts;
        }
        break;

    case ID_ORIENTATION:
        if (iio->GetOrientationEvent(&ts, &x, &y, &z) == 0 &&
            ts != dev->last_TimeStamp[ID_ORIENTATION]) {
            new_sensors |= (1U << ID_ORIENTATION);
            events[ID_ORIENTATION].u.vec3.x = x;   /* azimuth, degrees */
            events[ID_ORIENTATION].u.vec3.y = y;   /* pitch,   degrees */
            events[ID_ORIENTATION].u.vec3.z = z;   /* roll,    degrees */
            events[ID_ORIENTATION].u.vec3.status = ACCURACY_HIGH;
            events[ID_ORIENTATION].sensorType = SENSOR_TYPE_ORIENTATION;
            dev->last_TimeStamp[ID_ORIENTATION] = ts;
        }
        break;

    case ID_ROTATION_VECTOR:
        if (iio->GetRotationVectorEvent(&ts, &x, &y, &z, &w) == 0 &&
            ts != dev->last_TimeStamp[ID_ROTATION_VECTOR]) {
            new_sensors |= (1U << ID_ROTATION_VECTOR);
            events[ID_ROTATION_VECTOR].u.vec4.x = x;
            events[ID_ROTATION_VECTOR].u.vec4.y = y;
            events[ID_ROTATION_VECTOR].u.vec4.z = z;
            events[ID_ROTATION_VECTOR].u.vec4.w = w;
            events[ID_ROTATION_VECTOR].sensorType = SENSOR_TYPE_ROTATION_VECTOR;
            dev->last_TimeStamp[ID_ROTATION_VECTOR] = ts;
        }
        break;

    default:
        break;
    }

    if (new_sensors) {
        dev->pendingSensors |= new_sensors;

        /* Android requires the event timestamp to be strictly before the time
         * the event is delivered.  SensorIIO stamps each read with
         * CLOCK_BOOTTIME, which is the same clock Android uses, so the value
         * can be passed through -- but clamp to "now" anyway, since we do not
         * believe in events from the future. */
        const int64_t now = now_ns();
        int64_t t = (int64_t)ts;

        if (dev->timeStart == 0)
            dev->timeStart = now;
        if (t > now || t <= 0)
            t = now;

        uint32_t remaining = new_sensors;
        while (remaining) {
            uint32_t i = 31 - __builtin_clz(remaining);
            remaining &= ~(1U << i);
            dev->sensors[i].timestamp = t;
        }
    }

    if (dev->waiting_for_data)
        g_main_loop_quit(dev->loop);
}

/* glib timeout: drive the IIO reader. */
static gboolean sensor_poll_tick(gpointer user_data)
{
    SensorDevice *dev = (SensorDevice *)user_data;

    dev->mIioDevice->PollOnce();
    return G_SOURCE_CONTINUE;
}

Sensors::Sensors()
    : mSensorDevice(nullptr)
{
    mSensorDevice = (SensorDevice *)malloc(sizeof(*mSensorDevice));
    memset(mSensorDevice, 0, sizeof(*mSensorDevice));

    /* (sensorType == SENSOR_TYPE_META_DATA) is sticky.  Don't start off with
     * that setting. */
    for (int idx = 0; idx < MAX_NUM_SENSORS; idx++) {
        mSensorDevice->sensors[idx].sensorType = SENSOR_TYPE_ACCELEROMETER;
        mSensorDevice->flush_count[idx] = 0;
    }

    mSensorDevice->mIioDevice = new SensorIIO();
    mSensorDevice->mIioDevice->RegisterSensors(sensor_event_cb, mSensorDevice);

    pthread_mutex_init(&mSensorDevice->lock, NULL);
    mSensorDevice->loop = g_main_loop_new(NULL, TRUE);

    /* The reader runs on the default GMainContext.  poll() blocks by running
     * a nested main loop on that same context, so this timeout keeps firing
     * while poll() waits -- which is what wakes it. */
    g_timeout_add(mSensorDevice->mIioDevice->PollIntervalMs(),
                  sensor_poll_tick, mSensorDevice);
}

/* Fill in the four hidl_string fields of a sensor_t from string literals. */
static void set_strings(sensor_t &s, const char *name, const char *type_str)
{
    struct { gbinder_hidl_string *f; const char *v; } fields[] = {
        {&s.name, name},
        {&s.vendor, kVendor},
        {&s.typeAsString, type_str},
        {&s.requiredPermission, ""},
    };

    for (auto &f : fields) {
        f.f->data.str = f.v;
        f.f->len = strlen(f.v);
        f.f->owns_buffer = TRUE;
    }
}

/*
 * Sensor metadata.
 *
 * `resolution` is the measured quantisation step of each channel (see
 * bin/iio-probe.py and docs/14-sensors.md), not a guess:
 *
 *   accelerometer    LSB 4 raw      x 9.80665e-3   = 0.0392 m/s^2
 *   gyroscope        LSB 22381 raw  x 1.7453293e-7 = 0.003906 rad/s
 *   magnetometer     LSB 3907 raw   x 1e-4         = 0.3907 uT
 *   rotation vector  LSB 10 raw     x 1e-7         = 1e-6
 */
std::vector<sensor_t> Sensors::getSensorsList()
{
    std::vector<sensor_t> out;
    SensorIIO *iio = mSensorDevice->mIioDevice;

    /* minDelay is the fastest rate we can actually serve.  Reading three
     * sysfs attributes over the hub's i2c link costs 3-7 ms, so promising
     * more than the configured poll rate would be a lie. */
    const int32_t min_delay_us = iio->PollIntervalMs() * 1000;
    const int32_t max_delay_us = 1000000;

    for (int id = 0; id < MAX_NUM_SENSORS; id++) {
        if (!iio->IsSensorAvailable(id)) {
            GWARN("Sensor %s not present, omitting from list",
                  waydroid::SensorIdToName(id));
            continue;
        }

        sensor_t s;
        memset(&s, 0, sizeof(s));
        s.handle = id;
        s.version = 1;
        s.power = 0.5f;
        s.minDelay = min_delay_us;
        s.maxDelay = max_delay_us;
        s.fifoReservedEventCount = 0;
        s.fifoMaxEventCount = 0;
        s.flags = SENSOR_FLAG_CONTINUOUS_MODE;

        switch (id) {
        case ID_ACCELEROMETER:
            set_strings(s, "ITE8350 3-axis Accelerometer",
                        "android.sensor.accelerometer");
            s.type = SENSOR_TYPE_ACCELEROMETER;
            s.maxRange = 39.24f;         /* +/- 4 g */
            s.resolution = 0.0392f;
            break;

        case ID_GYROSCOPE:
            set_strings(s, "ITE8350 3-axis Gyroscope",
                        "android.sensor.gyroscope");
            s.type = SENSOR_TYPE_GYROSCOPE;
            s.maxRange = 16.46f;         /* rad/s, ~943 deg/s */
            s.resolution = 0.003906f;
            break;

        case ID_MAGNETIC_FIELD:
            set_strings(s, "ITE8350 3-axis Magnetometer",
                        "android.sensor.magnetic_field");
            s.type = SENSOR_TYPE_MAGNETIC_FIELD;
            s.maxRange = 2000.0f;        /* uT */
            s.resolution = 0.3907f;
            break;

        case ID_ORIENTATION:
            set_strings(s, "ITE8350 Orientation (from fused quaternion)",
                        "android.sensor.orientation");
            s.type = SENSOR_TYPE_ORIENTATION;
            s.maxRange = 360.0f;         /* degrees */
            s.resolution = 0.1f;
            break;

        case ID_ROTATION_VECTOR:
            set_strings(s, "ITE8350 Rotation Vector",
                        "android.sensor.rotation_vector");
            s.type = SENSOR_TYPE_ROTATION_VECTOR;
            s.maxRange = 1.0f;
            s.resolution = 1e-6f;
            break;

        default:
            continue;
        }

        out.push_back(s);
    }

    GINFO("getSensorsList: reporting %zu sensors", out.size());
    return out;
}

int Sensors::activate(int32_t handle, bool enabled)
{
    if (!ID_CHECK(handle)) {
        GERR("activate: bad handle ID: %d", handle);
        return RESULT_BAD_VALUE;
    }

    uint32_t mask = (1U << handle);
    uint32_t sensors = enabled ? mask : 0;

    pthread_mutex_lock(&mSensorDevice->lock);

    uint32_t active = mSensorDevice->active_sensors;
    uint32_t new_sensors = (active & ~mask) | (sensors & mask);
    uint32_t changed = active ^ new_sensors;

    if (changed) {
        if (enabled)
            mSensorDevice->mIioDevice->EnableSensorEvents(handle);
        else
            mSensorDevice->mIioDevice->DisableSensorEvents(handle);
        mSensorDevice->active_sensors = new_sensors;
    }
    pthread_mutex_unlock(&mSensorDevice->lock);
    return RESULT_OK;
}

std::vector<sensors_event_t> Sensors::poll(int32_t maxCount, int *err_out)
{
    std::vector<sensors_event_t> out;
    int err = 0;

    if (maxCount <= 0) {
        *err_out = RESULT_BAD_VALUE;
        return out;
    }

    int bufferSize = maxCount <= kPollMaxBufferSize ? maxCount
                                                    : kPollMaxBufferSize;

    if (!mSensorDevice->pendingSensors) {
        mSensorDevice->waiting_for_data = true;
        g_main_loop_run(mSensorDevice->loop);
        mSensorDevice->waiting_for_data = false;
    }
    out.resize(bufferSize);

    /* Now read as many pending events as needed. */
    for (int i = 0; i < bufferSize; i++) {
        if (!mSensorDevice->pendingSensors)
            break;
        int ret = sensor_device_pick_pending_event_locked(mSensorDevice,
                                                          &out[i]);
        if (ret < 0) {
            if (!err)
                err = ret;
            break;
        }
        err++;
    }

    if (err < 0) {
        out.clear();
        *err_out = RESULT_BAD_VALUE;
        return out;
    }

    out.resize((size_t)err);
    *err_out = RESULT_OK;
    return out;
}

int Sensors::flush(int32_t handle)
{
    if (!ID_CHECK(handle)) {
        GERR("flush: bad handle ID: %d", handle);
        return RESULT_BAD_VALUE;
    }

    pthread_mutex_lock(&mSensorDevice->lock);
    if ((mSensorDevice->pendingSensors & (1U << handle)) &&
        mSensorDevice->sensors[handle].sensorType == SENSOR_TYPE_META_DATA) {
        /* A 'flush' is already pending.  Just increment the count. */
        (mSensorDevice->flush_count[handle])++;
    } else {
        mSensorDevice->flush_count[handle] = 0;
        mSensorDevice->sensors[handle].sensorType = SENSOR_TYPE_META_DATA;
        mSensorDevice->sensors[handle].timestamp = 0;
        mSensorDevice->sensors[handle].sensorHandle = handle;
        mSensorDevice->sensors[handle].u.meta.what = META_DATA_FLUSH_COMPLETE;
        mSensorDevice->pendingSensors |= (1U << handle);
    }
    pthread_mutex_unlock(&mSensorDevice->lock);

    if (mSensorDevice->waiting_for_data)
        g_main_loop_quit(mSensorDevice->loop);

    return RESULT_OK;
}

void Sensors::killLoops()
{
    if (mSensorDevice->waiting_for_data)
        g_main_loop_quit(mSensorDevice->loop);
}

}  // namespace implementation
}  // namespace sensors
}  // namespace waydroid
