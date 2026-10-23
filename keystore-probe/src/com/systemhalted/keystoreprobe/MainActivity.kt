/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.keystoreprobe

import android.app.Activity
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * Runs [Probe] once per launch, shows the report and writes it where the host can
 * fetch it.
 *
 * The probe runs on a background thread: every StrongBox call here is a binder
 * transaction to a host daemon that execs tpm2-tools against swtpm, so a key
 * generation takes on the order of a second, and none of that belongs on the main
 * looper.
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
        setContentView(ScrollView(this).apply { addView(tv) })

        Thread({
            val report = try {
                Probe().run()
            } catch (t: Throwable) {
                // The probe guards each step itself, so reaching here means
                // something outside those steps broke. Still a result; still saved.
                Log.e(Probe.TAG, "probe aborted", t)
                "Keystore Probe aborted: ${t.javaClass.name}: ${t.message}\n"
            }
            save(report)
            runOnUiThread { tv.text = report }
        }, "keystore-probe-main").start()
    }

    /**
     * Writes to the app's own external files dir, which is
     * `<waydroid data>/media/0/Android/data/<pkg>/files/reports` on the host -- the
     * same route the other probes use, so `build.sh --pull` is the same three lines.
     */
    private fun save(report: String) {
        try {
            val dir = getExternalFilesDir("reports") ?: return
            dir.mkdirs()
            File(dir, "keystore-probe.txt").writeText(report)
        } catch (t: Throwable) {
            Log.w(Probe.TAG, "could not save report: $t")
        }
    }
}
