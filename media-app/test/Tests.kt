/*
 * Unit tests for media-app: the parts of turning waydroid-mediad's broadcasts
 * into notifications, and an Eject tap into a marker file, that need no
 * Context. Run by tests/run.sh; see tests/kotlin/Harness.kt for how and with
 * what limits.
 *
 * Inputs are shaped the way artifacts/media/waydroid-mediad produces them:
 * labels are what its safe_name() and target_for() can return, and the path
 * extra is its literal "/sdcard/Removable/" + basename(target). The expected
 * values are derived from that source and from ExternalStorageProvider's
 * documented document-id format, never from running the code under test.
 *
 * What is NOT reachable here, and why: openIntent() builds its Uri with
 * DocumentsContract.buildDocumentUri and the receivers read Intent extras, and
 * every one of those is an android.jar stub that throws. The logic they wrap
 * was lifted into documentId(), detail() and isSafeMarkerName() so it can be.
 */
package com.systemhalted.removablemedia

import testharness.suite
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/* waydroid-mediad's make_notifier(): action = "waydroid.ext.media.VOLUME_%s",
 * formatted with event.upper(), and Mounter only ever passes "mounted" and
 * "unmounted". Copied from the daemon, not from Volumes.kt. */
private const val DAEMON_ACTION_FMT = "waydroid.ext.media.VOLUME_%s"

/* The path extra the daemon sends: "/sdcard/Removable/" + basename(target). */
private fun daemonPath(label: String) = "/sdcard/Removable/$label"

/* Labels the daemon can actually send. Each is hand-derived from safe_name()
 * and target_for():
 *   a volume label passes through re.sub(r"[^A-Za-z0-9._+-]", "_").strip("._")
 *     "NO NAME"      -> "NO_NAME"
 *     "my stick+1"   -> "my_stick+1"
 *     "..backup."    -> "backup"
 *   no label: "<kind>_<first six alnum of the UUID>", or just "<kind>"
 *     tran=mmc, uuid "4CFC-8D0E" -> "SD_Card_4CFC8D"
 *     tran=usb, no uuid          -> "USB_Drive"
 *   a name already taken gets "_2", "_3", ... from target_for()
 *     -> "USB_Drive_2"
 */
private val DAEMON_LABELS = listOf(
    "NO_NAME", "my_stick+1", "backup", "SD_Card_4CFC8D", "USB_Drive", "USB_Drive_2",
    "Disc", "Volume", "a.b-c",
)

fun main() = suite("media-app") {

    // ---- the broadcast contract ------------------------------------------

    test("action names match what waydroid-mediad broadcasts") {
        // A mismatch here is silent on the device: `am broadcast` reports
        // result=0 and nothing fires (Volumes.kt's comment on the constants).
        assertEquals(DAEMON_ACTION_FMT.format("mounted".uppercase()), Volumes.ACTION_MOUNTED)
        assertEquals(DAEMON_ACTION_FMT.format("unmounted".uppercase()), Volumes.ACTION_UNMOUNTED)
    }

    // ---- the document a notification tap opens ----------------------------

    test("document id names the daemon's mount, relative to the primary root") {
        // ExternalStorageProvider's ids are "<rootId>:<path relative to the
        // root>", and the primary root is /storage/emulated/0, which /sdcard
        // is. So the id is the daemon's own path extra with "/sdcard/"
        // replaced by "primary:" -- derived from the daemon, not from SUBDIR.
        for (label in DAEMON_LABELS) {
            val expected = "primary:" + daemonPath(label).removePrefix("/sdcard/")
            assertEquals(expected, Volumes.documentId(label), label)
        }
        assertEquals("primary:Removable/SD_Card_4CFC8D", Volumes.documentId("SD_Card_4CFC8D"))
    }

    test("document id is passed through unescaped") {
        // buildDocumentUri does the URI encoding; the id itself must be the
        // raw relative path, or ExternalStorageProvider resolves "%2B" as a
        // literal file name. '+' is the one character safe_name() keeps that
        // URI encoders treat specially.
        assertEquals("primary:Removable/my_stick+1", Volumes.documentId("my_stick+1"))
    }

    // ---- notification text -----------------------------------------------

    test("detail shows the path and, when known, the filesystem") {
        assertEquals("/sdcard/Removable/SD_Card_4CFC8D  (vfat)",
            Volumes.detail(daemonPath("SD_Card_4CFC8D"), "vfat"))
    }

    test("detail omits empty parentheses when the daemon sent no fstype") {
        // The daemon sends `--es fstype ""` when lsblk had no FSTYPE, and
        // VolumeReceiver turns an absent extra into "" as well.
        assertEquals("/sdcard/Removable/USB_Drive", Volumes.detail(daemonPath("USB_Drive"), ""))
    }

    // ---- notification identity -------------------------------------------

    test("notification id is stable per label and never zero") {
        for (label in DAEMON_LABELS) {
            assertEquals(Volumes.notificationId(label), Volumes.notificationId(label))
            assertNotEquals(0, Volumes.notificationId(label), label)
        }
        // "".hashCode() is 0; the `or 1` is what keeps even that off zero.
        assertEquals(1, Volumes.notificationId(""))
    }

    test("a volume and its first duplicate get separate notifications") {
        // target_for()'s first collision: two unlabelled sticks.
        assertNotEquals(Volumes.notificationId("USB_Drive"), Volumes.notificationId("USB_Drive_2"))
        assertNotEquals(Volumes.notificationId("SD_Card"), Volumes.notificationId("SD_Card_2"))
    }

    // ---- the eject marker ------------------------------------------------

    test("every label the daemon can send is a usable marker name") {
        // The daemon's watch_ejects() calls eject(name) with the marker's
        // file name and matches it against basename(target), so the marker
        // must be the label verbatim -- and must be accepted for every label.
        for (label in DAEMON_LABELS) assertTrue(EjectReceiver.isSafeMarkerName(label), label)
    }

    test("a label that could leave the eject directory is refused") {
        for (bad in listOf("", ".", "..", "/", "a/b", "../x", "../../databases/x", "x/")) {
            assertFalse(EjectReceiver.isSafeMarkerName(bad), "'$bad'")
        }
    }

    test("dots are refused only as whole path components") {
        // "..." and "a..b" are ordinary file names, not traversal; refusing
        // them would only make an eject silently do nothing.
        assertTrue(EjectReceiver.isSafeMarkerName("..."))
        assertTrue(EjectReceiver.isSafeMarkerName("a..b"))
        assertTrue(EjectReceiver.isSafeMarkerName(".hidden"))
    }
}
