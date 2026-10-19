package io.nexussdv.vhalexample.nexusconnector

import io.nexussdv.vhalexample.VhalProperty
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import telemetry.Telemetry.DataType
import telemetry.Telemetry.TelemetryMessage

class TelemetryMessageFactoryTest {
    private val now = 1_760_000_000_123L

    private fun property(id: Int, name: String, value: Any?, static: Boolean = false, error: String? = null) =
        VhalProperty(id = id, areaId = 0, name = name, value = value, static = static, error = error)

    @Test
    fun `a number becomes a reading named after the property`() {
        val r = TelemetryMessageFactory.reading(property(1, "PERF_VEHICLE_SPEED", 13.9f), now)!!
        assertEquals("PERF_VEHICLE_SPEED", r.sensor)
        assertEquals("13.9", r.value)
        assertEquals(DataType.DYNAMIC, r.dataType)
        assertEquals(now / 1000, r.timestamp.seconds)
        assertEquals(123_000_000, r.timestamp.nanos)
    }

    @Test
    fun `an integer keeps its digits`() {
        assertEquals("8", TelemetryMessageFactory.reading(property(2, "GEAR_SELECTION", 8), now)!!.value)
        assertEquals("42000", TelemetryMessageFactory.reading(property(3, "FUEL_LEVEL", 42000f), now)!!.value)
    }

    @Test
    fun `zero is sent as 0, not left out and not replaced`() {
        assertEquals("0", TelemetryMessageFactory.reading(property(1, "PERF_VEHICLE_SPEED", 0f), now)!!.value)
        assertEquals("0", TelemetryMessageFactory.reading(property(2, "GEAR_SELECTION", 0), now)!!.value)
    }

    @Test
    fun `a boolean is sent as true or false`() {
        assertEquals("true", TelemetryMessageFactory.reading(property(4, "PARKING_BRAKE_ON", true), now)!!.value)
        assertEquals("false", TelemetryMessageFactory.reading(property(4, "PARKING_BRAKE_ON", false), now)!!.value)
    }

    @Test
    fun `a text is sent as it is`() {
        assertEquals("Toy Vehicle", TelemetryMessageFactory.reading(property(5, "INFO_MAKE", "Toy Vehicle"), now)!!.value)
    }

    @Test
    fun `a property without a value gives no reading`() {
        assertNull(TelemetryMessageFactory.reading(property(1, "PERF_VEHICLE_SPEED", null), now))
        assertNull(TelemetryMessageFactory.reading(property(4, "PARKING_BRAKE_ON", null, error = "not readable"), now))
    }

    @Test
    fun `a value that is neither number, boolean nor text gives no reading`() {
        assertNull(TelemetryMessageFactory.reading(property(6, "INFO_FUEL_TYPE", arrayOf(1, 2)), now))
    }

    @Test
    fun `a property that never changes is marked static`() {
        val r = TelemetryMessageFactory.reading(property(5, "INFO_MAKE", "Toy Vehicle", static = true), now)!!
        assertEquals(DataType.STATIC, r.dataType)
    }

    @Test
    fun `only ticked properties are in the message`() {
        val properties = listOf(
            property(1, "PERF_VEHICLE_SPEED", 0f),
            property(2, "GEAR_SELECTION", 4),
            property(3, "FUEL_LEVEL", 42000f),
        )
        val message = TelemetryMessageFactory.build("PKG11MESH01", properties, ticked = setOf(1, 3), nowMillis = now)!!
        assertEquals(listOf("PERF_VEHICLE_SPEED", "FUEL_LEVEL"), message.sensorDataList.map { it.sensor })
        assertEquals(listOf("0", "42000"), message.sensorDataList.map { it.value })
    }

    @Test
    fun `the message carries the VIN, a schema version and a fresh id`() {
        val properties = listOf(property(1, "PERF_VEHICLE_SPEED", 1f))
        val first = TelemetryMessageFactory.build("PKG11MESH01", properties, setOf(1), now)!!
        val second = TelemetryMessageFactory.build("PKG11MESH01", properties, setOf(1), now)!!
        assertEquals("PKG11MESH01", first.deviceId)
        assertEquals(1, first.schemaVersion)
        assertTrue(first.messageId.isNotEmpty())
        assertFalse(first.messageId == second.messageId)
        // What the cloud decodes is what was built.
        assertEquals(first, TelemetryMessage.parseFrom(first.toByteArray()))
    }

    @Test
    fun `a ticked property without a value is left out of the message`() {
        val properties = listOf(property(1, "PERF_VEHICLE_SPEED", 5f), property(4, "PARKING_BRAKE_ON", null, error = "not readable"))
        val message = TelemetryMessageFactory.build("PKG11MESH01", properties, setOf(1, 4), now)!!
        assertEquals(listOf("PERF_VEHICLE_SPEED"), message.sensorDataList.map { it.sensor })
    }

    @Test
    fun `nothing to send gives no message`() {
        val properties = listOf(property(1, "PERF_VEHICLE_SPEED", 5f), property(4, "PARKING_BRAKE_ON", null))
        assertNull(TelemetryMessageFactory.build("PKG11MESH01", properties, emptySet(), now))
        assertNull(TelemetryMessageFactory.build("PKG11MESH01", properties, setOf(4), now))
    }

    @Test
    fun `the subject is telemetry and the VIN, nothing after it`() {
        assertEquals("telemetry.PKG11MESH01", telemetrySubject("PKG11MESH01"))
    }

    @Test
    fun `only something shaped like a VIN is taken as one`() {
        assertTrue(validVin("PKG11MESH01"))
        assertTrue(validVin("WBA-12_3"))
        assertFalse(validVin(""))
        assertFalse(validVin("A".repeat(18)))
        assertFalse(validVin("VIN.WITH.DOTS"))
        assertFalse(validVin("VIN *"))
    }
}
