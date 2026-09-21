package lan.syshlt.bluetooth

import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.json.JSONObject

/**
 * The Quick Settings tile, standing in for the stock Bluetooth one.
 *
 * The stock tile is inert in this image -- `dumpsys bluetooth_manager` reports
 * `state: OFF, address: null` because there is no com.android.bluetooth behind
 * it (docs/50) -- so it is a control that can only fail. This replaces it in
 * place, driving the host's adapter through waydroid-btd instead.
 *
 * SHORT LIFE, CACHED FACE
 *
 * A TileService is bound only while the tile is visible: onStartListening when
 * the shade opens, onStopListening when it closes. So this connects, reads one
 * snapshot and disconnects, several times a day, rather than holding a socket.
 *
 * That leaves a gap of a few hundred milliseconds where the tile would have
 * nothing to show, which is why the last painted state is cached: the tile is
 * drawn from that immediately and corrected when `ready` arrives. Without the
 * cache every pull-down flashes "unavailable" first, which reads as broken.
 *
 * It deliberately does NOT scan. Discovery belongs to the screen somebody is
 * looking at, and the daemon stops it when the last client disconnects -- which
 * would be every time the shade closed.
 *
 * No R here, like the rest of this app: the tile's icon and label come from the
 * <service> declaration in the manifest, so nothing needs a resource id at
 * runtime and the build stays free of the aapt2 --java / javac steps.
 */
class BtTileService : TileService(), BtClient.Listener {

    private var client: BtClient? = null
    private var adapter: JSONObject? = null
    private val devices = LinkedHashMap<String, JSONObject>()
    private var live = false

    override fun onStartListening() {
        super.onStartListening()
        // Defensively: SystemUI is not obliged to pair every onStartListening
        // with an onStopListening, and a leaked BtClient would sit in the
        // background retrying a socket forever on its backoff. Never hold two.
        client?.stop()
        client = null
        paintCached()
        val profile = Profile.load(this)
        if (profile == null) {
            paint(Tile.STATE_UNAVAILABLE, "No host daemon")
            return
        }
        client = BtClient(profile, this).also { it.start() }
    }

    override fun onStopListening() {
        super.onStopListening()
        client?.stop()
        client = null
        live = false
        adapter = null
        devices.clear()
    }

    override fun onClick() {
        super.onClick()
        val current = client
        val info = adapter
        if (!live || current == null || info == null) {
            // Nothing to toggle. Send the user to the screen that can say why,
            // rather than swallowing the tap.
            startActivityAndCollapse(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }
        val wanted = !info.optBoolean("powered")
        current.send("power") { it.put("on", wanted) }
        // Optimistic, and not cached: the adapter event confirms or corrects
        // this within a moment, and a half-finished state is not worth
        // restoring on the next pull-down if the toggle failed.
        paint(
            if (wanted) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE,
            if (wanted) "Turning on…" else "Off",
            remember = false
        )
    }

    // ---- client callbacks ------------------------------------------------

    override fun onConnected() {
        live = true
    }

    override fun onDisconnected(reason: String) {
        live = false
        paint(Tile.STATE_UNAVAILABLE, "Host daemon unreachable")
    }

    override fun onReply(id: Int, reply: JSONObject) {
        // Failures show up as a corrected adapter state; a tile has nowhere to
        // put an error string.
    }

    override fun onEvent(event: JSONObject) {
        when (event.optString("ev")) {
            "ready", "reset" -> {
                adapter = event.optJSONObject("adapter")
                devices.clear()
                val list = event.optJSONArray("devices")
                if (list != null) {
                    for (index in 0 until list.length()) {
                        val device = list.optJSONObject(index) ?: continue
                        devices[device.optString("path")] = device
                    }
                }
            }
            "adapter" -> adapter = event.optJSONObject("adapter")
            "device" -> {
                val device = event.optJSONObject("device") ?: return
                devices[device.optString("path")] = device
            }
            "device-removed" -> devices.remove(event.optString("path"))
            else -> return
        }
        repaint()
    }

    // ---- painting --------------------------------------------------------

    private fun repaint() {
        val info = adapter
        if (info == null) {
            paint(Tile.STATE_UNAVAILABLE, "No adapter")
            return
        }
        if (!info.optBoolean("powered")) {
            paint(Tile.STATE_INACTIVE, "Off")
            return
        }
        val connected = devices.values.filter { it.optBoolean("connected") }
        paint(
            Tile.STATE_ACTIVE,
            when (connected.size) {
                0 -> "On"
                1 -> Devices.title(connected.first())
                else -> connected.size.toString() + " connected"
            }
        )
    }

    private fun paint(state: Int, subtitle: String, remember: Boolean = true) {
        if (remember) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putInt("state", state)
                .putString("subtitle", subtitle)
                .apply()
        }
        val tile = qsTile ?: return
        tile.state = state
        // The label is left alone: it comes from android:label on the <service>
        // element, which is the same @string/app_name the launcher uses.
        tile.subtitle = subtitle
        tile.contentDescription = "Bluetooth, " + subtitle
        tile.updateTile()
    }

    private fun paintCached() {
        val tile = qsTile ?: return
        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
        tile.state = prefs.getInt("state", Tile.STATE_UNAVAILABLE)
        tile.subtitle = prefs.getString("subtitle", "…")
        tile.updateTile()
    }

    private companion object {
        const val PREFS = "tile"
    }
}
