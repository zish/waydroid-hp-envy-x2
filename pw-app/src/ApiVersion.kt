/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.patchbay

import android.app.Activity
import android.content.Intent
import android.net.Uri
import org.json.JSONObject

/**
 * What wire formats this app speaks, and what to do when the host disagrees.
 *
 * See docs/58-api-versioning.md. Three numbers matter and they are not the same
 * number: this app's versionName, waydroid-ext-pwd's package version, and the
 * API version below. Only the last one decides whether the two can talk.
 *
 * BACKWARD COMPATIBILITY LIVES HERE, NOT IN THE DAEMON, and that is deliberate.
 * F-Droid updates this app in the background with no user action; the host
 * package waits for somebody to run `dnf upgrade`. So in the field this app
 * will usually be running AHEAD of the daemon, and the only thing that stops
 * that being a broken connection is this app continuing to speak the older
 * format. Hence MIN trailing MAX by two releases of the protocol rather than
 * tracking it.
 */
object ApiVersion {

    /** The newest wire format this build understands. */
    const val MAX = 1

    /**
     * The oldest it still speaks: a trailing window of two.
     *
     * coerceAtLeast(1) because there is no API 0 and MAX starts at 1; the
     * arithmetic only begins to bite once MAX reaches 3.
     */
    val MIN = (MAX - 2).coerceAtLeast(1)

    /** Put our range on an outgoing auth message. */
    fun declare(auth: JSONObject): JSONObject =
        auth.put("api_min", MIN).put("api_max", MAX)

    // ---- the refusal -----------------------------------------------------

    private const val FDROID = "https://f-droid.org/packages/"
    private const val SOURCE = "https://github.com/zish/waydroid-hp-envy-x2"

    /**
     * A daemon's structured refusal of our range.
     *
     * Structured rather than a human string on purpose: "update the app" and
     * "update the host package" send the user to completely different places,
     * and the app cannot pick between them by reading prose.
     */
    class Mismatch(
        val reason: String,
        val appMin: Int,
        val appMax: Int,
        val daemonMin: Int,
        val daemonMax: Int,
        val hostPackage: String?,
        val hostVersion: String?
    ) {

        /** True when the host is the half that has to move. */
        val hostIsBehind: Boolean get() = reason == "app_too_new"

        fun title(): String = when (reason) {
            "app_too_new" -> "Host service is too old"
            "app_too_old" -> "This app is too old"
            else -> "Cannot agree a protocol version"
        }

        fun detail(): String {
            val pkg = hostPackage ?: "waydroid-ext-pwd"
            val ver = hostVersion?.let { " $it" } ?: ""
            return when (reason) {
                "app_too_new" ->
                    "This app speaks protocol $appMin–$appMax. The host " +
                        "daemon$ver speaks $daemonMin–$daemonMax, so it is " +
                        "the half that needs updating.\n\nOn the host:\n" +
                        "    sudo dnf upgrade $pkg\n\n" +
                        "On an rpm-ostree host such as Fedora Atomic:\n" +
                        "    sudo rpm-ostree upgrade\n\n" +
                        "Updating this app again will not help."
                "app_too_old" ->
                    "This app speaks protocol $appMin–$appMax. The host " +
                        "daemon$ver speaks $daemonMin–$daemonMax and no " +
                        "longer supports a version this old.\n\n" +
                        "Install the current release of the app."
                else ->
                    "This app reported protocol $appMin–$appMax, which the " +
                        "host daemon$ver could not make sense of. This is a bug " +
                        "in the app; please report it."
            }
        }

        /** Null when there is nothing the app can usefully open. */
        fun actionLabel(): String? = if (hostIsBehind) null else "Get the latest app"

        /**
         * Send the user somewhere useful.
         *
         * Only for the app-too-old direction. There is deliberately no action
         * for app-too-new: this app has no route to dnf on the host, and the
         * daemon that might have run something on its behalf is the component
         * that is too old. That screen is text and a command to copy.
         *
         * No downgrade offer either, for a reason that overrides how tempting
         * it is: F-Droid's auto-update would put the user straight back into
         * the break, so the button would hand out a loop and call it a fix.
         */
        fun act(activity: Activity) {
            if (hostIsBehind) return
            val appId = activity.packageName
            val target = Uri.parse(FDROID + appId + "/")
            val intent = Intent(Intent.ACTION_VIEW, target)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (activity.packageManager.resolveActivity(intent, 0) != null) {
                activity.startActivity(intent)
                return
            }
            // No browser and no F-Droid client, which a kiosk image can manage.
            // The source page at least names the release.
            activity.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("$SOURCE/releases"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }

        companion object {
            /**
             * Read a refusal, or null if this reply is not one.
             *
             * Tolerant of a daemon that reports the failure without the detail:
             * an older daemon than the one this was written against might send
             * only `err`, and a screen saying "versions disagree" beats a
             * reconnect loop saying nothing.
             */
            fun from(reply: JSONObject): Mismatch? {
                if (reply.optString("err") != "api_unsupported") return null
                val daemon = reply.optJSONObject("daemon")
                val app = reply.optJSONObject("app")
                return Mismatch(
                    reason = reply.optString("reason", "unknown"),
                    appMin = app?.optInt("api_min", MIN) ?: MIN,
                    appMax = app?.optInt("api_max", MAX) ?: MAX,
                    daemonMin = daemon?.optInt("api_min", 0) ?: 0,
                    daemonMax = daemon?.optInt("api_max", 0) ?: 0,
                    hostPackage = daemon?.optString("package").takeUnless { it.isNullOrEmpty() },
                    hostVersion = daemon?.optString("version").takeUnless { it.isNullOrEmpty() }
                )
            }
        }
    }
}
