package lan.syshlt.quatmon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.io.File

/*
 * Samples both rotation-vector sensors at 20 Hz and writes them to disk, for
 * as long as it is running -- including while other apps are in the
 * foreground, which is the point: rotation anomalies are seen in other apps,
 * not in this one.
 *
 * THREADS
 *
 *   sampler   a HandlerThread. Sensor callbacks are delivered here (the
 *             Handler overload of registerListener), and a 50 ms tick emits
 *             one paired sample. Never touches disk.
 *   writer    inside LogWriter. Owns all file I/O.
 *   main      UI only. Reads the ring, never writes it.
 *
 * The sampler hands samples to the writer through a bounded queue that drops
 * rather than blocks, so no amount of disk latency can perturb sampling
 * timing. Dropped samples are counted and surfaced in the UI.
 *
 * WHY A FIXED TICK RATHER THAN EMITTING PER SENSOR EVENT
 *
 * The two sensors are independent and neither is guaranteed to be on the same
 * cadence, so pairing on arrival would produce a series whose spacing is an
 * artefact of which sensor happened to fire. Instead each callback just parks
 * its latest value, and the tick samples both. That yields a uniform 20 Hz
 * series -- and, because each reading's age is recorded, a sensor that has
 * stopped publishing shows up as a rising age rather than as a plausible flat
 * line. That distinction is the whole reason docs/19 was hard to spot.
 */
class SamplerService : Service() {

    private lateinit var sm: SensorManager
    private var hwSensor: Sensor? = null
    private var swSensor: Sensor? = null
    private var gmSensor: Sensor? = null
    private var accSensor: Sensor? = null
    private var gyrSensor: Sensor? = null
    private var magSensor: Sensor? = null

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var running = false

    /* Latest reading from each sensor, written and read only on the sampler
     * thread, so no synchronisation is needed. */
    private val hwQ = FloatArray(4)
    private val swQ = FloatArray(4)
    private val gmQ = FloatArray(4)
    private var hwStamp = 0L
    private var swStamp = 0L
    private var gmStamp = 0L
    private val acc = FloatArray(3)
    private val gyr = FloatArray(3)
    private val mag = FloatArray(3)
    private var magAcc = -1

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            emit()
            handler?.postDelayed(this, TICK_MS)
        }
    }

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            val v = e.values
            when {
                e.sensor === hwSensor -> { quat(hwQ, v); hwStamp = e.timestamp }
                e.sensor === swSensor -> { quat(swQ, v); swStamp = e.timestamp }
                e.sensor === gmSensor -> { quat(gmQ, v); gmStamp = e.timestamp }
                e.sensor === accSensor -> vec(acc, v)
                e.sensor === gyrSensor -> vec(gyr, v)
                e.sensor === magSensor -> vec(mag, v)
            }
        }
        /* Android's own verdict on the magnetometer, worth keeping alongside
         * our |B| check: they can disagree, and when they do that is itself
         * information about the 9-axis fusion's inputs. */
        override fun onAccuracyChanged(s: Sensor?, a: Int) {
            if (s === magSensor) magAcc = a
        }
        private fun quat(dst: FloatArray, v: FloatArray) {
            dst[0] = v[0]; dst[1] = v[1]; dst[2] = v[2]; dst[3] = Q.w(v)
        }
        private fun vec(dst: FloatArray, v: FloatArray) {
            dst[0] = v[0]; dst[1] = v[1]; dst[2] = v[2]
        }
    }

    override fun onBind(i: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val rv = sm.getSensorList(Sensor.TYPE_ROTATION_VECTOR)

        /* dumpsys sensorservice lists TWO rotation vectors -- the ITE8350's
         * firmware fusion via waydroid-sensord, and AOSP's software fusion --
         * but SensorService only publishes one of them to apps, because it
         * suppresses a virtual sensor when the HAL already supplies that type.
         * So the 9-axis software fusion is simply not reachable from here.
         *
         * That is not fatal, and arguably better. GEOMAGNETIC_ROTATION_VECTOR
         * (accel + magn, no gyro) and GAME_ROTATION_VECTOR (accel + gyro, no
         * magn) between them cover the same inputs as one 9-axis fusion, and
         * split along exactly the line that matters here: the magnetometer is
         * the contaminated input, so comparing the hub against one fusion that
         * uses it and one that does not isolates the cause directly.
         *
         * Whatever gets chosen is recorded in meta.txt, because a column is
         * uninterpretable later without knowing which sensor produced it. */
        hwSensor = rv.firstOrNull {
            it.vendor.contains("bigtab01", true) || it.name.contains("ITE8350", true)
        } ?: rv.firstOrNull()
        swSensor = rv.firstOrNull { it !== hwSensor }
            ?: sm.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR)
        gmSensor = sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
        accSensor = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyrSensor = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        magSensor = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)

        for (s in sm.getSensorList(Sensor.TYPE_ALL))
            Log.i(TAG, "visible: type=${s.type} ${s.name} (${s.vendor})")
        writeMeta()

        ring = Ring(RING_CAP)
        val w = LogWriter(logDir(this))
        w.start()
        writer = w
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_MARK) {
            onMark()
            return START_STICKY
        }
        if (running) return START_STICKY

        createChannel()
        startForeground(NOTE_ID, buildNotification("starting..."))

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "quatmon:sampler").apply {
            setReferenceCounted(false)
            acquire()
        }

        val t = HandlerThread("quat-sampler", android.os.Process.THREAD_PRIORITY_FOREGROUND)
        t.start()
        thread = t
        val h = Handler(t.looper)
        handler = h
        running = true

        /* Load recent history into the ring BEFORE sensors start, so the ring
         * has exactly one writer at any moment and the graph is populated the
         * instant the activity opens. */
        h.post {
            try { History.loadInto(logDir(this), ring!!) }
            catch (e: Exception) { Log.e(TAG, "history load failed", e) }

            for (s in listOf(hwSensor, swSensor, gmSensor,
                             accSensor, gyrSensor, magSensor)) {
                s?.let { sm.registerListener(listener, it, PERIOD_US, h) }
            }
            h.postDelayed(tick, TICK_MS)
            notify(status())
        }
        return START_STICKY
    }

    private fun emit() {
        val nowNs = SystemClock.elapsedRealtimeNanos()
        val bUt = Math.sqrt(
            (mag[0] * mag[0] + mag[1] * mag[1] + mag[2] * mag[2]).toDouble()).toFloat()
        val s = Sample(
            System.currentTimeMillis(), nowNs / 1_000_000L,
            hwQ[0], hwQ[1], hwQ[2], hwQ[3], age(nowNs, hwStamp),
            swQ[0], swQ[1], swQ[2], swQ[3], age(nowNs, swStamp),
            gmQ[0], gmQ[1], gmQ[2], gmQ[3], age(nowNs, gmStamp),
            acc[0], acc[1], acc[2],
            gyr[0], gyr[1], gyr[2],
            mag[0], mag[1], mag[2], magAcc, bUt,
            Q.angleDeg(hwQ[0], hwQ[1], hwQ[2], hwQ[3], swQ[0], swQ[1], swQ[2], swQ[3]),
            Q.angleDeg(hwQ[0], hwQ[1], hwQ[2], hwQ[3], gmQ[0], gmQ[1], gmQ[2], gmQ[3])
        )
        ring?.add(s)
        writer?.offer(s)

        val n = ring?.total ?: 0L
        if (n % NOTE_EVERY == 0L) notify(status())
    }

    /*
     * Record which physical sensor filled each column. Six months from now the
     * CSV headers say hw/sw/gm and nothing else; without this the data cannot
     * be interpreted, only guessed at.
     */
    private fun writeMeta() {
        try {
            val d = logDir(this)
            d.mkdirs()
            val f = File(d, "meta.txt")
            val sb = StringBuilder()
            sb.append("# quat-monitor sensor bindings, written at service start\n")
            sb.append("written=").append(Anomaly.iso(System.currentTimeMillis())).append('\n')
            fun row(slot: String, s: Sensor?) {
                sb.append(slot).append('=')
                if (s == null) sb.append("ABSENT\n")
                else sb.append(s.name).append(" | ").append(s.vendor)
                    .append(" | type=").append(s.type)
                    .append(" | ver=").append(s.version)
                    .append(" | maxRate=").append(
                        if (s.minDelay > 0) 1_000_000 / s.minDelay else 0).append("Hz\n")
            }
            row("hw", hwSensor); row("sw", swSensor); row("gm", gmSensor)
            row("accel", accSensor); row("gyro", gyrSensor); row("magn", magSensor)
            sb.append("\n# every sensor visible to this app\n")
            for (s in sm.getSensorList(Sensor.TYPE_ALL))
                sb.append("  type=").append(s.type).append(' ')
                    .append(s.name).append(" | ").append(s.vendor).append('\n')
            f.writeText(sb.toString())
            Log.i(TAG, "meta written to ${f.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "meta write failed", e)
        }
    }

    private fun age(nowNs: Long, stamp: Long): Float =
        if (stamp == 0L) Float.NaN else (nowNs - stamp) / 1e6f

    /* Stamp the moment, then collect the description later -- see Anomaly. */
    private fun onMark() {
        val now = System.currentTimeMillis()
        val dir = logDir(this)
        val id = try { Anomaly.mark(dir, now) } catch (e: Exception) {
            Log.e(TAG, "mark failed", e); return
        }
        Thread({ Anomaly.capture(dir, id, now) }, "quat-capture").start()

        val nm = getSystemService(NotificationManager::class.java)
        val open = Intent(this, AnomalyActivity::class.java)
            .putExtra(AnomalyActivity.EXTRA_ID, id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pi = PendingIntent.getActivity(this, id.toInt(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        nm.notify(id.toInt(), Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_edit)
            .setContentTitle("Anomaly marked at ${Anomaly.iso(now).substring(11, 19)}")
            .setContentText("Tap to describe what you saw")
            .setAutoCancel(true)
            .setContentIntent(pi)
            .build())
    }

    private fun status(): String {
        val w = writer ?: return "no writer"
        val n = ring?.total ?: 0L
        val d = w.dropped.get()
        return "$n samples, ${w.written.get()} written" +
               (if (d > 0) ", $d dropped" else "") + " -> ${w.currentFile}"
    }

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(
            CHANNEL, "Quaternion sampling", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Ongoing sampling and anomaly reporting"
            setShowBadge(false)
        })
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        /* The action goes straight to this service, not through a receiver:
         * Android 12+ blocks notification trampolines, and going direct also
         * means the timestamp is taken with no hop in between. */
        val mark = PendingIntent.getService(this, 1,
            Intent(this, SamplerService::class.java).setAction(ACTION_MARK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("Quat Monitor")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(
                null, "Report anomaly", mark).build())
            .build()
    }

    private fun notify(text: String) {
        try {
            getSystemService(NotificationManager::class.java)
                .notify(NOTE_ID, buildNotification(text))
        } catch (e: Exception) { /* POST_NOTIFICATIONS not granted */ }
    }

    override fun onDestroy() {
        running = false
        handler?.removeCallbacksAndMessages(null)
        try { sm.unregisterListener(listener) } catch (e: Exception) {}
        thread?.quitSafely()
        writer?.stop()
        wakeLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "quatmon"
        const val CHANNEL = "quatmon"
        const val NOTE_ID = 1
        const val ACTION_MARK = "lan.syshlt.quatmon.MARK"

        const val TICK_MS = 50L                 // 20 Hz, the hub's ceiling
        const val PERIOD_US = 50_000            // ask both sensors for 20 Hz
        /* One hour of live history, ~5.8 MB of primitive arrays now that
         * three quaternions are retained. Anything older is on disk, where it
         * belongs, and where the replay analysis reads it from anyway. */
        const val RING_CAP = 72_000
        private const val NOTE_EVERY = 100L     // refresh the notification ~5 s

        @Volatile var ring: Ring? = null
        @Volatile var writer: LogWriter? = null

        fun logDir(c: Context): File = File(c.getExternalFilesDir(null), "logs")
    }
}
