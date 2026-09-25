/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.patchbay

import org.json.JSONArray
import org.json.JSONObject

/**
 * The app's mirror of the host's PipeWire graph.
 *
 * Kept as the daemon's own projection rather than re-modelled into classes: the
 * daemon already reduced pw-dump to an allow-listed set of fields, and a second
 * translation here would be one more place for the two views to disagree.
 *
 * Two rules the graph itself imposes, and both have bitten other patchbays:
 *
 *  - Ids are ephemeral. They are integers PipeWire hands out and reuses, and a
 *    `systemctl --user restart pipewire` invalidates every one of them. They are
 *    fine to act on right now and useless to remember, which is why `reset()`
 *    exists and why nothing here is ever persisted by id.
 *  - Names are what endure. `nameKey` is node.name + ":" + port.name, which is
 *    the key a saved patch would have to use. Nothing saves patches yet; the key
 *    is here so that when something does, it is not tempted by the id.
 */
class Graph {

    private val objects = LinkedHashMap<Int, JSONObject>()

    var ready = false
        private set

    fun reset() {
        objects.clear()
        ready = false
    }

    /** Replace everything: the daemon's `ready` or `graph`, or a resync. */
    fun replace(array: JSONArray?) {
        objects.clear()
        if (array != null) {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val id = item.optInt("id", -1)
                if (id >= 0) objects[id] = item
            }
        }
        ready = true
    }

    /** Apply one `update` event. */
    fun update(changed: JSONArray?, removed: JSONArray?) {
        if (changed != null) {
            for (index in 0 until changed.length()) {
                val item = changed.optJSONObject(index) ?: continue
                val id = item.optInt("id", -1)
                if (id >= 0) objects[id] = item
            }
        }
        if (removed != null) {
            for (index in 0 until removed.length()) {
                objects.remove(removed.optInt(index, -1))
            }
        }
    }

    fun size(): Int = objects.size

    fun byId(id: Int): JSONObject? = objects[id]

    fun of(kind: String): List<JSONObject> =
        objects.values.filter { it.optString("kind") == kind }

    fun nodes(): List<JSONObject> = of("node")

    fun links(): List<JSONObject> = of("link")

    fun devices(): List<JSONObject> = of("device")

    fun clients(): List<JSONObject> = of("client")

    /**
     * The clients that say they are the container.
     *
     * A list rather than a single object because nothing guarantees there is
     * one of them: `pipewire-pulse` mints a client per connection, so a second
     * Android process opening audio gets its own, and both are the container.
     *
     * Display only, and that is not a hedge. Every `application.*` property is
     * whatever the client chose to send about itself -- docs/56 finding 4
     * measured the container's as `application.process.host=waydroid` while its
     * `pipewire.sec.*` properties were pipewire-pulse's own -- so a host
     * process could call itself Waydroid and this would agree. Nothing is
     * authorised on the answer; it decides which row gets the accent colour.
     */
    fun waydroidClients(): List<JSONObject> = clients().filter {
        text(it, "app_host").equals(WAYDROID_HOST, true) ||
            text(it, "app_name").equals(WAYDROID_NAME, true)
    }

    /**
     * The nodes a client currently owns.
     *
     * For the container this is its live streams, and the list is empty far
     * more often than not -- which is the whole reason the Clients section
     * exists. See MainActivity.clientCard.
     */
    fun nodesOfClient(clientId: Int): List<JSONObject> =
        nodes().filter { it.optInt("client", -1) == clientId }

    /** A human label for a client: what it calls itself, else its binary. */
    fun clientLabel(client: JSONObject): String =
        text(client, "app_name")
            ?: text(client, "app_binary")
            ?: "client ${client.optInt("id", -1)}"

    fun portsOf(nodeId: Int): List<JSONObject> =
        of("port").filter { it.optInt("node", -1) == nodeId }

    fun metadata(name: String): JSONObject? =
        of("metadata").firstOrNull { it.optString("name") == name }

    /** A `settings` value, or null. The daemon projects them as they arrive. */
    fun setting(key: String): String? {
        val entries = metadata("settings")?.optJSONObject("entries") ?: return null
        if (!entries.has(key)) return null
        return entries.opt(key)?.toString()
    }

    /** Which node this port belongs to, for labelling a link end. */
    fun nodeOfPort(portId: Int): JSONObject? {
        val port = byId(portId) ?: return null
        return byId(port.optInt("node", -1))
    }

    /**
     * The stable identity of a port: node name and port name.
     *
     * Deliberately not the alias. `port.alias` is prettier -- "ALC3227
     * Analog:playback_FL" -- but it is derived from the device description,
     * which changes when a profile changes; node.name does not.
     */
    fun nameKey(portId: Int): String? {
        val port = byId(portId) ?: return null
        val node = byId(port.optInt("node", -1)) ?: return null
        val nodeName = text(node, "name") ?: return null
        val portName = text(port, "name") ?: return null
        return "$nodeName:$portName"
    }

    /** A human label for a node: the description if it has one, else the name. */
    fun label(node: JSONObject): String =
        text(node, "description")
            ?: text(node, "nick")
            ?: text(node, "name")
            ?: "node ${node.optInt("id", -1)}"

    /**
     * Which section of the list a node belongs in.
     *
     * Grouped by what the user is looking for rather than by media.class alone:
     * "Streams" collects both directions of `Stream/` because on this host the
     * only stream that ever appears is Android's own, and it shows up as
     * whichever direction it is playing.
     */
    fun section(node: JSONObject): String {
        val cls = text(node, "media_class") ?: ""
        return when {
            cls == "Audio/Sink" -> SECTION_SINKS
            cls.startsWith("Audio/Source") -> SECTION_SOURCES
            cls.startsWith("Stream/") -> SECTION_STREAMS
            cls.startsWith("Midi/") -> SECTION_MIDI
            cls.startsWith("Video/") -> SECTION_VIDEO
            else -> SECTION_OTHER
        }
    }

    /**
     * Is this node worth a row?
     *
     * The graph has driver nodes (Dummy-Driver, Freewheel-Driver) with no ports,
     * no media.class and nothing to control. They are 2 of 7 nodes on this host,
     * so hiding them is not a rounding error.
     *
     * Through `text` and not optString: media.class arrives as JSON null on
     * exactly these nodes, and "null" is not an empty string, so the plain
     * check let both drivers through and captioned them "null · id 31".
     */
    fun interesting(node: JSONObject): Boolean {
        if (text(node, "media_class") != null) return true
        return portsOf(node.optInt("id", -1)).isNotEmpty()
    }

    companion object {
        /**
         * A projected string field, or null.
         *
         * The daemon's projections are fixed-shape allow-lists, so a property
         * an object does not carry arrives as JSON null rather than as an
         * absent key -- and org.json renders that through optString as the
         * four characters "null". Every read of a projected string goes
         * through here, or one of them eventually puts "null" on the screen.
         */
        fun text(obj: JSONObject, key: String): String? =
            obj.optString(key).takeIf { it.isNotEmpty() && it != "null" }

        // Measured on this host: the container's audio client reports
        // application.name=Waydroid and application.process.host=waydroid.
        // Either alone is enough, because which one is set depends on how the
        // HAL opened the connection and not on anything this app controls.
        private const val WAYDROID_HOST = "waydroid"
        private const val WAYDROID_NAME = "Waydroid"

        const val SECTION_SINKS = "Sinks"
        const val SECTION_SOURCES = "Sources"
        const val SECTION_STREAMS = "Streams"
        const val SECTION_MIDI = "MIDI"
        const val SECTION_VIDEO = "Video"
        const val SECTION_OTHER = "Other"

        val SECTIONS = listOf(
            SECTION_SINKS, SECTION_SOURCES, SECTION_STREAMS,
            SECTION_MIDI, SECTION_VIDEO, SECTION_OTHER
        )
    }
}
