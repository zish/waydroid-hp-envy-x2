/*
 * Unit tests for sensors/SensorIIO.cpp, end to end against a fake IIO tree:
 * sysfs files in, the values Android is handed out.
 *
 * includes: tests/cpp/shim sensors
 *
 * A unity build -- this file #includes SensorIIO.cpp after pointing IIO_ROOT
 * at a temporary directory -- because the root is a compile-time constant on
 * purpose (the shipped daemon cannot be redirected) and because it lets the
 * test see the file's static helpers.  shim/ stands in for gbinder.h and
 * gutil_log.h, which SensorIIO.cpp needs only for enums and log macros.
 *
 * The inputs and expectations come from the record, not from running this
 * code:
 *   - docs/18's three poses, which is the sign bug: the hub reports the gravity
 *     vector and Android wants proper acceleration, so face-up must read +Z.
 *     Every app that followed the sensor once rendered upside down.
 *   - docs/14's quaternion from the real hub, whose derived azimuth (102.93)
 *     and pitch (-62.24) were validated against the hub's own compass and
 *     inclinometer.
 */
#include <stdlib.h>
#define IIO_ROOT getenv("TEST_IIO_ROOT")
#include "SensorIIO.cpp"

#include <math.h>
#include <stdio.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using namespace waydroid;

static int failures;
static int checks;
static std::string root;
static int callbacks[MAX_NUM_SENSORS];

#define CHECK(cond) do {                                                    \
    ++checks;                                                               \
    if (!(cond)) {                                                          \
        ++failures;                                                         \
        fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__,    \
                #cond);                                                     \
    }                                                                       \
} while (0)

#define CHECK_NEAR(got, want, tol) do {                                     \
    ++checks;                                                               \
    double g_ = (got), w_ = (want);                                         \
    if (!(fabs(g_ - w_) <= (tol))) {                                        \
        ++failures;                                                         \
        fprintf(stderr, "%s:%d: %s = %.5f, want %.5f +/- %g\n",             \
                __FILE__, __LINE__, #got, g_, w_, (double) (tol));          \
    }                                                                       \
} while (0)

static void
put(const std::string& rel, const std::string& content)
{
    std::string path = root + "/" + rel;
    /* "w" truncates in place, keeping the inode -- like a sysfs attribute,
     * whose held fd sees the next value on the next pread. */
    FILE* f = fopen(path.c_str(), "w");
    if (!f) {
        perror(path.c_str());
        exit(2);
    }
    fputs(content.c_str(), f);
    fclose(f);
}

static void
node(const char* dir, const char* name)
{
    mkdir((root + "/" + dir).c_str(), 0755);
    put(std::string(dir) + "/name", std::string(name) + "\n");
}

static void
accelRaw(int x, int y, int z)
{
    put("iio:device4/in_accel_x_raw", std::to_string(x) + "\n");
    put("iio:device4/in_accel_y_raw", std::to_string(y) + "\n");
    put("iio:device4/in_accel_z_raw", std::to_string(z) + "\n");
}

static void
onEvent(void*, int id)
{
    callbacks[id]++;
}

static void
settle(SensorIIO& iio, int ms)
{
    usleep(ms * 1000);
    iio.PollOnce();
}

static void
useConfig(const char* text)
{
    if (!text) {
        setenv("WAYDROID_SENSORS_CONF", (root + "/no-such.conf").c_str(), 1);
        return;
    }
    put("sensors.conf", text);
    setenv("WAYDROID_SENSORS_CONF", (root + "/sensors.conf").c_str(), 1);
}

/* milli-g, as the ITE8350 reports it, from the m/s^2 docs/18 recorded. */
static const int POSE_FLAT[3]  = {   33,   -4, -1002 };  /* +0.32 -0.04 -9.83 */
static const int POSE_TOP[3]   = {   13, -1009,    6 };  /* +0.13 -9.90 +0.06 */
static const int POSE_RIGHT[3] = { -966,   -4,  -66 };  /* -9.47 -0.04 -0.65 */

static void
testDefaults()
{
    useConfig(nullptr);
    accelRaw(POSE_FLAT[0], POSE_FLAT[1], POSE_FLAT[2]);

    SensorIIO iio;
    iio.RegisterSensors(onEvent, nullptr);

    /* Found by name, not by index: the fake tree numbers them oddly on
     * purpose, as this machine did across boots (accel_3d was iio:device4 on
     * one boot and iio:device0 on the next). */
    CHECK(iio.IsSensorAvailable(ID_ACCELEROMETER));
    CHECK(iio.IsSensorAvailable(ID_MAGNETIC_FIELD));
    CHECK(iio.IsSensorAvailable(ID_ORIENTATION));
    CHECK(iio.IsSensorAvailable(ID_ROTATION_VECTOR));
    CHECK(!iio.IsSensorAvailable(ID_GYROSCOPE));
    CHECK(iio.EnableSensorEvents(ID_GYROSCOPE) == -1);
    CHECK(!iio.IsSensorAvailable(99));

    for (int id : { ID_ACCELEROMETER, ID_MAGNETIC_FIELD, ID_ORIENTATION,
                    ID_ROTATION_VECTOR })
        CHECK(iio.EnableSensorEvents(id) == 0);

    uint64_t ts;
    float x, y, z, w;

    /* Inside the warm-up window nothing is reported. */
    iio.PollOnce();
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == -1);
    CHECK(callbacks[ID_ACCELEROMETER] == 0);

    settle(iio, 600);       /* past every warm-up but the gyro's */
    CHECK(callbacks[ID_ACCELEROMETER] == 1);
    CHECK(callbacks[ID_ORIENTATION] == 1);
    CHECK(callbacks[ID_ROTATION_VECTOR] == 1);

    /* docs/18 pose 1: flat, screen up.  Android needs +Z. */
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == 0);
    CHECK(ts != 0);
    CHECK_NEAR(x, -0.3236, 0.001);
    CHECK_NEAR(y, +0.0392, 0.001);
    CHECK_NEAR(z, +9.8263, 0.001);
    CHECK(z > 9.0);

    /* An unchanged reading is not a new event until the 1 s heartbeat. */
    settle(iio, 80);
    CHECK(callbacks[ID_ACCELEROMETER] == 1);

    /* Pose 2: upright, top edge up.  Android needs +Y. */
    accelRaw(POSE_TOP[0], POSE_TOP[1], POSE_TOP[2]);
    settle(iio, 80);
    CHECK(callbacks[ID_ACCELEROMETER] == 2);
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == 0);
    CHECK(y > 9.0 && fabs(x) < 0.5 && fabs(z) < 0.5);

    /* Pose 3: right edge up.  Android needs +X.  This is the pose that
     * ruled out a mounting rotation (determinant -1, docs/18). */
    accelRaw(POSE_RIGHT[0], POSE_RIGHT[1], POSE_RIGHT[2]);
    settle(iio, 80);
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == 0);
    CHECK(x > 9.0 && fabs(y) < 0.5 && fabs(z) < 1.0);

    /* docs/14's hub quaternion, x 1e-7. */
    float az, pitch, roll;
    CHECK(iio.GetOrientationEvent(&ts, &az, &pitch, &roll) == 0);
    CHECK_NEAR(az, 102.93, 0.05);
    CHECK_NEAR(pitch, -62.24, 0.05);
    CHECK(iio.GetRotationVectorEvent(&ts, &x, &y, &z, &w) == 0);
    CHECK_NEAR(x, 0.3164, 1e-6);
    CHECK_NEAR(y, -0.4102, 1e-6);
    CHECK_NEAR(z, -0.6719, 1e-6);
    CHECK_NEAR(w, 0.5273, 1e-6);

    /* Magnetometer: 1e-4 uT per count by default, and |B| = 50 uT is the
     * default Earth field, so this sample is HIGH accuracy. */
    CHECK(iio.GetMagnetometerEvent(&ts, &x, &y, &z) == 0);
    CHECK_NEAR(x, 30.0, 1e-4);
    CHECK_NEAR(y, 0.0, 1e-4);
    CHECK_NEAR(z, -40.0, 1e-4);
    CHECK(iio.MagnetometerAccuracy(x, y, z) == ACCURACY_HIGH);

    /* Disabled sensors stop reporting. */
    CHECK(iio.DisableSensorEvents(ID_ACCELEROMETER) == 0);
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == -1);
}

static void
testMagnetometerAccuracy()
{
    useConfig("earth_field_ut = 54\n");
    SensorIIO iio;
    /* The keyboard's magnets swing |B| from ~52 to ~134 uT against a local
     * field near 54 (docs/14); the bands are ratios of the expected field. */
    CHECK(iio.MagnetometerAccuracy(54, 0, 0) == ACCURACY_HIGH);
    CHECK(iio.MagnetometerAccuracy(0, 0, -60) == ACCURACY_HIGH);    /* 1.11 */
    CHECK(iio.MagnetometerAccuracy(0, 42, 0) == ACCURACY_MEDIUM);   /* 0.78 */
    CHECK(iio.MagnetometerAccuracy(0, 0, 80) == ACCURACY_LOW);      /* 1.48 */
    CHECK(iio.MagnetometerAccuracy(134, 0, 0) == UNRELIABLE);       /* 2.48 */
    CHECK(iio.MagnetometerAccuracy(0, 0, 0) == UNRELIABLE);
}

static void
testConfig()
{
    /* Both knobs: no sign flip, and a 90 degree rotation about Z, which maps
     * (x, y) to (y, -x) and must leave Z alone. */
    useConfig("# comment\n"
              "accel_reports_gravity = no\n"
              "axis_rotation = 90   # trailing comment\n"
              "poll_hz = 20\n");
    accelRaw(POSE_FLAT[0], POSE_FLAT[1], POSE_FLAT[2]);

    SensorIIO iio;
    CHECK(iio.PollIntervalMs() == 50);
    iio.RegisterSensors(nullptr, nullptr);
    CHECK(iio.EnableSensorEvents(ID_ACCELEROMETER) == 0);
    settle(iio, 0);
    settle(iio, 300);

    uint64_t ts;
    float x, y, z;
    CHECK(iio.GetAccelerometerEvent(&ts, &x, &y, &z) == 0);
    CHECK_NEAR(x, -4 * SCALE_ACCEL, 1e-4);
    CHECK_NEAR(y, -33 * SCALE_ACCEL, 1e-4);
    CHECK_NEAR(z, -1002 * SCALE_ACCEL, 1e-4);

    /* Values the parser must refuse leave the defaults in place. */
    useConfig("axis_rotation = 45\npoll_hz = 1000\nearth_field_ut = 5\n"
              "accel_reports_gravity = maybe\n");
    SensorIIO strict;
    CHECK(strict.PollIntervalMs() == 50);
    CHECK(strict.MagnetometerAccuracy(50, 0, 0) == ACCURACY_HIGH);
    accelRaw(POSE_FLAT[0], POSE_FLAT[1], POSE_FLAT[2]);
    strict.RegisterSensors(nullptr, nullptr);
    strict.EnableSensorEvents(ID_ACCELEROMETER);
    settle(strict, 0);
    settle(strict, 300);
    CHECK(strict.GetAccelerometerEvent(&ts, &x, &y, &z) == 0);
    CHECK(z > 9.0);         /* gravity flag stayed on, rotation stayed 0 */
}

int
main()
{
    char tmpl[] = "/tmp/test_sensor_iio.XXXXXX";
    if (!mkdtemp(tmpl)) {
        perror("mkdtemp");
        return 2;
    }
    root = tmpl;
    setenv("TEST_IIO_ROOT", tmpl, 1);

    node("iio:device4", "accel_3d");
    node("iio:device0", "magn_3d");
    node("iio:device7", "dev_rotation");
    node("iio:device2", "incli_3d");            /* a decoy, never read */
    accelRaw(0, 0, 0);
    put("iio:device0/in_magn_x_raw", "300000\n");
    put("iio:device0/in_magn_y_raw", "0\n");
    put("iio:device0/in_magn_z_raw", "-400000\n");
    put("iio:device7/in_rot_quaternion_raw",
        "3164000 -4102000 -6719000 5273000\n");

    testDefaults();
    testMagnetometerAccuracy();
    testConfig();

    std::string rm = "rm -rf '" + root + "'";
    if (system(rm.c_str()) != 0)
        fprintf(stderr, "could not remove %s\n", root.c_str());

    printf("test_sensor_iio: %d checks, %d failed\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
