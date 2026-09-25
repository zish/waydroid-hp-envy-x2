/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.patchbay

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * How to reach waydroid-pwd.
 *
 * The profile is dropped as JSON into this app's own files directory. Two
 * processes on the host are involved and the split is the point: the daemon
 * runs unprivileged as the session user (PipeWire is a user service) and writes
 * the profile where only it can, and waydroid-pwd-publish -- root, and nothing
 * else -- copies it here, because this directory is mode 0700 owned by this
 * app's uid.
 *
 * That uid is the security boundary. SELinux is Disabled inside the container,
 * so the file needs no labelling and no content provider; but Android uids are
 * real uids, so the kernel keeps every other app in the container out of it.
 * The token in here is therefore bound to this app in a way that a bind-mounted
 * PipeWire socket could never be.
 *
 * A manual override is kept in SharedPreferences for when the daemon could not
 * publish one: it runs with --no-profile, or the package name was changed, or
 * somebody is pointing this at a different machine entirely.
 */
class Profile(
    val host: String,
    val port: Int,
    val token: String,
    val tls: Boolean,
    val pin: String?,
    val source: String
) {

    fun describe(): String {
        val wire = if (tls) "TLS" else "plaintext"
        return "$host:$port · $wire · $source"
    }

    companion object {
        const val FILE_NAME = "profile.json"
        const val DEFAULT_PORT = 7713
        private const val PREFS = "pwd"

        fun load(context: Context): Profile? = manual(context) ?: published(context)

        fun published(context: Context): Profile? {
            val file = File(context.filesDir, FILE_NAME)
            if (!file.isFile) return null
            return try {
                parse(JSONObject(file.readText()), "published by the host")
            } catch (exc: Exception) {
                null
            }
        }

        fun manual(context: Context): Profile? {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val host = prefs.getString("host", null) ?: return null
            return Profile(
                host,
                prefs.getInt("port", DEFAULT_PORT),
                prefs.getString("token", "") ?: "",
                prefs.getBoolean("tls", false),
                prefs.getString("pin", null),
                "entered by hand"
            )
        }

        fun saveManual(context: Context, profile: Profile?) {
            val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            if (profile == null) {
                editor.clear()
            } else {
                editor.putString("host", profile.host)
                    .putInt("port", profile.port)
                    .putString("token", profile.token)
                    .putBoolean("tls", profile.tls)
                    .putString("pin", profile.pin)
            }
            editor.apply()
        }

        private fun parse(json: JSONObject, source: String): Profile {
            val pin = json.optString("pin", "")
            return Profile(
                json.optString("host", "192.168.240.1"),
                json.optInt("port", DEFAULT_PORT),
                json.optString("token", ""),
                json.optBoolean("tls", false),
                if (pin.isEmpty() || pin == "null") null else pin,
                source
            )
        }
    }
}
