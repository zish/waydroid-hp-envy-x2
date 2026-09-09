/*
 * Backlight -- see Backlight.h for why this lives in the sensors daemon.
 */

#include "Backlight.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <vector>

#include <gutil_log.h>

namespace waydroid {

#define BACKLIGHT_ROOT  "/sys/class/backlight"

/*
 * /var/lib/waydroid rather than /etc: this daemon inherits
 * system_u:system_r:waydroid_t:s0 from container_manager.py, and that domain
 * reads and writes /var/lib/waydroid routinely (waydroid.log lives there).
 * service.cpp records the same lesson the hard way for its lock file, where
 * /run is var_run_t and the open() fails with EACCES.
 */
#define CONFIG_PATH     "/var/lib/waydroid/backlight.conf"

/* ------------------------------------------------------------------ sysfs */

static bool
read_int_file(const std::string& path, int* out)
{
    FILE* f = fopen(path.c_str(), "re");
    if (!f)
        return false;
    int v = 0;
    const bool ok = (fscanf(f, "%d", &v) == 1);
    fclose(f);
    if (ok)
        *out = v;
    return ok;
}

static std::string
read_str_file(const std::string& path)
{
    FILE* f = fopen(path.c_str(), "re");
    if (!f)
        return std::string();
    char buf[64] = { 0 };
    if (!fgets(buf, sizeof(buf), f)) {
        fclose(f);
        return std::string();
    }
    fclose(f);
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == ' '))
        s.pop_back();
    return s;
}

/*
 * Preference when a machine exposes more than one device.  "raw" first: it is
 * the native PWM controller (intel_backlight here, 0..937), which has far more
 * steps than the 0..100 an ACPI "firmware" device typically offers, and on
 * Broadwell it is the one that actually moves the panel.  bigtab01 has exactly
 * one device so this ordering is currently untested against a real tie.
 */
static int
type_rank(const std::string& type)
{
    if (type == "raw")      return 3;
    if (type == "platform") return 2;
    if (type == "firmware") return 1;
    return 0;
}

Backlight::Backlight()
{
    ReloadConfigIfChanged();
    if (!Discover()) {
        GWARN("No usable backlight under %s; brightness control disabled",
              BACKLIGHT_ROOT);
        return;
    }

    mInitialRaw = ReadRaw();
    mLastRaw = mInitialRaw;
    GINFO("Backlight %s: max=%d, currently %d (gamma %.2f, floor %.1f%%)",
          mName.c_str(), mMaxRaw, mInitialRaw, mGamma, mMinPercent);
}

bool
Backlight::Discover()
{
    DIR* d = opendir(BACKLIGHT_ROOT);
    if (!d) {
        GDEBUG("opendir(%s): %s", BACKLIGHT_ROOT, strerror(errno));
        return false;
    }

    std::string best;
    int best_rank = -1;

    struct dirent* e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;

        const std::string dir = std::string(BACKLIGHT_ROOT) + "/" + e->d_name;
        int max_raw = 0;
        if (!read_int_file(dir + "/max_brightness", &max_raw) || max_raw <= 0)
            continue;

        /* An explicit device= in the config wins outright. */
        if (!mConfigDevice.empty()) {
            if (mConfigDevice == e->d_name) {
                best = e->d_name;
                best_rank = 1000;
                mMaxRaw = max_raw;
            }
            continue;
        }

        const int rank = type_rank(read_str_file(dir + "/type"));
        if (rank > best_rank) {
            best = e->d_name;
            best_rank = rank;
            mMaxRaw = max_raw;
        }
    }
    closedir(d);

    if (best.empty()) {
        if (!mConfigDevice.empty())
            GWARN("backlight.conf names device=%s, which does not exist",
                  mConfigDevice.c_str());
        mMaxRaw = 0;
        return false;
    }

    mName = best;
    mDir = std::string(BACKLIGHT_ROOT) + "/" + best;
    return true;
}

/* ----------------------------------------------------------------- config */

void
Backlight::ReloadConfigIfChanged()
{
    struct stat st;
    if (stat(CONFIG_PATH, &st) != 0) {
        mConfigMtime = 0;
        return;
    }
    if (st.st_mtime == mConfigMtime)
        return;
    mConfigMtime = st.st_mtime;

    FILE* f = fopen(CONFIG_PATH, "re");
    if (!f)
        return;

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;

        char* eq = strchr(p, '=');
        if (!eq)
            continue;
        *eq = '\0';
        const std::string key(p);
        const std::string val(eq + 1);

        if (key == "gamma") {
            const double g = atof(val.c_str());
            if (g >= 0.1 && g <= 5.0)
                mGamma = g;
        } else if (key == "min_percent") {
            const double m = atof(val.c_str());
            if (m >= 0.0 && m <= 100.0)
                mMinPercent = m;
        } else if (key == "device") {
            std::string v = val;
            while (!v.empty() && (v.back() == '\n' || v.back() == ' '))
                v.pop_back();
            mConfigDevice = v;
        }
    }
    fclose(f);

    GINFO("backlight.conf reloaded: gamma=%.2f min_percent=%.1f device=%s",
          mGamma, mMinPercent,
          mConfigDevice.empty() ? "(auto)" : mConfigDevice.c_str());
}

/* ---------------------------------------------------------------- mapping */

/*
 * Android hands us 0..255.  Its own floor here is 10 (mScreenBrightnessMinimum
 * 0.035433073 == 9/254), so the bottom of the slider already lands at ~4% duty
 * and the floor below is only a guard against pathological input.
 *
 * The default curve is LINEAR in PWM duty, deliberately.  intel_backlight is
 * type "raw", so duty is linear in luminance and perception is not -- a gamma
 * of roughly 2.2 would track perceived brightness better and make the lower
 * half of the slider useful.  It is not the default because the honest
 * identity map is the one whose behaviour can be predicted from the numbers,
 * and because the right exponent is a matter of taste on a specific panel.
 * Set gamma= in backlight.conf to taste; it reloads live.
 *
 * v == 0 is passed through as a real 0.  Android sends it to blank the screen,
 * and blanking is correct: 27-android-power-button.md found that Android
 * "asleep" today is black pixels at a full 937 backlight.
 */
int
Backlight::AndroidToRaw(int v) const
{
    if (mMaxRaw <= 0)
        return -1;

    v = std::max(0, std::min(255, v));
    if (v == 0)
        return 0;

    double frac = (double) v / 255.0;
    if (mGamma != 1.0)
        frac = pow(frac, mGamma);

    int raw = (int) lround(frac * (double) mMaxRaw);

    const int floor_raw = (int) lround(mMinPercent / 100.0 * (double) mMaxRaw);
    if (raw < floor_raw)
        raw = floor_raw;
    if (raw < 1)
        raw = 1;
    if (raw > mMaxRaw)
        raw = mMaxRaw;
    return raw;
}

/* ---------------------------------------------------------------- writing */

bool
Backlight::WriteRaw(int raw)
{
    const std::string path = mDir + "/brightness";
    const int fd = open(path.c_str(), O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        GWARN("open(%s): %s", path.c_str(), strerror(errno));
        return false;
    }

    char buf[32];
    const int n = snprintf(buf, sizeof(buf), "%d\n", raw);
    const ssize_t w = write(fd, buf, n);
    const int err = errno;
    close(fd);

    if (w != n) {
        GWARN("write(%s, %d): %s", path.c_str(), raw, strerror(err));
        return false;
    }
    return true;
}

int
Backlight::SetAndroidBrightness(int v)
{
    if (!Available())
        return -1;

    ReloadConfigIfChanged();

    const int raw = AndroidToRaw(v);
    if (raw < 0)
        return -1;

    /* Android re-sends the same brightness often (every wake, every
     * DisplayPowerController pass).  Each write pokes a PWM register, so
     * skip the no-ops. */
    if (raw == mLastRaw) {
        GVERBOSE("brightness %d -> raw %d (unchanged)", v, raw);
        return raw;
    }

    if (!WriteRaw(raw))
        return -1;

    GDEBUG("brightness %d/255 -> raw %d/%d", v, raw, mMaxRaw);
    mLastRaw = raw;
    return raw;
}

int
Backlight::ReadRaw(const char* attr) const
{
    if (mDir.empty())
        return -1;
    int v = 0;
    if (!read_int_file(mDir + "/" + attr, &v))
        return -1;
    return v;
}

void
Backlight::RestoreInitial()
{
    if (!Available() || mInitialRaw < 0 || mInitialRaw == mLastRaw)
        return;
    GINFO("Restoring backlight to %d on exit", mInitialRaw);
    WriteRaw(mInitialRaw);
    mLastRaw = mInitialRaw;
}

}  /* namespace waydroid */
