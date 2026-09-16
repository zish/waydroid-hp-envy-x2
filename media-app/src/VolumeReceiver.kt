package lan.syshlt.removablemedia

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Receives volume events from waydroid-mediad on the host.
 *
 * The host sends these with `am broadcast --user 0 -f 32`, where 32 is
 * FLAG_INCLUDE_STOPPED_PACKAGES -- without it this receiver would never fire
 * until someone had launched the app by hand, because Android withholds
 * broadcasts from apps in the stopped state.
 */
class VolumeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val label = intent.getStringExtra("label").orEmpty()
        if (label.isEmpty()) {
            Log.w(TAG, "ignoring ${intent.action} with no label")
            return
        }
        when (intent.action) {
            Volumes.ACTION_MOUNTED -> {
                val path = intent.getStringExtra("path").orEmpty()
                val fstype = intent.getStringExtra("fstype").orEmpty()
                Log.i(TAG, "mounted: $label at $path ($fstype)")
                Volumes.show(context, label, path, fstype)
            }
            Volumes.ACTION_UNMOUNTED -> {
                Log.i(TAG, "unmounted: $label")
                Volumes.hide(context, label)
            }
            else -> Log.w(TAG, "unexpected action ${intent.action}")
        }
    }

    companion object {
        private const val TAG = "RemovableMedia"
    }
}
