/*
 * Copyright © 2021 Waydroid Project.
 * Copyright © 2026 bigtab01-waydroid project (SensorFW -> SensorIIO).
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
 * Authored by: Erfan Abdi <erfangplus@gmail.com>
 */

#ifndef WAYDROID_HARDWARE_SENSORS_H_
#define WAYDROID_HARDWARE_SENSORS_H_

#include <gbinder.h>
#include <gutil_log.h>
#include <glib-unix.h>

#include <vector>

#include "hybrisbindertypes.h"
#include "SensorIIO.h"

using waydroid::SensorIIO;

namespace waydroid {
namespace sensors {
namespace implementation {

constexpr char kVendor[] = "bigtab01-waydroid (ITE8350 via Linux IIO)";

typedef struct SensorDevice {
    SensorIIO *mIioDevice;
    uint64_t last_TimeStamp[MAX_NUM_SENSORS];
    sensors_event_t sensors[MAX_NUM_SENSORS];
    uint32_t pendingSensors;
    int64_t timeStart;
    int64_t timeOffset;
    uint32_t active_sensors;
    int flush_count[MAX_NUM_SENSORS];
    pthread_mutex_t lock;
    GMainLoop *loop;
    bool waiting_for_data;
} SensorDevice;

struct Sensors {
    Sensors();

    std::vector<sensor_t> getSensorsList();
    int activate(int32_t handle, bool enabled);
    std::vector<sensors_event_t> poll(int32_t maxCount, int *err_out);
    int flush(int32_t handle);
    void killLoops();

    /* Exposed so service.cpp can run --selftest without binder. */
    SensorIIO *iio() { return mSensorDevice->mIioDevice; }

private:
    static constexpr int32_t kPollMaxBufferSize = 128;
    SensorDevice *mSensorDevice;
};

}  // namespace implementation
}  // namespace sensors
}  // namespace waydroid

#endif  // WAYDROID_HARDWARE_SENSORS_H_
