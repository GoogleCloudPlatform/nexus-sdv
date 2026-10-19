package io.nexussdv.vhalexample.nexusconnector

import io.nats.client.Connection
import io.nats.client.ConnectionListener
import io.nats.client.Nats
import io.nats.client.Options
import java.time.Duration

/**
 * The connection to the leaf in the vehicle. It carries no credential: the leaf accepts
 * local clients as they are. Once connected, the NATS client reconnects by itself;
 * [onLink] is told when the leaf is lost (false) and when it is back (true).
 */
class NatsSession(private val onLink: (Boolean) -> Unit) : PublishSink {
    @Volatile
    private var connection: Connection? = null

    override val connected: Boolean
        get() = connection?.status == Connection.Status.CONNECTED

    /** Throws when the leaf cannot be reached; the caller decides when to try again. */
    fun connect(natsUrl: String) {
        val options = Options.builder()
            .server(natsUrl)
            .maxReconnects(-1)
            .reconnectWait(Duration.ofSeconds(2))
            .connectionTimeout(Duration.ofSeconds(10))
            .connectionListener(object : ConnectionListener {
                override fun connectionEvent(conn: Connection, type: ConnectionListener.Events) {
                    when (type) {
                        ConnectionListener.Events.DISCONNECTED -> onLink(false)
                        ConnectionListener.Events.RECONNECTED -> onLink(true)
                        else -> {}
                    }
                }
            })
            .build()
        connection = Nats.connect(options)
    }

    override fun publish(subject: String, bytes: ByteArray) {
        val nc = connection ?: throw IllegalStateException("not connected")
        nc.publish(subject, bytes)
    }

    /** A NATS request with an empty payload; the answer's payload, or null when none came in time. */
    fun request(subject: String, timeout: Duration): ByteArray? {
        val nc = connection ?: throw IllegalStateException("not connected")
        return nc.request(subject, null, timeout)?.data
    }

    fun close() {
        connection?.close()
        connection = null
    }
}
