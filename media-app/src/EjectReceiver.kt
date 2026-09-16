package lan.syshlt.removablemedia

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File

/**
 * Handles the notification's Eject action.
 *
 * There is no channel from inside the container out to the host: the daemon can
 * push events in with `am broadcast`, but nothing pulls the other way. So this
 * drops a zero-byte marker named after the volume into the app's own private
 * files directory, which on this host is plain host filesystem underneath, and
 * waydroid-mediad polls for it and unmounts.
 *
 * On the app's "no file I/O" rule: this is the one file the app ever writes, it
 * lives in the app sandbox and never on the removable volume, and it carries no
 * data at all -- the entire message is the filename. It is a control signal, not
 * access to the user's media. The alternative designs were worse: a logcat line
 * scraped by the host is fragile across ring-buffer wraps, and Settings.Global
 * would need WRITE_SECURE_SETTINGS plus a container round-trip per poll.
 */
class EjectReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val label = intent.getStringExtra("label").orEmpty()
        if (label.isEmpty() || label.contains('/') || label == "." || label == "..") {
            Log.w(TAG, "refusing eject request for bad label: '$label'")
            return
        }
        try {
            val dir = File(context.filesDir, "eject")
            dir.mkdirs()
            File(dir, label).createNewFile()
            Log.i(TAG, "eject requested: $label")
            Volumes.markEjecting(context, label)
        } catch (e: Exception) {
            Log.e(TAG, "could not request eject for $label", e)
        }
    }

    companion object {
        private const val TAG = "RemovableMedia"
    }
}
