package lan.syshlt.removablemedia

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.provider.DocumentsContract

/**
 * Everything that knows what a "volume" is.
 *
 * Note what is absent: any use of java.io.File. This app never opens, reads,
 * lists or writes anything on the removable volume. The host daemon mounts it
 * into the FUSE lower directory, ExternalStorageProvider indexes it, and all
 * we ever do is hand DocumentsUI a content:// URI. That is why the manifest
 * declares no storage permission at all, and why this app cannot be the thing
 * that corrupts someone's memory card.
 */
object Volumes {

    const val ACTION_MOUNTED = "lan.syshlt.bigtab01.media.VOLUME_MOUNTED"
    const val ACTION_UNMOUNTED = "lan.syshlt.bigtab01.media.VOLUME_UNMOUNTED"

    private const val CHANNEL_ID = "removable-media"
    private const val PREFS = "volumes"

    /** ExternalStorageProvider. Its "primary" root is /storage/emulated/0. */
    private const val AUTHORITY = "com.android.externalstorage.documents"

    /** Matches BASE_SUBDIR in waydroid-mediad: <data>/media/0/Removable. */
    private const val SUBDIR = "Removable"

    /**
     * The intent that opens a volume in whatever the user's file manager is.
     *
     * A document URI under ExternalStorageProvider, not a file:// path -- a
     * file:// URI would throw FileUriExposedException, and a raw path is not
     * something DocumentsUI can navigate to at all. The document id format is
     * "<root>:<relative path>", so a volume mounted at /sdcard/Removable/FOO is
     * "primary:Removable/FOO".
     */
    fun openIntent(label: String): Intent {
        val docId = "primary:$SUBDIR/$label"
        val uri: Uri = DocumentsContract.buildDocumentUri(AUTHORITY, docId)
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            )
        }
    }

    /** The tap target, falling back to our own status screen if nothing handles it. */
    private fun tapIntent(ctx: Context, label: String): Intent {
        val open = openIntent(label)
        val resolved = ctx.packageManager.resolveActivity(open, 0)
        return if (resolved != null) open
        else Intent(ctx, StatusActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun channel(ctx: Context): NotificationManager {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(
            CHANNEL_ID,
            ctx.getString(R.string.channel_name),
            // LOW: a card being present is a state, not an event worth a sound.
            NotificationManager.IMPORTANCE_LOW
        )
        ch.description = ctx.getString(R.string.channel_desc)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
        return nm
    }

    /** Stable per label, so a re-mount replaces its notification instead of stacking. */
    private fun notificationId(label: String): Int = label.hashCode() or 1

    /** The Eject button, which asks the host daemon to unmount this volume. */
    private fun ejectAction(ctx: Context, label: String): Notification.Action {
        val intent = Intent(ctx, EjectReceiver::class.java).putExtra("label", label)
        val pending = PendingIntent.getBroadcast(
            ctx, notificationId(label), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Action.Builder(
            Icon.createWithResource(ctx, R.drawable.ic_media),
            ctx.getString(R.string.eject), pending
        ).build()
    }

    private fun post(ctx: Context, label: String, detail: String, ejecting: Boolean) {
        val nm = channel(ctx)
        val pending = PendingIntent.getActivity(
            ctx, notificationId(label), tapIntent(ctx, label),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = Notification.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_media)
            .setContentTitle(label)
            .setContentText(detail)
            .setStyle(Notification.BigTextStyle().bigText(detail))
            .setContentIntent(pending)
            .setOngoing(true)          // persistent: it reflects a state
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS)
        // No Eject button once one is already in flight: pressing it twice
        // would leave a second marker for a volume that is already gone, and
        // the daemon would log an unknown-volume warning for it.
        if (!ejecting) builder.addAction(ejectAction(ctx, label))
        nm.notify(notificationId(label), builder.build())
    }

    fun show(ctx: Context, label: String, path: String, fstype: String) {
        val detail = if (fstype.isEmpty()) path else "$path  ($fstype)"
        post(ctx, label, detail, ejecting = false)
        remember(ctx, label, detail)
    }

    /**
     * Show that an eject is in flight.
     *
     * The notification is not cancelled here: the host is the authority on
     * whether the volume actually went away, and it says so with an
     * ACTION_UNMOUNTED broadcast. If the unmount fails -- a busy volume, say --
     * the notification correctly stays put rather than lying about it.
     */
    fun markEjecting(ctx: Context, label: String) {
        val detail = prefs(ctx).getString(label, null) ?: return
        post(ctx, label, ctx.getString(R.string.ejecting), ejecting = true)
        remember(ctx, label, detail)
    }

    fun hide(ctx: Context, label: String) {
        ctx.getSystemService(NotificationManager::class.java)
            .cancel(notificationId(label))
        forget(ctx, label)
    }

    // -- what we know about, kept without touching the filesystem -------------

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun remember(ctx: Context, label: String, detail: String) =
        prefs(ctx).edit().putString(label, detail).apply()

    private fun forget(ctx: Context, label: String) =
        prefs(ctx).edit().remove(label).apply()

    /**
     * Known volumes, newest state first.
     *
     * Read from our own record of the broadcasts rather than by listing
     * /sdcard/Removable, which would be exactly the file I/O this app promises
     * not to do -- and would need a storage permission to boot.
     */
    fun known(ctx: Context): List<Pair<String, String>> =
        prefs(ctx).all.entries
            .map { it.key to (it.value?.toString() ?: "") }
            .sortedBy { it.first.lowercase() }
}
