/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.patchbay

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
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
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

/**
 * Patchbay: the host's PipeWire graph, from inside Android.
 *
 * WHY A LIST AND NOT A CANVAS, FIRST
 *
 * qpwgraph is the obvious model and it is the wrong one to start with. It
 * assumes a mouse with hover, right-click menus and a big screen; on a tablet
 * held at arm's length a 60-object graph of bezier curves is a demo, not a
 * tool. So the first screen is a list: sections by kind, a row per node, ports
 * underneath, links in their own section. A canvas view comes later and shares
 * this Graph.
 *
 * Connecting by two taps rather than by dragging is the same decision. A drag
 * between two port circles needs both to be on screen at a legible size at the
 * same time, which on this display means about eight ports. Tapping an output
 * port arms it, tapping an input port completes the link, and the arming
 * survives scrolling the length of the graph.
 *
 * WHY THE WHOLE TREE IS REBUILT ON EVERY EVENT
 *
 * Because the events are rare and small -- WirePlumber suspends idle nodes, so a
 * quiet host sends nothing at all -- and because a diffing renderer for a graph
 * whose ids churn is exactly the kind of cleverness that shows the wrong port as
 * armed after a PipeWire restart. Scroll position is preserved by hand, and
 * rendering is suppressed while a volume slider is under a finger, which are the
 * only two places the rebuild is noticeable.
 */
class MainActivity : Activity(), PwClient.Listener {

    private var client: PwClient? = null
    private var profile: Profile? = null
    private val graph = Graph()
    private var policy = JSONObject()
    private var daemonReady = false

    private var status = "starting"
    private var armedPort = -1
    private var hideMonitors = true
    private var suppressRender = false

    private val pending = HashMap<Int, String>()

    private lateinit var root: LinearLayout
    private lateinit var statusView: TextView
    private lateinit var bannerView: TextView
    private lateinit var scroller: ScrollView
    private lateinit var container: LinearLayout

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        window.setBackgroundDrawable(ColorDrawable(BACKGROUND))
        buildChrome()
        setContentView(root)
    }

    override fun onStart() {
        super.onStart()
        connect()
    }

    override fun onStop() {
        super.onStop()
        client?.stop()
        client = null
    }

    // ---- chrome ----------------------------------------------------------

    private fun buildChrome() {
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(BACKGROUND)
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(14), dp(8), dp(6))
        }
        header.addView(TextView(this).apply {
            text = "Patchbay"
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
        })
        header.addView(About.link(this))
        root.addView(header)

        statusView = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(16), 0, dp(16), dp(8))
        }
        root.addView(statusView)

        bannerView = TextView(this).apply {
            setTextColor(Color.BLACK)
            setBackgroundColor(ARMED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            visibility = View.GONE
            isClickable = true
            setOnClickListener { armedPort = -1; render() }
        }
        root.addView(bannerView)

        val tools = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), 0, dp(10), dp(4))
        }
        tools.addView(CheckBox(this).apply {
            text = "Hide monitor ports"
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            isChecked = hideMonitors
            setOnCheckedChangeListener { _, checked -> hideMonitors = checked; render() }
        })
        tools.addView(View(this), LinearLayout.LayoutParams(0, dp(1), 1f))
        tools.addView(flatButton("Graph") { showGraphDialog() })
        tools.addView(flatButton("Host") { showProfileDialog() })
        root.addView(tools)

        container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(10), 0, dp(10), dp(24))
        }
        scroller = ScrollView(this).apply {
            addView(container)
            layoutParams = LinearLayout.LayoutParams(match(), 0, 1f)
        }
        root.addView(scroller)
    }

    // ---- connection ------------------------------------------------------

    private fun connect() {
        val loaded = Profile.load(this)
        profile = loaded
        if (loaded == null) {
            status = "no connection profile yet"
            render()
            // Not an error dialog: on a fresh install the publisher drops the
            // profile within its interval, so the common case resolves itself
            // without anybody being asked anything.
            return
        }
        status = "connecting to ${loaded.describe()}"
        render()
        client = PwClient(loaded, this).also { it.start() }
    }

    override fun onConnected() {
        status = "connected; waiting for the graph"
        render()
    }

    override fun onDisconnected(reason: String) {
        daemonReady = false
        status = "disconnected: $reason"
        render()
    }

    override fun onReply(id: Int, reply: JSONObject) {
        val what = pending.remove(id)
        if (!reply.optBoolean("ok", false)) {
            val error = reply.optString("error", "refused")
            toast(if (what != null) "$what: $error" else error)
            return
        }
        // Successful verbs are normally silent, because the monitor's update
        // event is the confirmation. A config write produces no graph change
        // at all, so it is the one verb whose success nothing would otherwise
        // show.
        if (what == "save") {
            val file = reply.optString("file", "").substringAfterLast('/')
            val skipped = reply.optJSONArray("skipped")?.length() ?: 0
            toast(
                "saved ${reply.optInt("values")} values to $file" +
                    if (skipped > 0) " ($skipped filter(s) had no control block)" else ""
            )
        }
    }

    override fun onEvent(event: JSONObject) {
        when (event.optString("ev")) {
            "ready" -> {
                policy = event.optJSONObject("policy") ?: JSONObject()
                daemonReady = event.optBoolean("ready", false)
                graph.replace(event.optJSONArray("objects"))
                status = describeConnection()
                armedPort = -1
                render()
            }
            "graph" -> {
                daemonReady = event.optBoolean("ready", true)
                graph.replace(event.optJSONArray("objects"))
                status = describeConnection()
                render()
            }
            "reset" -> {
                // PipeWire restarted. Every id is stale, including whatever was
                // armed, so the arming goes with it rather than completing a
                // link against a port that is now something else.
                graph.reset()
                armedPort = -1
                status = "PipeWire restarted; resyncing"
                render()
            }
            "update" -> {
                graph.update(event.optJSONArray("changed"), event.optJSONArray("removed"))
                if (armedPort >= 0 && graph.byId(armedPort) == null) armedPort = -1
                status = describeConnection()
                render()
            }
            "error" -> {
                status = event.optString("error", "error")
                render()
            }
            "node-spawned" -> toast("added ${event.optString("label")}")
            "node-gone" -> toast("removed ${event.optString("handle")}")
        }
    }

    private fun describeConnection(): String {
        val where = profile?.describe() ?: "?"
        if (!daemonReady) return "$where · graph not up on the host"
        return "$where · ${graph.size()} objects · ${describeAndroid()}"
    }

    /**
     * Android's own place in the graph, in one phrase, always on screen.
     *
     * In the status line and not only in the Clients section because the
     * honest answer has three states and two of them are indistinguishable if
     * you watch nodes: the container's client connection outlives every stream
     * it makes, so "connected and idle" and "not connected at all" both show
     * as no Waydroid node. Scrolling to find out which is a bad trade for the
     * question people ask first.
     */
    private fun describeAndroid(): String {
        val mine = graph.waydroidClients()
        if (mine.isEmpty()) return "Android not connected"
        val streams = mine.sumOf { graph.nodesOfClient(it.optInt("id", -1)).size }
        return when (streams) {
            0 -> "Android connected, idle"
            1 -> "Android streaming"
            else -> "Android streaming ×$streams"
        }
    }

    // ---- sending ---------------------------------------------------------

    private fun send(what: String, command: String, build: (JSONObject) -> Unit = {}) {
        val active = client
        if (active == null || !active.connected) {
            toast("not connected")
            return
        }
        pending[active.send(command, build)] = what
    }

    private fun allowed(capability: String): Boolean = policy.optBoolean(capability, false)

    // ---- rendering -------------------------------------------------------

    private fun render() {
        if (suppressRender) return
        statusView.text = status
        if (armedPort >= 0) {
            val key = graph.nameKey(armedPort) ?: "port $armedPort"
            bannerView.text = "Connecting from $key — tap an input port, or tap here to cancel"
            bannerView.visibility = View.VISIBLE
        } else {
            bannerView.visibility = View.GONE
        }

        val scrollY = scroller.scrollY
        container.removeAllViews()

        if (profile == null) {
            container.addView(note(
                "Waiting for waydroid-pwd to publish a connection profile.\n\n" +
                    "The host daemon offers it every 30 seconds, so this " +
                    "normally clears by itself. \"Host\" sets one by hand."
            ))
        } else if (!graph.ready) {
            container.addView(note("No graph yet."))
        } else {
            renderGraph()
        }
        container.addView(footer())
        scroller.post { scroller.scrollTo(0, scrollY) }
    }

    private fun renderGraph() {
        val nodes = graph.nodes().filter { graph.interesting(it) }
        for (section in Graph.SECTIONS) {
            val inSection = nodes.filter { graph.section(it) == section }
            if (inSection.isEmpty()) continue
            container.addView(heading(section))
            for (node in inSection.sortedBy { graph.label(it).lowercase() }) {
                container.addView(nodeCard(node))
            }
        }

        val clients = graph.clients()
        if (clients.isNotEmpty()) {
            val containerIds = graph.waydroidClients()
                .map { it.optInt("id", -1) }.toSet()
            container.addView(heading("Clients (${clients.size})"))
            if (containerIds.isNotEmpty()) {
                container.addView(note(
                    "The highlighted client is the one saying it is the " +
                        "container. application.* properties are self-reported, " +
                        "so they label a row and authorise nothing."
                ))
            }
            val ordered = clients.sortedWith(
                compareByDescending<JSONObject> { it.optInt("id", -1) in containerIds }
                    .thenBy { graph.clientLabel(it).lowercase() }
            )
            for (client in ordered) {
                container.addView(clientCard(client, client.optInt("id", -1) in containerIds))
            }
        }

        val links = graph.links()
        container.addView(heading("Links (${links.size})"))
        if (links.isEmpty()) {
            container.addView(note(
                "No links. WirePlumber suspends idle nodes, so an idle host " +
                    "really does have none."
            ))
        } else {
            for (link in links.sortedBy { it.optInt("id") }) {
                container.addView(linkRow(link))
            }
        }

        val devices = graph.devices().filter { it.optJSONArray("profiles") != null }
        if (devices.isNotEmpty()) {
            container.addView(heading("Devices"))
            for (device in devices) container.addView(deviceRow(device))
        }
    }

    private fun nodeCard(node: JSONObject): View {
        val id = node.optInt("id", -1)
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(CARD)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            layoutParams = LinearLayout.LayoutParams(match(), wrap()).apply {
                bottomMargin = dp(6)
            }
        }

        card.addView(TextView(this).apply {
            text = graph.label(node)
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        })

        val detail = buildString {
            append(Graph.text(node, "media_class") ?: "no media.class")
            append("  ·  id $id")
            Graph.text(node, "state")?.let { append("  ·  ").append(it) }
            Graph.text(node, "app_host")?.let { append("  ·  from ").append(it) }
        }
        card.addView(TextView(this).apply {
            text = detail
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        })

        if (node.has("volume")) card.addView(volumeRow(node, id))

        val controls = Controls.of(node)
        if (controls.isNotEmpty()) card.addView(effectsRow(node, id, controls))

        val ports = graph.portsOf(id)
            .filter { !hideMonitors || !it.optBoolean("monitor", false) }
        for (port in ports.sortedWith(compareBy({ it.optString("direction") },
                                                { it.optString("name") }))) {
            card.addView(portRow(port))
        }
        return card
    }

    private fun volumeRow(node: JSONObject, id: Int): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val muted = node.optBoolean("mute", false)
        // The daemon reports the cubic value, which is what wpctl prints and
        // accepts; the linear channelVolumes are also on the wire for anyone
        // who wants them, but a slider wants the one the host's own tools use.
        val volume = node.optDouble("volume", 0.0)
        val bar = SeekBar(this).apply {
            max = 150
            progress = (volume * 100).toInt().coerceIn(0, 150)
            isEnabled = allowed("mixer")
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {}
                override fun onStartTrackingTouch(bar: SeekBar) {
                    // A rebuild mid-drag would replace the SeekBar under the
                    // finger, and the gesture would be delivered to a view that
                    // is no longer in the tree.
                    suppressRender = true
                }
                override fun onStopTrackingTouch(bar: SeekBar) {
                    suppressRender = false
                    send("set volume", "node-volume") {
                        it.put("node", id)
                        it.put("volume", bar.progress / 100.0)
                    }
                }
            })
        }
        row.addView(bar)
        row.addView(flatButton(if (muted) "Unmute" else "Mute") {
            send("mute", "node-mute") { it.put("node", id); it.put("mute", "toggle") }
        }.apply { isEnabled = allowed("mixer") })
        row.addView(flatButton("Default") {
            send("set default", "default-set") { it.put("node", id) }
        }.apply { isEnabled = allowed("mixer") })
        return row
    }

    /**
     * The way in to a node's filter controls.
     *
     * A row of its own rather than a button on the volume row, because a
     * filter chain does not have to be a sink: a node created by
     * `pipewire -c` with no audioconvert in front of it publishes controls and
     * no volume at all, and hanging the entry point off the mixer would hide
     * the controls on exactly those nodes.
     */
    private fun effectsRow(node: JSONObject, id: Int, controls: List<Controls.Control>): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(4), 0, 0)
        }
        val adjustable = controls.count { !it.readonly }
        val filters = controls.map { it.filter }.distinct().size
        row.addView(TextView(this).apply {
            text = "$filters " + (if (filters == 1) "filter" else "filters") +
                "  ·  $adjustable adjustable"
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
        })
        // Always enabled, like Graph: with the capability off the dialog still
        // opens and says so, which is more use than a dead button.
        row.addView(flatButton("Effects") { showEffects(node, id) })
        return row
    }

    private fun portRow(port: JSONObject): View {
        val id = port.optInt("id", -1)
        val direction = port.optString("direction")
        val isOutput = direction == "out"
        val armed = id == armedPort
        val label = buildString {
            append(if (isOutput) "◀ " else "▶ ")
            append(Graph.text(port, "name") ?: "port $id")
            if (port.optBoolean("monitor", false)) append("  (monitor)")
        }
        return TextView(this).apply {
            text = label
            setTextColor(if (armed) Color.BLACK else if (isOutput) OUTPUT else INPUT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(8), dp(9), dp(8), dp(9))
            if (armed) setBackgroundColor(ARMED)
            isClickable = true
            setOnClickListener { onPortTapped(id, isOutput) }
        }
    }

    private fun onPortTapped(id: Int, isOutput: Boolean) {
        if (!allowed("links")) {
            toast("link editing is disabled in the daemon's policy")
            return
        }
        if (armedPort < 0) {
            if (!isOutput) {
                toast("start from an output port")
                return
            }
            armedPort = id
            render()
            return
        }
        if (id == armedPort) {
            armedPort = -1
            render()
            return
        }
        if (isOutput) {
            // Re-arming rather than refusing: two output taps in a row is much
            // more likely to be a change of mind than a mistake.
            armedPort = id
            render()
            return
        }
        val source = armedPort
        armedPort = -1
        send("connect", "link-create") { it.put("output", source); it.put("input", id) }
        render()
    }

    private fun linkRow(link: JSONObject): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(CARD)
            setPadding(dp(12), dp(8), dp(6), dp(8))
            layoutParams = LinearLayout.LayoutParams(match(), wrap()).apply {
                bottomMargin = dp(4)
            }
        }
        val from = graph.nameKey(link.optInt("output_port", -1)) ?: "?"
        val to = graph.nameKey(link.optInt("input_port", -1)) ?: "?"
        row.addView(TextView(this).apply {
            text = "$from\n    → $to"
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
        })
        row.addView(TextView(this).apply {
            text = Graph.text(link, "state") ?: "?"
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setPadding(dp(6), 0, dp(6), 0)
        })
        row.addView(flatButton("✕") {
            send("disconnect", "link-destroy") { it.put("link", link.optInt("id", -1)) }
        }.apply { isEnabled = allowed("links") })
        return row
    }

    /**
     * One connected client, playing or not.
     *
     * This section exists because of docs/56 finding 4, and the finding is not
     * a detail: Android's stream *node* is present only while audio is
     * actually flowing -- WirePlumber tears it down when playback stops -- but
     * the HAL's *client* connection persists for the life of the container. A
     * patchbay that lists only nodes therefore says nothing at all about
     * Android on a quiet host, and "no Waydroid node" reads as "not connected"
     * when the truth is "connected and silent". Those are opposite answers to
     * the first question anybody opens this app to ask.
     *
     * Each client's nodes are listed underneath it so the transience is
     * visible rather than inferred: watch the line appear when something plays.
     */
    private fun clientCard(client: JSONObject, isContainer: Boolean): View {
        val id = client.optInt("id", -1)
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(CARD)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            layoutParams = LinearLayout.LayoutParams(match(), wrap()).apply {
                bottomMargin = dp(4)
            }
        }
        card.addView(TextView(this).apply {
            text = graph.clientLabel(client)
            setTextColor(if (isContainer) ACCENT else FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        })
        card.addView(TextView(this).apply {
            text = buildString {
                append("id ").append(id)
                Graph.text(client, "api")?.let { append("  ·  ").append(it) }
                val host = Graph.text(client, "app_host")
                val user = Graph.text(client, "app_user")
                if (host != null || user != null) {
                    append("  ·  ").append(host ?: "?").append("/").append(user ?: "?")
                }
                Graph.text(client, "access")?.let { append("  ·  ").append(it) }
            }
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        })

        // Not filtered to Stream/* nodes: WirePlumber owns the device nodes,
        // and showing that is how "which client put alsa_output here" gets
        // answered at all. Capped because a busy desktop host would otherwise
        // give WirePlumber a card longer than the rest of the screen.
        val owned = graph.nodesOfClient(id).sortedBy { it.optInt("id", -1) }
        if (owned.isEmpty()) {
            card.addView(nodeLine("no nodes right now", MUTED))
        } else {
            for (node in owned.take(NODES_PER_CLIENT)) {
                card.addView(nodeLine(
                    "▸ " + graph.label(node) +
                        "  ·  " + (Graph.text(node, "media_class") ?: "no media.class") +
                        "  ·  id " + node.optInt("id", -1),
                    FOREGROUND
                ))
            }
            val hidden = owned.size - NODES_PER_CLIENT
            if (hidden > 0) card.addView(nodeLine("+ $hidden more", MUTED))
        }
        return card
    }

    private fun nodeLine(text: String, colour: Int): View = TextView(this).apply {
        this.text = text
        setTextColor(colour)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        setPadding(0, dp(4), 0, 0)
    }

    private fun deviceRow(device: JSONObject): View {
        val id = device.optInt("id", -1)
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(CARD)
            setPadding(dp(12), dp(8), dp(6), dp(8))
            layoutParams = LinearLayout.LayoutParams(match(), wrap()).apply {
                bottomMargin = dp(4)
            }
        }
        val current = device.optJSONObject("profile")
            ?.let { Graph.text(it, "description") ?: Graph.text(it, "name") } ?: "?"
        row.addView(TextView(this).apply {
            text = (Graph.text(device, "description")
                ?: Graph.text(device, "name") ?: "device $id") + "\n    $current"
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
        })
        row.addView(flatButton("Profile") { showProfilePicker(device, id) }
            .apply { isEnabled = allowed("mixer") })
        return row
    }

    // ---- dialogs ---------------------------------------------------------

    private fun showProfilePicker(device: JSONObject, id: Int) {
        val profiles = device.optJSONArray("profiles") ?: return
        val labels = ArrayList<CharSequence>()
        val indices = ArrayList<Int>()
        for (i in 0 until profiles.length()) {
            val entry = profiles.optJSONObject(i) ?: continue
            val suffix = if (Graph.text(entry, "available") == "no") "  (unavailable)" else ""
            labels.add((Graph.text(entry, "description")
                ?: Graph.text(entry, "name") ?: "profile ${entry.optInt("index", -1)}") + suffix)
            indices.add(entry.optInt("index", -1))
        }
        AlertDialog.Builder(this)
            .setTitle("Profile")
            .setItems(labels.toTypedArray()) { _, which ->
                send("set profile", "device-profile") {
                    it.put("device", id); it.put("index", indices[which])
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * One filter chain's controls, one slider each.
     *
     * The coefficient ports are dropped rather than shown read-only. They are
     * two thirds of what a biquad publishes -- 36 of the 54 keys on the host's
     * six-band EQ -- and they are outputs: a biquad computes b0..a2 from the
     * Freq, Q and Gain above them, so a screen that lists them is mostly a
     * view of its own arithmetic.
     *
     * No left/right pairing, because there is none to make. A filter graph
     * declared without explicit `inputs`/`outputs` is duplicated across both
     * channels by filter-chain and the two copies share one set of control
     * ports, so one slider here moves both. docs/56 measured that.
     *
     * Nothing suppresses rendering while a slider is dragged, which the volume
     * slider has to do: these views live in a dialog rather than in the list
     * that render() rebuilds, so the finger is never over a view that is about
     * to be replaced.
     */
    private fun showEffects(node: JSONObject, nodeId: Int) {
        val controls = Controls.of(node)
        val adjustable = controls.filter { !it.readonly }
        if (adjustable.isEmpty()) {
            AlertDialog.Builder(this)
                .setTitle(graph.label(node))
                .setMessage(
                    "This node publishes ${controls.size} filter values and none " +
                        "of them are adjustable: they are coefficients the filters " +
                        "compute for themselves."
                )
                .setPositiveButton("Close", null)
                .show()
            return
        }

        val editable = allowed("params")
        val resets = ArrayList<() -> Unit>()
        val opened = LinkedHashMap<String, Double>()

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(4), dp(18), dp(8))
        }

        val filters = adjustable.map { it.filter }.distinct().size
        layout.addView(note(buildString {
            append(filters).append(if (filters == 1) " filter" else " filters")
            append("  ·  ").append(adjustable.size).append(" adjustable")
            val computed = controls.size - adjustable.size
            if (computed > 0) append("  ·  ").append(computed).append(" computed, hidden")
        }))

        if (!editable) {
            layout.addView(note(
                "The params capability is disabled in the daemon's policy, so " +
                    "these are read-only here."
            ))
        } else if (Graph.text(node, "state") != "running") {
            // docs/56: a chain that has never been instantiated reports its
            // CONFIGURED values whatever is written to it. The write is not
            // lost, and nothing in the graph distinguishes that state from an
            // ordinary idle one, so this is worded as the possibility it is.
            layout.addView(note(
                "Not running. A move still applies, but a chain that has never " +
                    "passed audio keeps reporting its configured values, so the " +
                    "host may not confirm the new number until something plays."
            ))
        }

        for ((filter, group) in adjustable.groupBy { it.filter }) {
            layout.addView(heading(filter))
            for (control in group) {
                opened[control.key] = control.value
                layout.addView(controlRow(nodeId, control, editable, resets))
            }
        }

        // A row rather than a dialog button. The three button slots are taken
        // by Close and Revert, and the one left is the "negative" slot, which
        // sitting next to those two reads as Cancel.
        layout.addView(heading("Startup values"))
        if (!allowed("config")) {
            layout.addView(note(
                "These values live only in the running graph, and the config " +
                    "capability is disabled in the daemon's policy, so they " +
                    "last only until the chain stops."
            ))
        } else {
            layout.addView(note(
                "These values live only in the running graph \u2014 nothing " +
                    "else persists a filter control, so the chain stopping " +
                    "loses them. Saving writes them into the drop-in that " +
                    "declares this chain."
            ))
            layout.addView(flatButton("Save as startup values") {
                confirmSave(nodeId, graph.label(node))
            })
        }

        val dialog = AlertDialog.Builder(this)
            .setTitle(graph.label(node))
            .setView(ScrollView(this).apply { addView(layout) })
            .setPositiveButton("Close", null)
            .setNeutralButton("Revert", null)
            .create()
        dialog.show()
        // Wired after show() so that reverting does not also dismiss: undoing
        // one bad move is the point, and being thrown out of the screen to do
        // it would mean scrolling back to where you were every time.
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.apply {
            isEnabled = editable
            setOnClickListener {
                send("revert controls", "node-param") {
                    it.put("node", nodeId)
                    val payload = JSONObject()
                    for ((key, value) in opened) payload.put(key, value)
                    it.put("params", payload)
                }
                for (reset in resets) reset()
            }
        }
    }

    /**
     * The second tap before writing a file.
     *
     * Same reasoning as confirmQuantum: this is the one control in the app
     * that outlives the process on both sides. It is well short of dangerous
     * -- the daemon keeps a .bak, preserves the file's comments and refuses an
     * edit that would not parse -- but "the config the audio server reads at
     * every start" deserves being named out loud before it changes.
     */
    private fun confirmSave(nodeId: Int, label: String) {
        AlertDialog.Builder(this)
            .setTitle("Save $label?")
            .setMessage(
                "Writes the current control values into the conf.d drop-in " +
                    "that declares this chain, so it starts this way. The " +
                    "previous contents are kept beside it as .bak, the file's " +
                    "comments survive, and the write is refused if the result " +
                    "would not parse.\n\n" +
                    "Nothing restarts and nothing stops playing: the chain is " +
                    "already in this state, so the file only matters the next " +
                    "time it starts."
            )
            .setPositiveButton("Save") { _, _ ->
                send("save", "chain-save") { it.put("node", nodeId) }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun controlRow(
        nodeId: Int,
        control: Controls.Control,
        editable: Boolean,
        resets: MutableList<() -> Unit>
    ): View {
        val spec = ControlSpec.of(control.port, control.value)
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(6), 0, dp(2))
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(TextView(this).apply {
            text = control.port
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            layoutParams = LinearLayout.LayoutParams(0, wrap(), 1f)
        })
        val readout = TextView(this).apply {
            text = spec?.format(control.value) ?: plain(control.value)
            setTextColor(ACCENT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(8), 0, dp(8), 0)
        }
        header.addView(readout)
        row.addView(header)

        if (spec == null) {
            // No calibrated range for this port name; Controls.kt says why a
            // guessed one would be worse than typing the number.
            header.addView(flatButton("Set…") {
                showControlEntry(nodeId, control, readout)
            }.apply { isEnabled = editable })
            resets.add { readout.text = plain(control.value) }
            return row
        }

        val bar = SeekBar(this).apply {
            max = ControlSpec.STEPS
            progress = spec.toProgress(control.value)
            isEnabled = editable
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(bar: SeekBar, value: Int, fromUser: Boolean) {
                    readout.text = spec.format(spec.fromProgress(value))
                }

                override fun onStartTrackingTouch(bar: SeekBar) {}

                // On release and not on every pixel: a set-param per progress
                // step is a pw-cli spawn per progress step on the host.
                override fun onStopTrackingTouch(bar: SeekBar) {
                    send("set ${control.port}", "node-param") {
                        it.put("node", nodeId)
                        it.put(
                            "params",
                            JSONObject().put(control.key, spec.fromProgress(bar.progress))
                        )
                    }
                }
            })
        }
        row.addView(bar)
        resets.add {
            bar.progress = spec.toProgress(control.value)
            readout.text = spec.format(control.value)
        }
        return row
    }

    private fun showControlEntry(nodeId: Int, control: Controls.Control, readout: TextView) {
        val field = EditText(this).apply {
            setText(plain(control.value))
            inputType = InputType.TYPE_CLASS_NUMBER or
                InputType.TYPE_NUMBER_FLAG_DECIMAL or
                InputType.TYPE_NUMBER_FLAG_SIGNED
        }
        AlertDialog.Builder(this)
            .setTitle(control.key)
            .setView(LinearLayout(this).apply {
                setPadding(dp(20), dp(12), dp(20), 0)
                addView(field)
            })
            .setPositiveButton("Set") { _, _ ->
                val value = field.text.toString().trim().toDoubleOrNull()
                if (value == null) {
                    toast("not a number")
                } else {
                    readout.text = plain(value)
                    send("set ${control.port}", "node-param") {
                        it.put("node", nodeId)
                        it.put("params", JSONObject().put(control.key, value))
                    }
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun plain(value: Double): String = "%.4f".format(value)

    /**
     * The graph-wide controls: quantum, and what the host currently runs.
     *
     * docs/44 measured this host at clock.quantum 1024 with min-quantum 32 and
     * called the 1024 "a default nobody has had a reason to lower". This is that
     * reason -- it is the one control here that moves the latency floor rather
     * than routing around it -- which is also why it is behind its own
     * capability and not on the main screen.
     */
    private fun showGraphDialog() {
        val quantum = graph.setting("clock.quantum") ?: "?"
        val forced = graph.setting("clock.force-quantum") ?: "0"
        val min = graph.setting("clock.min-quantum")?.toIntOrNull() ?: 32
        val max = graph.setting("clock.max-quantum")?.toIntOrNull() ?: 8192
        val rate = graph.setting("clock.rate") ?: "?"

        val hz = rate.toIntOrNull() ?: 48000
        val running = quantum.toIntOrNull() ?: 1024

        val choices = ArrayList<Int>()
        choices.add(0)
        for (value in intArrayOf(32, 64, 128, 256, 512, 1024, 2048)) {
            if (value in min..max) choices.add(value)
        }
        // min-quantum says what PipeWire will ACCEPT, not what this host survives.
        // Forcing 32 -- 0.7 ms, the first non-zero choice here, and legal because
        // this host advertises min-quantum 32 -- made Android's audio scratchy and
        // then robotic on bigtab01, and left it that way for two days: a forced
        // quantum lives in PipeWire's own settings metadata, so it outlives both
        // this app and the daemon and only a reboot or an unforce clears it.
        // docs/56 records the measurement. So a value below the quantum the graph
        // is configured for is labelled as such and takes a second tap, rather
        // than being one tap away from the top of the list.
        val labels = choices.map {
            val ms = "%.1f".format(it * 1000.0 / hz)
            when {
                it == 0 -> "Unforce (follow the graph)"
                it < running -> "$it frames  ·  $ms ms  ·  below $running"
                else -> "$it frames  ·  $ms ms"
            }
        }

        if (!allowed("graph")) {
            AlertDialog.Builder(this)
                .setTitle("Graph")
                .setMessage("quantum $quantum · forced $forced · rate $rate\n\n" +
                    "The graph capability is disabled in the daemon's policy, " +
                    "so these are read-only here.")
                .setPositiveButton("Close", null)
                .show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Quantum (now $quantum, forced $forced, rate $rate)")
            .setItems(labels.toTypedArray()) { _, which ->
                val chosen = choices[which]
                if (chosen != 0 && chosen < running) confirmQuantum(chosen, running, hz)
                else send("set quantum", "quantum") { it.put("value", chosen) }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /**
     * The second tap for a quantum below the one the graph is configured for.
     *
     * Deliberately a confirmation and not a hard floor. Lowering the latency
     * floor is what this control is FOR, and the only floor this app could
     * defend would be a number nobody has measured -- 32 is known bad and 1024
     * is known good, and nothing in between has been tried. A real floor belongs
     * in the daemon's policy file, which today parses yes/no only; see docs/56.
     */
    private fun confirmQuantum(frames: Int, running: Int, hz: Int) {
        AlertDialog.Builder(this)
            .setTitle("Force $frames frames?")
            .setMessage(
                "${"%.1f".format(frames * 1000.0 / hz)} ms, below the $running " +
                "this graph is configured for. A forced quantum applies to every " +
                "client on the host, including Android's audio, which reaches " +
                "PipeWire through an 85 ms HAL buffer.\n\n" +
                "32 frames was measured on this host to make Android's audio " +
                "unusable. It will not clear when this app closes or the daemon " +
                "restarts -- only unforcing it here, or a reboot.")
            .setPositiveButton("Force it") { _, _ ->
                send("set quantum", "quantum") { it.put("value", frames) }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun showProfileDialog() {
        val current = profile
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(12), dp(20), 0)
        }
        val host = EditText(this).apply {
            hint = "host"
            setText(current?.host ?: "192.168.240.1")
            inputType = InputType.TYPE_CLASS_TEXT
        }
        val port = EditText(this).apply {
            hint = "port"
            setText((current?.port ?: Profile.DEFAULT_PORT).toString())
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        val token = EditText(this).apply {
            hint = "token"
            setText(current?.token ?: "")
            inputType = InputType.TYPE_CLASS_TEXT
        }
        layout.addView(host); layout.addView(port); layout.addView(token)

        AlertDialog.Builder(this)
            .setTitle("Host daemon")
            .setView(layout)
            .setPositiveButton("Save") { _, _ ->
                Profile.saveManual(this, Profile(
                    host.text.toString().trim(),
                    port.text.toString().trim().toIntOrNull() ?: Profile.DEFAULT_PORT,
                    token.text.toString().trim(),
                    false, null, "entered by hand"
                ))
                restartConnection()
            }
            .setNeutralButton("Use published") { _, _ ->
                Profile.saveManual(this, null)
                restartConnection()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun restartConnection() {
        client?.stop()
        client = null
        graph.reset()
        armedPort = -1
        connect()
    }

    // ---- small view helpers ---------------------------------------------

    /**
     * What the daemon will and will not do, spelled out rather than implied by
     * greyed-out buttons: a refused verb is a deliberate host-side choice, and
     * the only place to change it is the host's policy.conf.
     */
    private fun footer(): View = TextView(this).apply {
        text = buildString {
            append("policy: ")
            val names = policy.keys().asSequence().sorted().toList()
            if (names.isEmpty()) {
                append("unknown")
            } else {
                append(names.joinToString("  ") {
                    (if (policy.optBoolean(it)) "+" else "−") + it
                })
            }
        }
        setTextColor(MUTED)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
        setPadding(dp(8), dp(16), dp(8), dp(8))
    }

    private fun heading(text: String): View = TextView(this).apply {
        this.text = text.uppercase()
        setTextColor(ACCENT)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
        setPadding(dp(4), dp(16), dp(4), dp(6))
    }

    private fun note(text: String): View = TextView(this).apply {
        this.text = text
        setTextColor(MUTED)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(dp(8), dp(8), dp(8), dp(8))
    }

    private fun flatButton(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            setTextColor(FOREGROUND)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            minWidth = dp(64)
            setBackgroundColor(BUTTON)
            setOnClickListener { onClick() }
        }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun wrap(): Int = ViewGroup.LayoutParams.WRAP_CONTENT

    private fun match(): Int = ViewGroup.LayoutParams.MATCH_PARENT

    private companion object {
        const val NODES_PER_CLIENT = 6

        const val BACKGROUND = 0xFF101418.toInt()
        const val CARD = 0xFF1B2128.toInt()
        const val BUTTON = 0xFF2A323B.toInt()
        const val FOREGROUND = 0xFFECEFF1.toInt()
        const val MUTED = 0xFF8A99A8.toInt()
        const val ACCENT = 0xFF4FC3F7.toInt()
        const val OUTPUT = 0xFFFFB74D.toInt()
        const val INPUT = 0xFF81C784.toInt()
        const val ARMED = 0xFFFFD54F.toInt()
    }
}
