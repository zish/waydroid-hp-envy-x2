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
 *
 * `am start -n <pkg>/.MainActivity --es mode auth-gen` (and auth-fresh,
 * auth-stale, auth-clean) runs one phase of the auth-bound key test instead, and
 * saves it as keystore-probe-<mode>.txt. The host force-stops the app between
 * phases, so each launch is a fresh onCreate.
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

        val mode = intent?.getStringExtra("mode") ?: ""
        Thread({
            val report = try {
                Probe().run(mode)
            } catch (t: Throwable) {
                // The probe guards each step itself, so reaching here means
                // something outside those steps broke. Still a result; still saved.
                Log.e(Probe.TAG, "probe aborted", t)
                "Keystore Probe aborted: ${t.javaClass.name}: ${t.message}\n"
            }
            save(report, if (mode.isEmpty()) "keystore-probe.txt" else "keystore-probe-$mode.txt")
            runOnUiThread { tv.text = report }
        }, "keystore-probe-main").start()
    }

    /**
     * Writes to the app's own external files dir, which is
     * `<waydroid data>/media/0/Android/data/<pkg>/files/reports` on the host -- the
     * same route the other probes use, so `build.sh --pull` is the same three lines.
     */
    private fun save(report: String, name: String) {
        try {
            val dir = getExternalFilesDir("reports") ?: return
            dir.mkdirs()
            // Write then rename, so a host polling for the file never reads half.
            val tmp = File(dir, "$name.tmp")
            tmp.writeText(report)
            tmp.renameTo(File(dir, name))
        } catch (t: Throwable) {
            Log.w(Probe.TAG, "could not save report: $t")
        }
    }
}
