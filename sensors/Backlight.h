/*
 * Backlight -- writes the host's panel backlight on Android's behalf.
 *
 * bigtab01-waydroid, goal "Android controls screen brightness".
 *
 * WHY THIS EXISTS AT ALL
 *
 * The HP Envy x2 has no ambient light sensor -- the ITE8350 hub declares only
 * accel/gyro/compass/inclinometer/device-orientation, there is no ACPI0008 and
 * no ALS on either i2c bus -- so Android's *automatic* brightness can never
 * work here.  Manual brightness can, and did not, because Waydroid's shipped
 * /vendor/bin/hw/android.hardware.light@2.0-service.waydroid is a 15 KB stub
 * that registers ILight and discards every call.  It contains no file path
 * strings at all; it writes nowhere.
 *
 * Android 13 reaches that stub over HIDL rather than through the composer:
 *
 *     mBacklightAdapter=BacklightAdapter [useSurfaceControl=false
 *         (force_anyway? false),
 *         backlight=com.android.server.lights.LightsService$LightImpl@...]
 *
 * useSurfaceControl=false because SurfaceControl.setDisplayBrightness needs
 * composer >= 2.3 and Waydroid ships graphics.composer@2.1.  So ILight is the
 * live path, and serving it from the host is all that is missing.
 *
 * NOTHING ELSE WRITES THIS FILE
 *
 * Checked, not assumed: 27-android-power-button.md sampled a full 40 s Android
 * sleep and found backlight=937/937 throughout -- Android asleep is black
 * pixels at full backlight, because cage is too minimal to have output-power
 * IPC and nothing calls logind's SetBrightness.  So this class is the only
 * writer and needs no arbitration.
 *
 * WE ARE ROOT, SO THIS IS A sysfs WRITE AND NOT D-Bus
 *
 * container_manager.py spawns waydroid-sensord as root, so
 * /sys/class/backlight/<dev>/brightness is directly writable.  logind's
 * SetBrightness would need a session bus and buys nothing here.
 */

#ifndef WAYDROID_BACKLIGHT_H
#define WAYDROID_BACKLIGHT_H

#include <string>
#include <sys/types.h>

namespace waydroid {

class Backlight {
public:
    Backlight();

    /* False when no backlight device was found; every setter then no-ops so a
     * machine without a panel backlight still runs the sensors half. */
    bool Available() const { return mMaxRaw > 0; }

    const std::string& Name() const { return mName; }
    int MaxRaw() const { return mMaxRaw; }

    /* v is Android's 0..255 brightness.  Returns the raw value written, the
     * cached value if unchanged, or -1 on failure. */
    int SetAndroidBrightness(int v);

    /* The mapping, exposed so --backlight-info can print it without side
     * effects. */
    int AndroidToRaw(int v) const;

    int ReadRaw(const char* attr = "actual_brightness") const;

    /* Put back whatever the panel was at when we started.  Called on clean
     * exit: if the daemon goes away while Android has it dimmed, nothing is
     * left that could ever brighten it again. */
    /*
     * Put the panel back where the host had it, never dimmer than
     * RECOVER_FLOOR_PERCENT.  Called on exit AND whenever Android goes
     * away -- see the note in app_sm_presence_handler() for why the exit
     * path alone is not enough.  "why" is logged.
     */
    void RestoreInitial(const char* why);

private:
    bool Discover();
    void ReloadConfigIfChanged();
    bool WriteRaw(int raw);

    std::string mDir;          /* /sys/class/backlight/<name> */
    std::string mName;
    int    mMaxRaw      = 0;
    int    mInitialRaw  = -1;
    int    mLastRaw     = -1;

    /* Tunables, re-read from mConfigPath whenever its mtime changes.  Live
     * reload matters on this host: the daemon is spawned by
     * container_manager.py, so restarting it to pick up a new curve costs a
     * container restart, which drops the kiosk to the SDDM greeter and needs
     * someone physically at the machine. */
    double mGamma       = 1.0; /* 1.0 = linear in PWM duty */
    double mMinPercent  = 1.0; /* floor for any non-zero request */
    std::string mConfigDevice;
    time_t mConfigMtime = 0;
};

}  /* namespace waydroid */

#endif /* WAYDROID_BACKLIGHT_H */
