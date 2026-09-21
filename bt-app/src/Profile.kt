package lan.syshlt.bluetooth

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * How to reach waydroid-btd.
 *
 * The host daemon drops this as JSON in the app's own files directory. It can
 * do that because the container mounts /data straight off the host filesystem
 * and SELinux is Disabled *inside* the container, so a root-written file with
 * the app's uid on it is simply readable -- no labelling, no provider, no
 * broadcast that only lands if the app happens to be running.
 *
 * A manual override is kept in SharedPreferences for the case where the daemon
 * could not publish one: it runs with --no-profile, or the package name was
 * changed, or somebody is pointing this at a different machine entirely.
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
        const val FILE_NAME = "btd.json"
        private const val PREFS = "btd"

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
                prefs.getInt("port", 7712),
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
                json.optInt("port", 7712),
                json.optString("token", ""),
                json.optBoolean("tls", false),
                if (pin.isEmpty() || pin == "null") null else pin,
                source
            )
        }
    }
}
