/*
 * SensorIIO -- a Linux IIO data source for the Waydroid sensors HAL.
 *
 * Copyright © 2026 bigtab01-waydroid project.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3,
 * as published by the Free Software Foundation.  See LICENSE.
 */

#include "SensorIIO.h"

#include "hybrisbindertypes.h"   /* ACCURACY_* */

#include <dirent.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <gutil_log.h>

namespace waydroid {

#define IIO_ROOT "/sys/bus/iio/devices"
#define CONFIG_PATH "/etc/waydroid-sensors.conf"

/*
 * Scale factors: raw IIO integer -> Android's SI unit.
 *
 * These come from the ITE8350's HID report descriptor (decoded with
 * bin/hid-decode.py), NOT from the in_*_scale sysfs attributes, because one of
 * those attributes is wrong by a factor of 1e4:
 *
 *   accel_3d      unit 0x1a (G),          expo -3  -> milli-g
 *                 x 9.80665e-3 = m/s^2.   in_accel_scale agrees.
 *   gyro_3d       unit 0x15 (DEG/S),      expo -5  -> 1e-5 deg/s
 *                 x 1.7453293e-7 = rad/s. in_anglvel_scale agrees.
 *   magn_3d       unit 0x1c (GAUSS),      expo -3  -> micro-gauss
 *                 x 1e-4 = uT.            in_magn_scale says 1.0 and is WRONG:
 *                 the kernel's unit_conversion[] entry for {COMPASS_3D, GAUSS}
 *                 carries scale_val0 = 1000, so it computes 1000 x 10^-3 = 1.0
 *                 exactly.  That assumes a hub reporting gauss; this one
 *                 reports milligauss.  Believing sysfs puts Earth's field at
 *                 536070 gauss instead of 53.6 uT.
 *   dev_rotation  no unit,                expo -7  -> unit quaternion
 *                 x 1e-7.                 in_rot_scale agrees.
 *
 * incli_3d is deliberately absent: it is a derived output (its X/Y track the
 * accelerometer's gravity vector, its Z is 360 deg minus the compass heading),
 * so ORIENTATION is computed from the quaternion instead, which is exact.
 * See docs/14-sensors.md.
 */
#define SCALE_ACCEL 9.80665e-3
#define SCALE_GYRO 1.7453293e-7
/* Local geomagnetic field strength, only used to judge how contaminated a
 * reading is.  Earth's field runs 25-65 uT; 50 is a safe middle for a check
 * that is meant to catch a bias comparable to the field, not to be precise.
 * Override with earth_field_ut in the config for a tighter check. */
#define EARTH_FIELD_UT_DEFAULT 50.0

#define SCALE_MAGN_DEFAULT 1e-4
#define SCALE_ROT 1e-7

/*
 * Warm-up windows.
 *
 * The hid-sensor drivers power the sensor up for each _raw read and let
 * runtime PM suspend it again, so every read after an idle gap is a cold read.
 * For the gyro that matters enormously -- measured on a stationary machine:
 *
 *   t=0.16s   |w| = 1015 deg/s      first read after resume: garbage
 *   t=0.37s   |w| =  139 deg/s      decaying
 *   t=0.5-3s  |w| =    7.6 deg/s    persistent bias, mostly on Z
 *   t>=5.5s   |w| =    0.3-1.0      settled (1-3 LSB)
 *
 * Since the daemon polls continuously while a sensor is enabled, the sensor
 * never goes cold again -- the warm-up only has to cover the first activation.
 * The accelerometer and magnetometer are clean from cold and need almost none.
 * The quaternion's cold read is already a valid unit quaternion, so it needs
 * only a short settle.
 */
#define WARMUP_ACCEL_MS 200
#define WARMUP_MAGN_MS 200
#define WARMUP_GYRO_MS 5000
#define WARMUP_ROT_MS 500

static int64_t now_boottime_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_BOOTTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

const char *SensorIdToName(int id)
{
    switch (id) {
    case ID_ACCELEROMETER:   return "accelerometer";
    case ID_GYROSCOPE:       return "gyroscope";
    case ID_MAGNETIC_FIELD:  return "magnetic-field";
    case ID_ORIENTATION:     return "orientation";
    case ID_ROTATION_VECTOR: return "rotation-vector";
    default:                 return "<unknown>";
    }
}

/* Read one IIO attribute.  Returns the number of whitespace-separated values
 * parsed, or -1.  in_rot_quaternion_raw yields four; everything else one. */
static int read_iio_attr(const std::string &path, const std::string &attr,
                         double *out, int max)
{
    char buf[256];
    std::string full = path + "/" + attr;
    FILE *f = fopen(full.c_str(), "r");

    if (!f)
        return -1;
    if (!fgets(buf, sizeof(buf), f)) {
        fclose(f);
        return -1;
    }
    fclose(f);

    int n = 0;
    char *p = buf;
    while (n < max) {
        char *end;
        double v = strtod(p, &end);
        if (end == p)
            break;
        out[n++] = v;
        p = end;
    }
    return n ? n : -1;
}

SensorIIO::SensorIIO()
    : mCb(nullptr), mUserdata(nullptr), mPollIntervalMs(50),
      mAxisRotation(0), mAccelReportsGravity(true),
      mMagnScale(SCALE_MAGN_DEFAULT),
      mEarthFieldUt(EARTH_FIELD_UT_DEFAULT)
{
    LoadConfig();

    IioSensor defaults[MAX_NUM_SENSORS] = {};

    defaults[ID_ACCELEROMETER].id = ID_ACCELEROMETER;
    defaults[ID_ACCELEROMETER].iio_name = "accel_3d";
    defaults[ID_ACCELEROMETER].attrs = {"in_accel_x_raw", "in_accel_y_raw",
                                        "in_accel_z_raw"};
    defaults[ID_ACCELEROMETER].scale = SCALE_ACCEL;
    defaults[ID_ACCELEROMETER].warmup_ms = WARMUP_ACCEL_MS;

    defaults[ID_GYROSCOPE].id = ID_GYROSCOPE;
    defaults[ID_GYROSCOPE].iio_name = "gyro_3d";
    defaults[ID_GYROSCOPE].attrs = {"in_anglvel_x_raw", "in_anglvel_y_raw",
                                    "in_anglvel_z_raw"};
    defaults[ID_GYROSCOPE].scale = SCALE_GYRO;
    defaults[ID_GYROSCOPE].warmup_ms = WARMUP_GYRO_MS;

    defaults[ID_MAGNETIC_FIELD].id = ID_MAGNETIC_FIELD;
    defaults[ID_MAGNETIC_FIELD].iio_name = "magn_3d";
    defaults[ID_MAGNETIC_FIELD].attrs = {"in_magn_x_raw", "in_magn_y_raw",
                                         "in_magn_z_raw"};
    defaults[ID_MAGNETIC_FIELD].scale = mMagnScale;
    defaults[ID_MAGNETIC_FIELD].warmup_ms = WARMUP_MAGN_MS;

    /* ORIENTATION and ROTATION_VECTOR are both computed from the same
     * dev_rotation quaternion, so they share an IIO node. */
    defaults[ID_ORIENTATION].id = ID_ORIENTATION;
    defaults[ID_ORIENTATION].iio_name = "dev_rotation";
    defaults[ID_ORIENTATION].attrs = {"in_rot_quaternion_raw"};
    defaults[ID_ORIENTATION].scale = SCALE_ROT;
    defaults[ID_ORIENTATION].warmup_ms = WARMUP_ROT_MS;

    defaults[ID_ROTATION_VECTOR].id = ID_ROTATION_VECTOR;
    defaults[ID_ROTATION_VECTOR].iio_name = "dev_rotation";
    defaults[ID_ROTATION_VECTOR].attrs = {"in_rot_quaternion_raw"};
    defaults[ID_ROTATION_VECTOR].scale = SCALE_ROT;
    defaults[ID_ROTATION_VECTOR].warmup_ms = WARMUP_ROT_MS;

    for (int i = 0; i < MAX_NUM_SENSORS; i++)
        mSensors[i] = defaults[i];
}

void SensorIIO::LoadConfig()
{
    /* WAYDROID_SENSORS_CONF overrides the path, so the parser can be exercised
     * without writing into /etc on an immutable host. */
    const char *path = getenv("WAYDROID_SENSORS_CONF");
    if (!path)
        path = CONFIG_PATH;

    FILE *f = fopen(path, "r");
    char line[256];

    if (!f)
        return;

    GINFO("Reading %s", path);
    while (fgets(line, sizeof(line), f)) {
        char *hash = strchr(line, '#');
        if (hash)
            *hash = '\0';

        char key[64], val[128];
        if (sscanf(line, " %63[a-z_] = %127s", key, val) != 2)
            continue;

        if (!strcmp(key, "poll_hz")) {
            double hz = atof(val);
            if (hz > 0.5 && hz <= 200)
                mPollIntervalMs = (int)(1000.0 / hz);
        } else if (!strcmp(key, "axis_rotation")) {
            int deg = atoi(val);
            if (deg == 0 || deg == 90 || deg == 180 || deg == 270)
                mAxisRotation = deg;
            else
                GWARN("axis_rotation must be 0, 90, 180 or 270; got %s", val);
        } else if (!strcmp(key, "accel_reports_gravity")) {
            if (!strcmp(val, "1") || !strcmp(val, "yes"))
                mAccelReportsGravity = true;
            else if (!strcmp(val, "0") || !strcmp(val, "no"))
                mAccelReportsGravity = false;
            else
                GWARN("accel_reports_gravity must be 0/1 or no/yes; got %s",
                      val);
        } else if (!strcmp(key, "magn_scale")) {
            double s = atof(val);
            if (s > 0)
                mMagnScale = s;
        } else if (!strcmp(key, "earth_field_ut")) {
            double f = atof(val);
            /* Earth's field runs about 25-65 uT depending on latitude. */
            if (f >= 20.0 && f <= 70.0)
                mEarthFieldUt = f;
            else
                GWARN("earth_field_ut must be 20-70 uT; got %s", val);
        } else {
            GWARN("%s: unknown key '%s'", path, key);
        }
    }
    fclose(f);
    GINFO("config: poll=%d ms  axis_rotation=%d  accel_reports_gravity=%d  "
          "magn_scale=%g  earth_field=%g uT", mPollIntervalMs, mAxisRotation,
          mAccelReportsGravity, mMagnScale, mEarthFieldUt);
}

/*
 * Report how far the magnetometer can be trusted, from the one check that
 * needs no external reference: |B| is a property of where the machine is
 * standing, not of how it is held, so a clean magnetometer reads the same
 * magnitude in every orientation.  A hard-iron offset -- and the keyboard's
 * attachment magnets are a large one -- adds a constant vector in the device
 * frame, so |measured| swings above and below the true field as the machine
 * turns.  Deviation from the expected magnitude is therefore a direct measure
 * of contamination, with no need to know which way is north.
 *
 * Measured on bigtab01 with the keyboard attached, |B| has ranged from about
 * 52 uT to 134 uT against a local field near 54 -- a bias comparable to the
 * field being measured.  This daemon used to report ACCURACY_HIGH regardless,
 * which tells an app that a corrupted heading is good.  Android has a
 * vocabulary for precisely this situation; the honest thing is to use it.
 *
 * Note this does NOT detect a bias that happens to leave the magnitude alone,
 * so passing is weaker evidence than failing.  It is a contamination detector,
 * not a correctness proof.
 */
int SensorIIO::MagnetometerAccuracy(float x, float y, float z) const
{
    double mag = sqrt((double)x * x + (double)y * y + (double)z * z);
    double ratio = mag / mEarthFieldUt;

    if (ratio >= 0.85 && ratio <= 1.15)
        return ACCURACY_HIGH;
    if (ratio >= 0.75 && ratio <= 1.30)
        return ACCURACY_MEDIUM;
    if (ratio >= 0.60 && ratio <= 1.60)
        return ACCURACY_LOW;
    return UNRELIABLE;
}

/*
 * Re-express an (x, y) pair in a device frame rotated by mAxisRotation about
 * Z.  This exists because the sensor hub's axes need not agree with the
 * display's natural orientation -- on a detachable like this one the panel can
 * be mounted rotated relative to the board.  Runtime-configurable so it can be
 * settled by experiment on the host rather than by assumption; see
 * docs/14-sensors.md.
 */
void SensorIIO::ApplyAxisRotation(double &x, double &y) const
{
    double nx = x, ny = y;

    switch (mAxisRotation) {
    case 90:  nx =  y; ny = -x; break;
    case 180: nx = -x; ny = -y; break;
    case 270: nx = -y; ny =  x; break;
    default:  return;
    }
    x = nx;
    y = ny;
}

void SensorIIO::RegisterSensors(sensor_event_cb_t cb, void *userdata)
{
    mCb = cb;
    mUserdata = userdata;

    /* Map IIO node name -> path.  Matching on name is mandatory: the
     * iio:deviceN indices are assigned in probe order and are not stable
     * across boots (accel_3d was device4 on one boot, device0 on the next). */
    DIR *d = opendir(IIO_ROOT);
    if (!d) {
        GERR("cannot open %s -- no sensors will be reported", IIO_ROOT);
        return;
    }

    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "iio:device", 10))
            continue;

        std::string path = std::string(IIO_ROOT) + "/" + e->d_name;
        char name[64] = {0};
        FILE *f = fopen((path + "/name").c_str(), "r");
        if (!f)
            continue;
        if (fscanf(f, "%63s", name) != 1) {
            fclose(f);
            continue;
        }
        fclose(f);

        for (int i = 0; i < MAX_NUM_SENSORS; i++) {
            if (strcmp(mSensors[i].iio_name, name))
                continue;
            /* Require every attribute to be readable, so a half-probed
             * driver is reported absent rather than returning garbage. */
            bool ok = true;
            for (const std::string &a : mSensors[i].attrs) {
                double tmp[4];
                if (read_iio_attr(path, a, tmp, 4) < 1)
                    ok = false;
            }
            if (!ok) {
                GWARN("%s: node %s found but attributes unreadable",
                      SensorIdToName(i), name);
                continue;
            }
            mSensors[i].path = path;
            mSensors[i].available = true;
            GINFO("%-16s -> %s (%s)", SensorIdToName(i), e->d_name, name);
        }
    }
    closedir(d);

    for (int i = 0; i < MAX_NUM_SENSORS; i++)
        if (!mSensors[i].available)
            GWARN("%-16s -- no IIO node named '%s'", SensorIdToName(i),
                  mSensors[i].iio_name);
}

bool SensorIIO::IsSensorAvailable(int id)
{
    return ID_CHECK(id) && mSensors[id].available;
}

bool SensorIIO::IsSensorEventEnable(int id)
{
    return ID_CHECK(id) && mSensors[id].enabled;
}

int SensorIIO::EnableSensorEvents(int id)
{
    if (!ID_CHECK(id) || !mSensors[id].available)
        return -1;

    IioSensor &s = mSensors[id];
    if (!s.enabled) {
        s.enabled = true;
        s.valid = false;
        s.warmup_until_ns = now_boottime_ns() +
                            (int64_t)s.warmup_ms * 1000000LL;
        GINFO("enable %s (warm-up %d ms)", SensorIdToName(id), s.warmup_ms);
    }
    return 0;
}

int SensorIIO::DisableSensorEvents(int id)
{
    if (!ID_CHECK(id))
        return -1;

    if (mSensors[id].enabled) {
        mSensors[id].enabled = false;
        mSensors[id].valid = false;
        GINFO("disable %s", SensorIdToName(id));
    }
    return 0;
}

bool SensorIIO::ReadSensor(IioSensor &s)
{
    double raw[4];
    int n = 0;

    if (s.attrs.size() == 1) {
        /* Quaternion: one attribute holding four values. */
        n = read_iio_attr(s.path, s.attrs[0], raw, 4);
        if (n < 4)
            return false;
    } else {
        for (size_t i = 0; i < s.attrs.size() && n < 4; i++) {
            double v[4];
            if (read_iio_attr(s.path, s.attrs[i], v, 1) < 1)
                return false;
            raw[n++] = v[0];
        }
    }

    for (int i = 0; i < n; i++)
        s.v[i] = raw[i] * s.scale;
    s.n = n;
    s.ts = (uint64_t)now_boottime_ns();
    return true;
}

void SensorIIO::PollOnce()
{
    int64_t now = now_boottime_ns();

    for (int i = 0; i < MAX_NUM_SENSORS; i++) {
        IioSensor &s = mSensors[i];

        if (!s.enabled || !s.available)
            continue;

        /* Read even during warm-up: the read is what keeps the sensor
         * powered, which is what lets it settle. */
        if (!ReadSensor(s))
            continue;

        if (now < s.warmup_until_ns) {
            s.valid = false;
            continue;
        }

        if (!s.valid) {
            s.valid = true;
            GDEBUG("%s warmed up", SensorIdToName(i));
        }

        if (mCb)
            mCb(mUserdata, i);
    }
}

/*
 * Android's accelerometer convention is proper acceleration -- the force the
 * device's frame resists -- so a machine at rest reads +1 g along whichever
 * axis points at the sky, and lying flat with the screen up reads +9.81 on Z.
 * The ITE8350 reports the opposite: the gravity vector itself, pointing down.
 *
 * Measured on bigtab01 against Android's axes (+X right, +Y toward the top of
 * the screen, +Z out of the screen):
 *
 *     pose                      hub reads               Android needs
 *     flat, screen up           (+0.32, -0.04, -9.83)   (0, 0, +9.81)
 *     upright, top edge up      (+0.13, -9.90, +0.06)   (0, +9.81, 0)
 *     upright, right edge up    (-9.47, -0.04, -0.65)   (+9.81, 0, 0)
 *
 * Every axis is negated and none are swapped.  That rules a mounting rotation
 * out rather than suggesting one: a global negation has determinant -1, and no
 * rigid mounting can turn one right-handed frame into a reflection of another.
 * The hub's axes already line up with the panel's; only the sign convention of
 * the quantity differs, which is why this correction lives here and not in
 * ApplyAxisRotation.
 *
 * The hub's own fused quaternion is the independent witness, and it is already
 * in Android's convention: rotating world-up into the device frame with it
 * gives (0.007, 0.885, 0.463) where the raw accelerometer reads
 * (0.011, -0.895, -0.446) at the same moment -- the same axis, opposite sign,
 * agreeing to 1.5 degrees (docs/14-sensors.md).  So the quaternion needs no
 * correction and the accelerometer needs exactly this one.
 *
 * Uncorrected, this is what made Android's WindowOrientationListener propose
 * ROTATION_180 in normal viewing pose, so every app that follows the sensor
 * rendered upside down.  It also quietly wronged Gravity and Linear
 * Acceleration, which Android synthesises from this sensor.  See
 * docs/18-sensor-axes.md.
 */
int SensorIIO::GetAccelerometerEvent(uint64_t *ts, float *x, float *y,
                                     float *z)
{
    IioSensor &s = mSensors[ID_ACCELEROMETER];

    if (!s.valid || s.n < 3)
        return -1;

    double sgn = mAccelReportsGravity ? -1.0 : 1.0;
    double vx = sgn * s.v[0], vy = sgn * s.v[1];
    ApplyAxisRotation(vx, vy);
    *ts = s.ts;
    *x = (float)vx;
    *y = (float)vy;
    *z = (float)(sgn * s.v[2]);
    return 0;
}

int SensorIIO::GetGyroscopeEvent(uint64_t *ts, float *x, float *y, float *z)
{
    IioSensor &s = mSensors[ID_GYROSCOPE];

    if (!s.valid || s.n < 3)
        return -1;

    double vx = s.v[0], vy = s.v[1];
    ApplyAxisRotation(vx, vy);
    *ts = s.ts;
    *x = (float)vx;
    *y = (float)vy;
    *z = (float)s.v[2];
    return 0;
}

int SensorIIO::GetMagnetometerEvent(uint64_t *ts, float *x, float *y, float *z)
{
    IioSensor &s = mSensors[ID_MAGNETIC_FIELD];

    if (!s.valid || s.n < 3)
        return -1;

    double vx = s.v[0], vy = s.v[1];
    ApplyAxisRotation(vx, vy);
    *ts = s.ts;
    *x = (float)vx;
    *y = (float)vy;
    *z = (float)s.v[2];
    return 0;
}

int SensorIIO::GetRotationVectorEvent(uint64_t *ts, float *x, float *y,
                                      float *z, float *w)
{
    IioSensor &s = mSensors[ID_ROTATION_VECTOR];

    if (!s.valid || s.n < 4)
        return -1;

    /* IIO reports the four quaternion components in the order the HID
     * descriptor declares them, x,y,z,w.  Verified numerically: rotating
     * world-up into the device frame with this ordering reproduces the
     * accelerometer's gravity vector to 1.5 degrees, whereas reading it as
     * w,x,y,z misses by 12.  See docs/14-sensors.md. */
    double qx = s.v[0], qy = s.v[1], qz = s.v[2], qw = s.v[3];

    if (mAxisRotation) {
        /* Compose with a rotation of the device frame about its Z axis. */
        double half = mAxisRotation * M_PI / 360.0;
        double cz = cos(half), sz = sin(half);
        double nx = qx * cz + qy * sz;
        double ny = -qx * sz + qy * cz;
        double nz = qz * cz + qw * sz;
        double nw = -qz * sz + qw * cz;
        qx = nx; qy = ny; qz = nz; qw = nw;
    }

    *ts = s.ts;
    *x = (float)qx;
    *y = (float)qy;
    *z = (float)qz;
    *w = (float)qw;
    return 0;
}

/*
 * Android's deprecated ORIENTATION sensor, computed from the quaternion with
 * exactly the formula SensorManager.getOrientation() uses, so the values agree
 * with what an app would derive itself from ROTATION_VECTOR.
 *
 * This is derived rather than taken from the hub's own incli_3d node because
 * incli_3d does not use Android's convention: its X/Y are tilt angles from the
 * gravity vector and its Z is (360 - compass heading).  Validated against the
 * hub's two independent outputs -- with the quaternion below, azimuth came out
 * 102.93 deg against the hub's tilt-compensated compass heading of 102.0, and
 * pitch -62.24 against its inclinometer X of 62.9.
 */
int SensorIIO::GetOrientationEvent(uint64_t *ts, float *azimuth, float *pitch,
                                   float *roll)
{
    IioSensor &s = mSensors[ID_ORIENTATION];

    if (!s.valid || s.n < 4)
        return -1;

    double qx = s.v[0], qy = s.v[1], qz = s.v[2], qw = s.v[3];

    if (mAxisRotation) {
        double half = mAxisRotation * M_PI / 360.0;
        double cz = cos(half), sz = sin(half);
        double nx = qx * cz + qy * sz;
        double ny = -qx * sz + qy * cz;
        double nz = qz * cz + qw * sz;
        double nw = -qz * sz + qw * cz;
        qx = nx; qy = ny; qz = nz; qw = nw;
    }

    /* Rotation matrix, row-major, device -> world. */
    double r01 = 2 * (qx * qy - qz * qw);
    double r11 = 1 - 2 * (qx * qx + qz * qz);
    double r20 = 2 * (qx * qz - qy * qw);
    double r21 = 2 * (qy * qz + qx * qw);
    double r22 = 1 - 2 * (qx * qx + qy * qy);

    double az = atan2(r01, r11) * 180.0 / M_PI;
    if (az < 0)
        az += 360.0;

    /* asin's argument can drift outside [-1,1] on a not-quite-unit
     * quaternion; the hub's norm measures 0.9989. */
    double sp = -r21;
    if (sp > 1.0)  sp = 1.0;
    if (sp < -1.0) sp = -1.0;

    *ts = s.ts;
    *azimuth = (float)az;
    *pitch = (float)(asin(sp) * 180.0 / M_PI);
    *roll = (float)(atan2(-r20, r22) * 180.0 / M_PI);
    return 0;
}

/*
 * `waydroid-sensord --selftest`: prove the daemon reads the hardware
 * correctly, without needing binder or a running container.
 *
 * The checks are cross-checks between independent hub outputs, so they fail
 * loudly if a scale factor or the quaternion component order is wrong:
 *
 *   1. |acceleration| must be about 1 g.
 *   2. |B| must be a plausible Earth field (25-65 uT).  This is the check that
 *      catches the in_magn_scale trap -- believing sysfs gives 536070.
 *   3. The quaternion must be a unit quaternion.
 *   4. Rotating world-up by the quaternion must reproduce the accelerometer's
 *      gravity direction.
 *   5. The azimuth derived from the quaternion must match the hub's own
 *      tilt-compensated compass heading.
 */
int SensorIIO::SelfTest()
{
    int failures = 0;

    for (int i = 0; i < MAX_NUM_SENSORS; i++) {
        if (mSensors[i].available)
            EnableSensorEvents(i);
        else
            printf("  %-16s ABSENT\n", SensorIdToName(i));
    }

    /* Poll through the longest warm-up window. */
    int warm = 0;
    for (int i = 0; i < MAX_NUM_SENSORS; i++)
        if (mSensors[i].enabled && mSensors[i].warmup_ms > warm)
            warm = mSensors[i].warmup_ms;
    printf("  warming up for %d ms...\n", warm + 500);
    int64_t until = now_boottime_ns() + (int64_t)(warm + 500) * 1000000LL;
    while (now_boottime_ns() < until) {
        PollOnce();
        struct timespec req = {0, (long)mPollIntervalMs * 1000000L};
        nanosleep(&req, NULL);
    }

    uint64_t ts;
    float x, y, z, w;

    if (GetAccelerometerEvent(&ts, &x, &y, &z) == 0) {
        double mag = sqrt((double)x * x + (double)y * y + (double)z * z);
        bool ok = mag > 8.5 && mag < 11.5;
        printf("  accelerometer   %+8.3f %+8.3f %+8.3f m/s^2  |a|=%.3f  %s\n",
               x, y, z, mag, ok ? "OK (~1 g)" : "FAIL: not ~1 g");
        failures += !ok;
    } else {
        printf("  accelerometer   no sample\n");
        failures++;
    }

    if (GetGyroscopeEvent(&ts, &x, &y, &z) == 0) {
        double dps = sqrt((double)x * x + (double)y * y + (double)z * z)
                     * 180.0 / M_PI;
        /* Only meaningful if the machine is being held still. */
        printf("  gyroscope       %+8.4f %+8.4f %+8.4f rad/s  |w|=%.2f deg/s"
               "  %s\n", x, y, z, dps,
               dps < 5.0 ? "OK (settled)" : "note: moving, or still settling");
    } else {
        printf("  gyroscope       no sample\n");
        failures++;
    }

    double bmag = 0;
    if (GetMagnetometerEvent(&ts, &x, &y, &z) == 0) {
        bmag = sqrt((double)x * x + (double)y * y + (double)z * z);
        bool ok = bmag > 20 && bmag < 80;
        printf("  magnetometer    %+8.2f %+8.2f %+8.2f uT     |B|=%.2f uT  %s\n",
               x, y, z, bmag,
               ok ? "OK (Earth field)" : "FAIL: not an Earth field");
        failures += !ok;
    } else {
        printf("  magnetometer    no sample\n");
        failures++;
    }

    if (GetRotationVectorEvent(&ts, &x, &y, &z, &w) == 0) {
        double norm = sqrt((double)x * x + (double)y * y + (double)z * z +
                           (double)w * w);
        bool ok = fabs(norm - 1.0) < 0.02;
        printf("  rotation vector %+8.4f %+8.4f %+8.4f %+8.4f  |q|=%.5f  %s\n",
               x, y, z, w, norm, ok ? "OK (unit)" : "FAIL: not a unit quaternion");
        failures += !ok;

        /* Cross-check 4: world-up rotated into the device frame is the third
         * row of R, and must equal the accelerometer's normalised reading --
         * both answer "which way is up, in device axes".
         *
         * This check used to negate the dot product, demanding the two be
         * anti-parallel, which is what the hub reports raw.  So it agreed with
         * the accelerometer's sign convention rather than catching it, and the
         * bug reached Android unnoticed until auto-rotation was switched on and
         * every app came up inverted.  Requiring them parallel makes this a
         * real regression test for the correction in GetAccelerometerEvent.
         * See docs/18-sensor-axes.md. */
        float ax, ay, az;
        uint64_t ats;
        if (ok && GetAccelerometerEvent(&ats, &ax, &ay, &az) == 0) {
            double ux = 2 * ((double)x * z - (double)y * w);
            double uy = 2 * ((double)y * z + (double)x * w);
            double uz = 1 - 2 * ((double)x * x + (double)y * y);
            double amag = sqrt((double)ax * ax + (double)ay * ay +
                               (double)az * az);
            double dot = (ux * ax + uy * ay + uz * az) / amag;
            if (dot > 1.0) dot = 1.0;
            if (dot < -1.0) dot = -1.0;
            double err = acos(dot) * 180.0 / M_PI;
            bool agree = err < 15.0;
            printf("  quat vs accel   gravity directions differ by %.2f deg"
                   "        %s\n", err,
                   agree ? "OK" : "FAIL: wrong sign convention, component "
                                  "order or axis map?");
            failures += !agree;
        }
    } else {
        printf("  rotation vector no sample\n");
        failures++;
    }

    float azimuth, pitch, roll;
    if (GetOrientationEvent(&ts, &azimuth, &pitch, &roll) == 0) {
        printf("  orientation     azimuth=%.1f pitch=%.1f roll=%.1f deg\n",
               azimuth, pitch, roll);

        /* Cross-check 5: against the hub's own tilt-compensated heading,
         * which is computed independently in the hub's firmware. */
        IioSensor &m = mSensors[ID_MAGNETIC_FIELD];
        double head[4];
        if (m.available &&
            read_iio_attr(m.path, "in_rot_from_north_magnetic_tilt_comp_raw",
                          head, 1) == 1) {
            double hub = head[0] * 0.1;   /* HID says DEGREES, expo -1 */
            double diff = fabs(azimuth - hub);
            if (diff > 180)
                diff = 360 - diff;
            bool agree = diff < 20.0;
            printf("  azimuth vs hub  %.1f deg vs hub heading %.1f deg"
                   "  (%.1f apart)  %s\n", azimuth, hub, diff,
                   agree ? "OK" : "FAIL: world frame mismatch");
            failures += !agree;
        }
    }

    printf("\n  %s\n", failures ? "SELFTEST FAILED" : "SELFTEST PASSED");
    return failures;
}

}  // namespace waydroid
