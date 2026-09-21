package lan.syshlt.bluetooth

import org.json.JSONObject

/**
 * Presentation rules for one BlueZ device.
 *
 * Kept out of the Activity because these are judgements about BlueZ, not about
 * layout: which of three name fields to believe, what "available" means when a
 * device is paired but out of range, and how to turn an icon hint into
 * something a person recognises at a glance.
 */
object Devices {

    /** BlueZ's icon hints, which come from the device's class-of-device. */
    private val GLYPHS = mapOf(
        "audio-card" to "🔊",
        "audio-headset" to "🎧",
        "audio-headphones" to "🎧",
        "audio-speakers" to "🔊",
        "input-keyboard" to "⌨",
        "input-mouse" to "🖱",
        "input-tablet" to "✎",
        "input-gaming" to "🎮",
        "phone" to "📱",
        "computer" to "💻",
        "printer" to "🖨",
        "camera-photo" to "📷",
        "camera-video" to "📹",
        "video-display" to "📺",
        "modem" to "📡",
        "network-wireless" to "📡",
        "scanner" to "🖨"
    )

    /** The handful of profile UUIDs worth naming in an authorisation prompt. */
    private val SERVICES = mapOf(
        "0000110a" to "audio source",
        "0000110b" to "audio output",
        "0000110c" to "remote control target",
        "0000110e" to "remote control",
        "00001105" to "file transfer",
        "00001106" to "file transfer",
        "0000111e" to "hands-free calling",
        "0000111f" to "hands-free gateway",
        "00001124" to "keyboard or mouse",
        "00001132" to "messages",
        "0000112f" to "contacts",
        "00001812" to "input device"
    )

    fun glyph(device: JSONObject): String {
        val icon = device.optString("icon", "")
        GLYPHS[icon]?.let { return it }
        // No icon hint at all is the normal case for a bare BLE advertisement.
        return if (device.optBoolean("paired")) "🔷" else "○"
    }

    fun title(device: JSONObject): String {
        for (key in arrayOf("alias", "name")) {
            val value = device.optString(key, "")
            if (value.isNotEmpty() && value != "null") return value
        }
        return device.optString("addr", "unknown")
    }

    /**
     * True when the title is really just the address with the colons swapped
     * for dashes, which is what BlueZ falls back to. Such a device is worth
     * showing -- it may be the thing being paired -- but not worth ranking
     * above one that told us its name.
     */
    fun isAnonymous(device: JSONObject): Boolean {
        val addr = device.optString("addr", "").replace(':', '-')
        return addr.isNotEmpty() && title(device).equals(addr, ignoreCase = true)
    }

    fun subtitle(device: JSONObject): String {
        val parts = ArrayList<String>(4)
        when {
            device.optBoolean("connected") -> parts.add("Connected")
            device.optBoolean("paired") -> parts.add("Paired")
        }
        if (device.has("battery")) parts.add("battery " + device.optInt("battery") + "%")
        if (device.optBoolean("trusted")) parts.add("trusted")
        if (device.optBoolean("blocked")) parts.add("blocked")
        if (device.has("rssi")) parts.add(device.optInt("rssi").toString() + " dBm")
        parts.add(device.optString("addr", ""))
        return parts.joinToString(" · ")
    }

    fun serviceName(uuid: String?): String {
        if (uuid == null || uuid.length < 8) return "a service"
        return SERVICES[uuid.substring(0, 8).lowercase()] ?: "a service"
    }

    /**
     * Paired devices first and in a stable order, because that list is a
     * possession list and things must not jump around in it. Everything else is
     * ordered by signal, which is the only useful ordering while scanning --
     * with named devices ahead of anonymous ones at equal strength.
     */
    fun compareAvailable(a: JSONObject, b: JSONObject): Int {
        val anon = isAnonymous(a).compareTo(isAnonymous(b))
        if (anon != 0) return anon
        val strength = rssi(b).compareTo(rssi(a))
        if (strength != 0) return strength
        return title(a).compareTo(title(b), ignoreCase = true)
    }

    fun comparePaired(a: JSONObject, b: JSONObject): Int {
        val live = b.optBoolean("connected").compareTo(a.optBoolean("connected"))
        if (live != 0) return live
        return title(a).compareTo(title(b), ignoreCase = true)
    }

    private fun rssi(device: JSONObject): Int =
        if (device.has("rssi")) device.optInt("rssi") else -127
}
