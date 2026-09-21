package lan.syshlt.bluetooth

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

/**
 * The whole UI. Built programmatically for the same reason as sensor-app and
 * media-app: no AndroidX and no Compose, so the build stays a handful of tool
 * invocations instead of a Gradle daemon and a Maven cache.
 *
 * It holds no Bluetooth state of its own beyond what the daemon has told it.
 * Every view here is a rendering of the last snapshot plus the events since,
 * and a reconnect throws the lot away and starts from a fresh `ready` -- which
 * is why a daemon restart, a bluetoothd restart or a flapping link all converge
 * on the truth without any reconciliation code.
 */
class MainActivity : Activity(), BtClient.Listener {

    private val handler = Handler(Looper.getMainLooper())
    private val devices = LinkedHashMap<String, JSONObject>()
    private val pendingLabels = HashMap<Int, String>()

    private var profile: Profile? = null
    private var client: BtClient? = null
    private var adapter: JSONObject? = null
    private var status = "Starting"
    private var live = false
    private var userStoppedScan = false

    private var agentDialog: AlertDialog? = null
    private var agentRequest = -1

    private lateinit var scroller: ScrollView
    private lateinit var content: LinearLayout

    private val renderTask = Runnable { render() }

    /**
     * Discovery is capped rather than left running. Android's own Settings does
     * the same thing, and for the same reason: classic inquiry degrades the
     * links to devices that are already connected -- here, the keyboard the
     * owner is typing on.
     */
    private val scanStopTask = Runnable {
        if (live) command("Scan", "scan") { it.put("on", false) }
    }

    // ---- lifecycle -------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(32))
        }
        scroller = ScrollView(this).apply {
            setBackgroundColor(BACKGROUND)
            addView(content)
        }
        setContentView(scroller)
    }

    override fun onStart() {
        super.onStart()
        connect()
    }

    override fun onStop() {
        super.onStop()
        // Leaving the screen stops the radio scanning -- but the daemon does
        // that itself when the last client disconnects, because a send() here
        // would race the socket being closed underneath it and would not cover
        // a crash or a force-stop anyway.
        handler.removeCallbacks(scanStopTask)
        client?.stop()
        client = null
        live = false
        dismissAgentDialog()
    }

    private fun connect() {
        profile = Profile.load(this)
        val current = profile
        if (current == null) {
            status = "No connection profile"
            render()
            return
        }
        status = "Connecting to " + current.host
        client = BtClient(current, this).also { it.start() }
        render()
    }

    private fun reconnect() {
        client?.stop()
        client = null
        live = false
        devices.clear()
        adapter = null
        connect()
    }

    // ---- client callbacks ------------------------------------------------

    override fun onConnected() {
        live = true
        status = "Connected"
        scheduleRender()
    }

    override fun onDisconnected(reason: String) {
        live = false
        status = "Reconnecting — " + reason
        scheduleRender()
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
                if (!userStoppedScan && adapter?.optBoolean("powered") == true) {
                    client?.send("scan") { it.put("on", true) }
                }
            }
            "adapter" -> adapter = event.optJSONObject("adapter")
            "device" -> {
                val device = event.optJSONObject("device") ?: return
                devices[device.optString("path")] = device
            }
            "device-removed" -> devices.remove(event.optString("path"))
            "agent" -> return showAgentPrompt(event)
            "agent-show" -> return showAgentDisplay(event)
            "agent-cancel" -> {
                dismissAgentDialog()
                toast("Pairing cancelled")
            }
        }
        trackScan()
        scheduleRender()
    }

    override fun onReply(id: Int, reply: JSONObject) {
        val label = pendingLabels.remove(id)
        if (!reply.optBoolean("ok", false)) {
            val error = reply.optString("error", "failed")
            toast(if (label != null) "$label: ${humanise(error)}" else humanise(error))
        } else if (label != null && label.startsWith("Forget")) {
            toast(label + " — done")
        }
    }

    /** BlueZ error names are precise and unreadable; the tail usually is not. */
    private fun humanise(error: String): String {
        val message = error.substringAfter(": ", "").trim()
        if (message.isNotEmpty()) return message
        return error.substringAfterLast('.').ifEmpty { error }
    }

    // ---- issuing commands ------------------------------------------------

    private fun command(label: String, name: String, build: (JSONObject) -> Unit = {}) {
        val current = client
        if (current == null || !live) {
            toast("Not connected to the host daemon")
            return
        }
        pendingLabels[current.send(name, build)] = label
    }

    private fun deviceCommand(label: String, name: String, device: JSONObject,
                              build: (JSONObject) -> Unit = {}) {
        command(label, name) {
            it.put("addr", device.optString("addr"))
            build(it)
        }
    }

    // ---- rendering -------------------------------------------------------

    private fun trackScan() {
        handler.removeCallbacks(scanStopTask)
        if (adapter?.optBoolean("discovering") == true) {
            handler.postDelayed(scanStopTask, SCAN_SECONDS * 1000L)
        }
    }

    private fun scheduleRender() {
        // Coalesced: a scan produces an event per advertisement per device, and
        // rebuilding the tree for each one would make the list unusable.
        handler.removeCallbacks(renderTask)
        handler.postDelayed(renderTask, 150)
    }

    private fun render() {
        val scrollY = scroller.scrollY
        content.removeAllViews()

        content.addView(header())
        content.addView(gap(dp(18)))

        val current = profile
        if (current == null) {
            content.addView(
                note(
                    "The host daemon has not published a connection profile.\n\n" +
                        "Start waydroid-btd on the host and reopen this screen, " +
                        "or enter the details by hand."
                )
            )
            content.addView(gap(dp(12)))
            content.addView(wideButton("Enter connection details") { editConnection() })
            scroller.post { scroller.scrollTo(0, scrollY) }
            return
        }

        content.addView(adapterCard())
        content.addView(gap(dp(20)))

        val paired = devices.values.filter { it.optBoolean("paired") }
            .sortedWith(Devices::comparePaired)
        val available = devices.values.filter { !it.optBoolean("paired") }
            .sortedWith(Devices::compareAvailable)

        content.addView(sectionTitle("Paired devices"))
        if (paired.isEmpty()) {
            content.addView(note("Nothing paired yet."))
        } else {
            for (device in paired) content.addView(deviceRow(device))
        }

        content.addView(gap(dp(20)))
        content.addView(
            sectionTitle(
                if (adapter?.optBoolean("discovering") == true)
                    "Available devices — scanning" else "Available devices"
            )
        )
        if (available.isEmpty()) {
            content.addView(
                note(
                    if (adapter?.optBoolean("powered") == true) "Nothing found yet."
                    else "Bluetooth is off."
                )
            )
        } else {
            for (device in available) content.addView(deviceRow(device))
        }

        scroller.post { scroller.scrollTo(0, scrollY) }
    }

    private fun header(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = fill()
        }
        val titles = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        titles.addView(label("Bluetooth", 24f, Color.WHITE, bold = true))
        val detail = profile?.let { status + " · " + it.describe() } ?: status
        titles.addView(label(detail, 12f, if (live) DIM else WARN))
        row.addView(titles)
        row.addView(smallButton("⚙") { editConnection() })
        return row
    }

    private fun adapterCard(): View {
        val card = cardBox()
        val info = adapter
        if (info == null) {
            card.addView(label("No Bluetooth adapter on the host", 15f, WARN))
            return card
        }

        val name = info.optString("alias", info.optString("name", "this computer"))
        val nameRow = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = fill()
        }
        nameRow.addView(label(name, 17f, Color.WHITE, bold = true).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        nameRow.addView(smallButton("Rename") { renameAdapter(name) })
        card.addView(nameRow)
        card.addView(label(info.optString("addr", ""), 12f, DIM))
        card.addView(gap(dp(10)))

        card.addView(toggle("Bluetooth", info.optBoolean("powered")) { on ->
            command("Power", "power") { it.put("on", on) }
        })
        card.addView(toggle("Visible to other devices", info.optBoolean("discoverable")) { on ->
            command("Discoverable", "discoverable") {
                it.put("on", on)
                // Zero means "until turned off". BlueZ's own default is 180 s,
                // which is wrong for a tablet somebody is pairing a headset to
                // while reading instructions on the same screen.
                it.put("timeout", 0)
            }
        })

        card.addView(gap(dp(8)))
        val scanning = info.optBoolean("discovering")
        card.addView(wideButton(if (scanning) "Stop scanning" else "Scan for devices") {
            userStoppedScan = scanning
            command("Scan", "scan") { it.put("on", !scanning) }
        })
        return card
    }

    private fun deviceRow(device: JSONObject): View {
        val row = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(12), dp(14), dp(12))
            setBackgroundColor(CARD)
            isClickable = true
            layoutParams = fill()
            setOnClickListener { deviceActions(device) }
        }

        row.addView(label(Devices.glyph(device), 20f, Color.WHITE).apply {
            width = dp(36)
        })
        val text = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        text.addView(
            label(
                Devices.title(device), 16f,
                if (device.optBoolean("connected")) ACCENT else Color.WHITE
            )
        )
        text.addView(label(Devices.subtitle(device), 12f, DIM))
        row.addView(text)

        val wrapper = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = fill()
            addView(row)
            addView(gap(dp(6)))
        }
        return wrapper
    }

    // ---- dialogs ---------------------------------------------------------

    private fun deviceActions(device: JSONObject) {
        val name = Devices.title(device)
        val paired = device.optBoolean("paired")
        val connected = device.optBoolean("connected")
        val trusted = device.optBoolean("trusted")
        val blocked = device.optBoolean("blocked")

        val actions = ArrayList<Pair<String, () -> Unit>>()
        if (!paired) {
            actions.add("Pair" to {
                deviceCommand("Pair with $name", "pair", device)
                toast("Pairing with $name…")
            })
        }
        if (connected) {
            actions.add("Disconnect" to { deviceCommand("Disconnect", "disconnect", device) })
        } else {
            actions.add("Connect" to {
                deviceCommand("Connect to $name", "connect", device)
                toast("Connecting to $name…")
            })
        }
        actions.add((if (trusted) "Stop trusting" else "Trust (connect automatically)") to {
            deviceCommand("Trust", "trust", device) { it.put("on", !trusted) }
        })
        actions.add("Rename" to { renameDevice(device, name) })
        actions.add((if (blocked) "Unblock" else "Block") to {
            deviceCommand("Block", "block", device) { it.put("on", !blocked) }
        })
        if (paired) {
            actions.add("Forget this device" to { confirmForget(device, name) })
        }

        AlertDialog.Builder(this)
            .setTitle(name)
            .setItems(actions.map { it.first }.toTypedArray()) { _, which ->
                actions[which].second()
            }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun confirmForget(device: JSONObject, name: String) {
        AlertDialog.Builder(this)
            .setTitle("Forget $name?")
            .setMessage(
                "The pairing is removed from this computer. You will have to " +
                    "pair again to use it."
            )
            .setPositiveButton("Forget") { _, _ ->
                deviceCommand("Forget $name", "remove", device)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun renameDevice(device: JSONObject, current: String) {
        promptForText("Rename", current) { value ->
            deviceCommand("Rename", "rename", device) { it.put("alias", value) }
        }
    }

    private fun renameAdapter(current: String) {
        promptForText("Name this computer", current) { value ->
            command("Rename", "alias") { it.put("name", value) }
        }
    }

    private fun promptForText(title: String, initial: String, done: (String) -> Unit) {
        val field = EditText(this).apply {
            setText(initial)
            setSelection(initial.length)
        }
        AlertDialog.Builder(this)
            .setTitle(title)
            .setView(pad(field))
            .setPositiveButton("Save") { _, _ ->
                val value = field.text.toString().trim()
                if (value.isNotEmpty()) done(value)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * A pairing request from BlueZ, forwarded by the daemon. Answering is
     * mandatory in the sense that the daemon holds the D-Bus reply open until
     * this dialog is answered or its timeout expires, so the dialog is not
     * dismissable by tapping outside it.
     */
    private fun showAgentPrompt(event: JSONObject) {
        dismissAgentDialog()
        agentRequest = event.optInt("req", -1)
        val name = event.optString("alias", event.optString("name", ""))
            .ifEmpty { event.optString("addr", "a device") }
        val builder = AlertDialog.Builder(this).setCancelable(false)

        when (event.optString("kind")) {
            "confirm" -> builder
                .setTitle("Pair with $name?")
                .setMessage(
                    "Check that the same code is shown on the other device:" +
                        "\n\n        " + passkeyText(event.optInt("passkey")) + "\n"
                )
                .setPositiveButton("Pair") { _, _ -> answerAgent(true, null) }
                .setNegativeButton("Cancel") { _, _ -> answerAgent(false, null) }

            "authorize" -> builder
                .setTitle("Pair with $name?")
                .setMessage("$name is asking to pair with this computer.")
                .setPositiveButton("Pair") { _, _ -> answerAgent(true, null) }
                .setNegativeButton("Cancel") { _, _ -> answerAgent(false, null) }

            "authorize-service" -> builder
                .setTitle("Allow connection?")
                .setMessage(
                    name + " wants to use " +
                        Devices.serviceName(event.optString("uuid")) + "."
                )
                .setPositiveButton("Allow") { _, _ -> answerAgent(true, null) }
                .setNegativeButton("Deny") { _, _ -> answerAgent(false, null) }

            "passkey", "pin" -> {
                val numeric = event.optString("kind") == "passkey"
                val field = EditText(this).apply {
                    inputType = if (numeric) InputType.TYPE_CLASS_NUMBER
                    else InputType.TYPE_CLASS_TEXT
                    hint = if (numeric) "6-digit passkey" else "PIN"
                }
                builder
                    .setTitle("Pair with $name")
                    .setMessage(
                        if (numeric) "Enter the passkey shown on $name."
                        else "Enter the PIN for $name (often 0000 or 1234)."
                    )
                    .setView(pad(field))
                    .setPositiveButton("Pair") { _, _ ->
                        answerAgent(true, field.text.toString().trim())
                    }
                    .setNegativeButton("Cancel") { _, _ -> answerAgent(false, null) }
            }

            else -> {
                answerAgent(false, null)
                return
            }
        }
        agentDialog = builder.show()
    }

    /**
     * The other direction: BlueZ is telling the user what to type on the device
     * being paired. There is nothing to answer, so this one only offers a way
     * out -- which has to cancel the pairing, not just hide the dialog.
     */
    private fun showAgentDisplay(event: JSONObject) {
        dismissAgentDialog()
        val name = event.optString("alias", event.optString("name", ""))
            .ifEmpty { event.optString("addr", "the device") }
        val code = if (event.has("passkey")) passkeyText(event.optInt("passkey"))
        else event.optString("pin", "")
        val addr = event.optString("addr", "")
        agentRequest = -1
        agentDialog = AlertDialog.Builder(this)
            .setCancelable(false)
            .setTitle("Pairing with $name")
            .setMessage("Type this on $name, then press Enter:\n\n        $code\n")
            .setNegativeButton("Cancel") { _, _ ->
                if (addr.isNotEmpty()) {
                    command("Cancel pairing", "cancel-pair") { it.put("addr", addr) }
                }
            }
            .show()
    }

    private fun answerAgent(accept: Boolean, value: String?) {
        val request = agentRequest
        agentRequest = -1
        agentDialog = null
        if (request < 0) return
        command(if (accept) "Pairing" else "Cancel", "agent-reply") {
            it.put("req", request)
            it.put("accept", accept)
            if (value != null) it.put("value", value)
        }
    }

    private fun dismissAgentDialog() {
        agentDialog?.let {
            try {
                it.dismiss()
            } catch (exc: Exception) {
                // the window is already gone
            }
        }
        agentDialog = null
    }

    /** BlueZ passkeys are six digits and leading zeros are significant. */
    private fun passkeyText(passkey: Int): String = String.format("%06d", passkey)

    private fun editConnection() {
        val current = profile
        val host = EditText(this).apply {
            hint = "host"; setText(current?.host ?: "192.168.240.1")
        }
        val port = EditText(this).apply {
            hint = "port"
            inputType = InputType.TYPE_CLASS_NUMBER
            setText((current?.port ?: 7712).toString())
        }
        val token = EditText(this).apply {
            hint = "token"; setText(current?.token ?: "")
        }
        val pin = EditText(this).apply {
            hint = "certificate fingerprint (TLS only)"
            setText(current?.pin ?: "")
        }
        val tls = CheckBox(this).apply {
            text = "Use TLS"
            setTextColor(Color.WHITE)
            isChecked = current?.tls ?: false
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), dp(8))
            addView(host); addView(port); addView(token); addView(tls); addView(pin)
        }
        AlertDialog.Builder(this)
            .setTitle("Host daemon")
            .setView(ScrollView(this).apply { addView(box) })
            .setPositiveButton("Save") { _, _ ->
                Profile.saveManual(
                    this,
                    Profile(
                        host.text.toString().trim(),
                        port.text.toString().trim().toIntOrNull() ?: 7712,
                        token.text.toString().trim(),
                        tls.isChecked,
                        pin.text.toString().trim().ifEmpty { null },
                        "entered by hand"
                    )
                )
                reconnect()
            }
            .setNeutralButton("Use the published one") { _, _ ->
                Profile.saveManual(this, null)
                reconnect()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    // ---- view helpers ----------------------------------------------------

    private fun label(text: String, size: Float, colour: Int, bold: Boolean = false): TextView =
        TextView(this).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
            setTextColor(colour)
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

    private fun sectionTitle(text: String): View =
        label(text.uppercase(), 12f, DIM, bold = true).apply {
            setPadding(dp(2), 0, 0, dp(8))
            letterSpacing = 0.08f
        }

    private fun note(text: String): View =
        label(text, 14f, DIM).apply { setPadding(dp(2), 0, dp(2), 0) }

    private fun cardBox(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        layoutParams = fill()
        setBackgroundColor(CARD)
        setPadding(dp(16), dp(14), dp(16), dp(16))
    }

    private fun toggle(text: String, on: Boolean, changed: (Boolean) -> Unit): View {
        val row = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = fill()
            setPadding(0, dp(4), 0, dp(4))
        }
        row.addView(label(text, 15f, Color.WHITE).apply {
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })
        // isChecked is set before the listener is attached, so redrawing from a
        // property change cannot echo back as a command.
        row.addView(Switch(this).apply {
            isChecked = on
            setOnCheckedChangeListener { _, checked -> if (checked != on) changed(checked) }
        })
        return row
    }

    private fun wideButton(text: String, tapped: () -> Unit): View =
        Button(this).apply {
            this.text = text
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setOnClickListener { tapped() }
        }

    private fun smallButton(text: String, tapped: () -> Unit): View =
        Button(this).apply {
            this.text = text
            minWidth = 0
            minimumWidth = 0
            setPadding(dp(14), 0, dp(14), 0)
            setOnClickListener { tapped() }
        }

    private fun pad(view: View): View = LinearLayout(this).apply {
        setPadding(dp(20), dp(8), dp(20), dp(8))
        addView(view)
    }

    private fun gap(height: Int): View =
        View(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, height
            )
        }

    private fun fill(): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
        )

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private companion object {
        val BACKGROUND = Color.parseColor("#121212")
        val CARD = Color.parseColor("#1E1E1E")
        val DIM = Color.parseColor("#B0B0B0")
        val WARN = Color.parseColor("#FFB74D")
        val ACCENT = Color.parseColor("#4FC3F7")
        const val SCAN_SECONDS = 30L
    }
}
