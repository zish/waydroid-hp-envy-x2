/*
 * SensorIIO -- a Linux IIO data source for the Waydroid sensors HAL.
 *
 * Copyright © 2026 bigtab01-waydroid project.
 * Copyright © 2021 Waydroid Project (interface shape, from SensorFW.h).
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3,
 * as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 *
 * WHY THIS EXISTS
 *
 * Upstream waydroid-sensors (droidian/waydroid-sensors) sources its data from
 * sensorfw, Sailfish's Qt/D-Bus sensor daemon.  bigtab01 runs Fedora Sway
 * Atomic, where sensorfw is not packaged and could only be added as a layered
 * rpm-ostree install plus a reboot.  Its five sensors are, however, already
 * live as plain IIO sysfs nodes behind the ITE8350 HID sensor hub.
 *
 * So this class replaces SensorFW with a direct IIO reader, keeping upstream's
 * (proven) libgbinder ISensors@1.0 server untouched.  That drops Qt, D-Bus and
 * sensorfw entirely, leaving glib + libgbinder -- both of which Waydroid
 * already pulls onto the host.
 *
 * See docs/14-sensors.md for how every constant below was derived.
 */

#ifndef SENSOR_IIO_H_
#define SENSOR_IIO_H_

#include <stdint.h>

#include <string>
#include <vector>

namespace waydroid {

/*
 * Sensor ids.  These are the HIDL `sensorHandle` values Android sees, so they
 * only have to be self-consistent -- but they are also indices into a uint32_t
 * bitmask in Sensors.cpp, so MAX_NUM_SENSORS must stay <= 32.
 */
#define MAX_NUM_SENSORS 5

#define ID_ACCELEROMETER    0
#define ID_GYROSCOPE        1
#define ID_MAGNETIC_FIELD   2
#define ID_ORIENTATION      3
#define ID_ROTATION_VECTOR  4

#define SUPPORTED_SENSORS ((1u << MAX_NUM_SENSORS) - 1)
#define ID_CHECK(x) ((unsigned)(x) < MAX_NUM_SENSORS)

const char *SensorIdToName(int id);

typedef void (*sensor_event_cb_t)(void *userdata, int id);

/*
 * One IIO-backed sensor.
 *
 * `iio_name` is matched against /sys/bus/iio/devices/iio:deviceN/name.  It is
 * NOT safe to hardcode the device index: on this machine accel_3d was
 * iio:device4 on one boot and iio:device0 on the next.
 */
struct IioSensor {
    int id;
    const char *iio_name;           /* value of the node's `name` attribute  */
    std::vector<std::string> attrs; /* attributes to read, in order          */
    double scale;                   /* raw -> SI, derived from the HID
                                     * report descriptor, NOT from in_*_scale */
    int warmup_ms;                  /* discard events for this long after
                                     * enabling; see the gyro note below      */

    /* Resolved at startup. */
    std::string path;               /* /sys/bus/iio/devices/iio:deviceN       */
    bool available;

    /* Runtime state. */
    bool enabled;
    int64_t warmup_until_ns;
    double v[4];                    /* scaled values; quaternion uses all 4  */
    int n;                          /* how many of v[] are valid             */
    uint64_t ts;                    /* CLOCK_BOOTTIME ns of the last read    */
    bool valid;
};

struct SensorIIO {
    SensorIIO();

    /* Discover the IIO nodes and record the event callback. */
    void RegisterSensors(sensor_event_cb_t cb, void *userdata);

    bool IsSensorAvailable(int id);
    bool IsSensorEventEnable(int id);
    int EnableSensorEvents(int id);
    int DisableSensorEvents(int id);

    /* Accessors.  Each returns 0 on success and -1 if there is no fresh,
     * post-warm-up sample.  Units are Android's: m/s^2, rad/s, uT, degrees. */
    int GetAccelerometerEvent(uint64_t *ts, float *x, float *y, float *z);
    int GetGyroscopeEvent(uint64_t *ts, float *x, float *y, float *z);
    int GetMagnetometerEvent(uint64_t *ts, float *x, float *y, float *z);
    int GetOrientationEvent(uint64_t *ts, float *azimuth, float *pitch,
                            float *roll);
    int GetRotationVectorEvent(uint64_t *ts, float *x, float *y, float *z,
                               float *w);

    /* Poll every enabled sensor once and fire the callback for each that
     * produced a usable sample.  Driven by a glib timeout in Sensors.cpp. */
    void PollOnce();

    /* Milliseconds between polls, from the config file. */
    int PollIntervalMs() const { return mPollIntervalMs; }

    /* How far to trust the magnetometer right now, as an Android accuracy
     * value (0 UNRELIABLE, 1 LOW, 2 MEDIUM, 3 HIGH).  See the definition for
     * why |B| alone is enough to tell. */
    int MagnetometerAccuracy(float x, float y, float z) const;

    /* Read live values and check the hub's quaternion against its own
     * accelerometer and compass.  Used by `waydroid-sensord --selftest`. */
    int SelfTest();

private:
    bool ReadSensor(IioSensor &s);
    void ApplyAxisRotation(double &x, double &y) const;
    void LoadConfig();

    IioSensor mSensors[MAX_NUM_SENSORS];
    sensor_event_cb_t mCb;
    void *mUserdata;

    /* Tunables, overridable from /etc/waydroid-sensors.conf so the axis
     * convention can be corrected on the host without a rebuild. */
    int mPollIntervalMs;
    int mAxisRotation;              /* 0, 90, 180 or 270 degrees about Z     */
    double mMagnScale;
    double mEarthFieldUt;           /* local geomagnetic field strength      */
};

}  // namespace waydroid

#endif  // SENSOR_IIO_H_
