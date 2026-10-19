package io.nexussdv.vhalexample

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import io.nexussdv.vhalexample.nexusconnector.NO_LEAF_CONFIGURED
import io.nexussdv.vhalexample.nexusconnector.NatsSession
import io.nexussdv.vhalexample.nexusconnector.TelemetryPublisher
import io.nexussdv.vhalexample.nexusconnector.leafUrl
import io.nexussdv.vhalexample.nexusconnector.validVin
import java.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Holds the connection to the leaf and sends the ticked properties.
 *
 * Where the leaf is comes from the boot configuration of this VM (`ro.boot.nexus.leaf`);
 * which vehicle this is, the app asks the nexus-connectivity-agent over the leaf. The app
 * holds neither a credential nor a VIN of its own.
 */
class VhalExampleService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val session = NatsSession(::onLink)
    private var connectJob: Job? = null
    private var vinJob: Job? = null

    private val publisher by lazy {
        val selection = SelectionStore.get(this)
        TelemetryPublisher(
            sink = session,
            vin = { state.value.vin },
            properties = { VhalWrapper.getProperties(selection.ticked) },
            ticked = { selection.ticked },
            periodMs = SEND_PERIOD_MS,
            onSent = { at -> _state.update { it.copy(sent = it.sent + 1, lastSentMillis = at) } },
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(1, notification())
        VhalWrapper.init(this)
        if (connectJob == null) connectJob = scope.launch { connectToLeaf() }
        when (intent?.action) {
            ACTION_START_SENDING -> {
                publisher.start()
                _state.update { it.copy(sending = true) }
            }
            ACTION_STOP_SENDING -> {
                publisher.stop()
                _state.update { it.copy(sending = false) }
            }
            ACTION_SEND_ONCE -> scope.launch { publisher.tick() }
        }
        return START_STICKY
    }

    /**
     * Tries until the leaf is reached once; from then on the NATS client reconnects by
     * itself. A VM whose boot configuration names no leaf has none: the status line says
     * so and nothing is tried, as the boot configuration does not change while the VM runs.
     */
    private suspend fun connectToLeaf() {
        val leafUrl = leafUrl(GetpropBootProperty)
        if (leafUrl == null) {
            _state.update { it.copy(leaf = LeafState.NOT_REACHABLE, detail = NO_LEAF_CONFIGURED, vin = null) }
            return
        }
        while (scope.isActive) {
            try {
                session.connect(leafUrl)
                onLink(true)
                return
            } catch (e: Exception) {
                Log.w(TAG, "leaf not reached: ${e.message}")
                _state.update { it.copy(leaf = LeafState.NOT_REACHABLE, detail = e.message, vin = null) }
                delay(RETRY_MS)
            }
        }
    }

    @Synchronized
    private fun onLink(connected: Boolean) {
        vinJob?.cancel()
        if (!connected) {
            _state.update { it.copy(leaf = LeafState.NOT_REACHABLE, detail = null, vin = null) }
            return
        }
        _state.update { it.copy(leaf = LeafState.REACHABLE, detail = null, vin = null) }
        vinJob = scope.launch { askVin() }
    }

    /** Asked after every connect: the VIN is never kept from an earlier connection. */
    private suspend fun askVin() {
        while (scope.isActive) {
            val answer = try {
                session.request(IDENTITY_SUBJECT, IDENTITY_WAIT)?.toString(Charsets.UTF_8)
            } catch (e: Exception) {
                null
            }
            if (answer != null && validVin(answer)) {
                _state.update { it.copy(vin = answer, detail = null) }
                return
            }
            _state.update { it.copy(detail = "no VIN from the nexus-connectivity-agent yet") }
            delay(RETRY_MS)
        }
    }

    // A dataSync foreground service is stopped by the system after six hours in a day
    // (Android 15 and later) and must end itself when told so.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    private fun notification(): Notification {
        val channel = NotificationChannel(TAG, "Nexus VHAL example", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        return Notification.Builder(this, TAG)
            .setContentTitle("Nexus VHAL example")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .build()
    }

    override fun onDestroy() {
        publisher.stop()
        scope.cancel()
        session.close()
        _state.value = LinkStatus(sent = state.value.sent, lastSentMillis = state.value.lastSentMillis)
        super.onDestroy()
    }

    companion object {
        private const val TAG = "VhalExampleService"
        private const val ACTION_START_SENDING = "io.nexussdv.vhalexample.START_SENDING"
        private const val ACTION_STOP_SENDING = "io.nexussdv.vhalexample.STOP_SENDING"
        private const val ACTION_SEND_ONCE = "io.nexussdv.vhalexample.SEND_ONCE"
        private const val IDENTITY_SUBJECT = "nexus.identity.vin"
        private val IDENTITY_WAIT = Duration.ofSeconds(2)
        private const val SEND_PERIOD_MS = 2000L
        private const val RETRY_MS = 3000L

        private val _state = MutableStateFlow(LinkStatus())
        val state: StateFlow<LinkStatus> = _state

        /** Starts the service and its connection to the leaf; sends nothing yet. */
        fun connect(context: Context) = send(context, null)
        fun startSending(context: Context) = send(context, ACTION_START_SENDING)
        fun stopSending(context: Context) = send(context, ACTION_STOP_SENDING)
        fun sendOnce(context: Context) = send(context, ACTION_SEND_ONCE)
        fun stop(context: Context) = context.stopService(Intent(context, VhalExampleService::class.java))

        private fun send(context: Context, action: String?) {
            context.startForegroundService(Intent(context, VhalExampleService::class.java).setAction(action))
        }
    }
}
