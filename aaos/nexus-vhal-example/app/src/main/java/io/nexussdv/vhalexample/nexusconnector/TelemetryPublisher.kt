package io.nexussdv.vhalexample.nexusconnector

import io.nexussdv.vhalexample.VhalProperty

/** Minimal publish surface so the publisher is testable without a NATS server. */
interface PublishSink {
    val connected: Boolean
    fun publish(subject: String, bytes: ByteArray)
}

/**
 * Sends one telemetry message per cycle with a reading for every ticked property.
 * A cycle sends nothing while the leaf is away, while the VIN is not known, or when no
 * ticked property has a value.
 */
class TelemetryPublisher(
    private val sink: PublishSink,
    private val vin: () -> String?,
    private val properties: () -> List<VhalProperty>,
    private val ticked: () -> Set<Int>,
    private val periodMs: Long,
    /** Called with the time of every message that went out. */
    private val onSent: (Long) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private var timer: java.util.Timer? = null

    /** One sending cycle. start() drives it on a timer; "send once" calls it directly. */
    @Synchronized
    fun tick() {
        if (!sink.connected) return
        val vin = vin() ?: return
        val now = clock()
        val message = TelemetryMessageFactory.build(vin, properties(), ticked(), now) ?: return
        try {
            sink.publish(telemetrySubject(vin), message.toByteArray())
        } catch (e: Exception) {
            return // the leaf went away between the check and the publish; the next cycle tries again
        }
        onSent(now)
    }

    fun start() {
        stop()
        timer = java.util.Timer("telemetry-publisher", true).apply {
            scheduleAtFixedRate(object : java.util.TimerTask() {
                override fun run() = tick()
            }, 0, periodMs)
        }
    }

    fun stop() {
        timer?.cancel()
        timer = null
    }
}
