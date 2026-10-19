package io.nexussdv.vhalexample.nexusconnector

import io.nexussdv.vhalexample.VhalProperty
import org.junit.Assert.assertEquals
import org.junit.Test
import telemetry.Telemetry.TelemetryMessage

class TelemetryPublisherTest {
    private class FakeSession : PublishSink {
        var up = true
        val published = mutableListOf<Pair<String, ByteArray>>()
        override val connected get() = up
        override fun publish(subject: String, bytes: ByteArray) {
            if (!up) throw IllegalStateException("down")
            published += subject to bytes
        }
    }

    private val properties = listOf(
        VhalProperty(id = 1, areaId = 0, name = "PERF_VEHICLE_SPEED", value = 0f),
        VhalProperty(id = 2, areaId = 0, name = "GEAR_SELECTION", value = 4),
    )
    private var vin: String? = "PKG11MESH01"
    private var ticked = setOf(1, 2)
    private val sent = mutableListOf<Long>()

    private fun publisher(session: FakeSession) = TelemetryPublisher(
        sink = session,
        vin = { vin },
        properties = { properties },
        ticked = { ticked },
        periodMs = 2000,
        onSent = { sent += it },
        clock = { 1_760_000_000_000L },
    )

    @Test
    fun `one cycle is one message on telemetry and the VIN`() {
        val s = FakeSession()
        publisher(s).tick()
        val (subject, bytes) = s.published.single()
        assertEquals("telemetry.PKG11MESH01", subject)
        val message = TelemetryMessage.parseFrom(bytes)
        assertEquals("PKG11MESH01", message.deviceId)
        assertEquals(listOf("PERF_VEHICLE_SPEED", "GEAR_SELECTION"), message.sensorDataList.map { it.sensor })
        assertEquals(listOf(1_760_000_000_000L), sent)
    }

    @Test
    fun `an unticked property is in no later message`() {
        val s = FakeSession()
        val p = publisher(s)
        p.tick()
        ticked = setOf(2)
        p.tick()
        val last = TelemetryMessage.parseFrom(s.published.last().second)
        assertEquals(listOf("GEAR_SELECTION"), last.sensorDataList.map { it.sensor })
    }

    @Test
    fun `nothing is sent while the VIN is not known`() {
        val s = FakeSession()
        vin = null
        publisher(s).tick()
        assertEquals(0, s.published.size)
        assertEquals(0, sent.size)
    }

    @Test
    fun `nothing is sent and nothing is counted while the leaf is away`() {
        val s = FakeSession().apply { up = false }
        val p = publisher(s)
        p.tick()
        assertEquals(0, sent.size)
        s.up = true
        p.tick()
        assertEquals(1, s.published.size)
        assertEquals(1, sent.size)
    }

    @Test
    fun `nothing ticked sends nothing`() {
        val s = FakeSession()
        ticked = emptySet()
        publisher(s).tick()
        assertEquals(0, s.published.size)
    }
}
