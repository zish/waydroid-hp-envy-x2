/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.appfuseprobe

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * Runs [Probe] once per launch, shows the report and writes it where the host can
 * fetch it.
 *
 * The probe runs on a background thread rather than in `onCreate`, which matters here
 * in a way it does not for the other probes in this repo: this one does a megabyte of
 * blocking I/O through FUSE, and on a container where the mount is broken every read
 * path instead throws. Either way it has no business on the main looper.
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val tv = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 9f
            setPadding(16, 16, 16, 16)
            setTextIsSelectable(true)
            text = "running..."
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(About.link(this@MainActivity))
            addView(ScrollView(this@MainActivity).apply { addView(tv) },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })

        Thread({
            val report = try {
                Probe(this).run()
            } catch (t: Throwable) {
                // The probe guards every step of its own, so reaching here means
                // something outside those steps broke. Still a result; still saved.
                Log.e(Probe.TAG, "probe aborted", t)
                "AppFuse Probe aborted: ${t.javaClass.name}: ${t.message}\n"
            }
            save(report)
            runOnUiThread { tv.text = report }
        }, "appfuse-probe-main").start()
    }

    /**
     * Writes to the app's own external files dir, which is
     * `<waydroid data>/media/0/Android/data/<pkg>/files/reports` on the host -- the
     * same route drm-probe uses, so `build.sh --pull` is the same three lines.
     */
    private fun save(report: String) {
        try {
            val dir = getExternalFilesDir("reports") ?: return
            dir.mkdirs()
            File(dir, "appfuse-probe.txt").writeText(report)
        } catch (t: Throwable) {
            Log.w(Probe.TAG, "could not save report: $t")
        }
    }
}
