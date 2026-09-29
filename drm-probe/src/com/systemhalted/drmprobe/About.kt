/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.drmprobe

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Paint
import android.util.TypedValue
import android.widget.TextView

/**
 * The "About" link, and the dialog behind it: who wrote this app, who holds
 * the copyright, and under what licence it is distributed.
 *
 * This file is duplicated verbatim -- the package line aside -- in every app
 * in this repository: bt-app, drm-probe, media-app, quat-monitor, sensor-app
 * and touch-probe. Each of those builds from its own src/ directory with no
 * shared module and no dependency resolution, which is the whole reason the
 * build is four tool invocations rather than a Gradle daemon; a common source
 * root would have to be threaded through six build.sh files to save six small
 * copies of one screen. Change one, change all six; an md5sum over the six,
 * package line excluded, says whether they have drifted.
 *
 * Nothing here touches R. The name comes from the package manager, so the file
 * drops unchanged into the five apps whose build generates no R class.
 */
object About {

    private const val AUTHOR = "Jeremy Melanson (\"Zish\")"
    private const val AUTHOR_MAIL = "1080872+zish@users.noreply.github.com"
    private const val COAUTHOR = "Claude Code (Anthropic)"
    private const val COPYRIGHT = "Copyright © 2026 Jeremy Melanson"
    private const val LICENSE = "GPL-3.0-or-later"
    private const val SOURCE = "https://github.com/zish/waydroid-hp-envy-x2"

    /** The default link colour: legible on a dark screen and on a light one. */
    private const val LINK = 0xFF2196F3.toInt()

    /**
     * A tappable "About" label, for wherever an app has room for one. The
     * colour is a parameter because these apps do not share a palette -- some
     * paint their own dark background, some inherit a DayNight theme.
     */
    fun link(activity: Activity, colour: Int = LINK): TextView =
        TextView(activity).apply {
            text = "About"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(colour)
            paintFlags = paintFlags or Paint.UNDERLINE_TEXT_FLAG
            // A one-word label is a small target on a tablet held at arm's
            // length; the padding is what makes it tappable, not just visible.
            setPadding(pad(activity, 12), pad(activity, 8), pad(activity, 12), pad(activity, 8))
            isClickable = true
            setOnClickListener { show(activity) }
        }

    /** Opens the dialog. Public so a canvas-drawn hotspot can call it too. */
    fun show(activity: Activity) {
        if (activity.isFinishing) return
        val dialog = AlertDialog.Builder(activity)
            .setTitle("About " + appName(activity))
            .setMessage(body(activity))
            .setPositiveButton("Close", null)
            .show()
        try {
            // So the URL and the address can be copied out rather than copied
            // down. android.R.id.message is public API, but a themed dialog is
            // free not to use it, so the result is treated as optional.
            dialog.findViewById<TextView>(android.R.id.message)?.setTextIsSelectable(true)
        } catch (t: Throwable) {
            // Cosmetic. An About box must not be the thing that kills the app.
        }
    }

    private fun body(activity: Activity): String = buildString {
        version(activity)?.let {
            appendLine("Version $it")
            appendLine()
        }
        appendLine(
            "Part of the Waydroid hardware enablement project for Linux " +
                "laptops and tablets."
        )
        appendLine()
        appendLine("AUTHORS")
        appendLine(AUTHOR)
        appendLine(AUTHOR_MAIL)
        appendLine(COAUTHOR)
        appendLine()
        appendLine("COPYRIGHT")
        appendLine(COPYRIGHT)
        appendLine()
        appendLine("LICENSE")
        appendLine(LICENSE)
        appendLine()
        appendLine(
            "This program is free software: you can redistribute it and/or " +
                "modify it under the terms of the GNU General Public License " +
                "as published by the Free Software Foundation, either " +
                "version 3 of the License, or (at your option) any later " +
                "version."
        )
        appendLine()
        appendLine(
            "This program is distributed in the hope that it will be useful, " +
                "but WITHOUT ANY WARRANTY; without even the implied warranty " +
                "of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See " +
                "the GNU General Public License for more details."
        )
        appendLine()
        appendLine(
            "You should have received a copy of the GNU General Public " +
                "License along with this program. If not, see " +
                "https://www.gnu.org/licenses/."
        )
        appendLine()
        appendLine("SOURCE")
        append(SOURCE)
    }

    private fun appName(activity: Activity): String =
        try {
            activity.applicationInfo.loadLabel(activity.packageManager).toString()
        } catch (t: Throwable) {
            activity.packageName
        }

    /**
     * Nullable on purpose. All six apps declare versionName 1.0 today, but
     * aapt2 links a manifest without the attribute and says nothing, so one
     * that loses it would reach here as null; the line is then dropped rather
     * than rendered as "Version null".
     */
    private fun version(activity: Activity): String? =
        try {
            activity.packageManager.getPackageInfo(activity.packageName, 0)
                .versionName?.takeIf { it.isNotBlank() }
        } catch (t: Throwable) {
            null
        }

    private fun pad(activity: Activity, value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()
}
