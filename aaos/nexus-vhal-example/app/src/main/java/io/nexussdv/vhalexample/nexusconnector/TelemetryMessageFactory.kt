package io.nexussdv.vhalexample.nexusconnector

import com.google.protobuf.Timestamp
import io.nexussdv.vhalexample.VhalProperty
import java.util.UUID
import telemetry.Telemetry.DataType
import telemetry.Telemetry.SensorReading
import telemetry.Telemetry.TelemetryMessage

/** The subject of the native Nexus telemetry message: the VIN, and nothing after it. */
fun telemetrySubject(vin: String): String = "telemetry.$vin"

/** The same shape the nexus-telemetry-client accepts as an answer on `nexus.identity.vin`. */
fun validVin(text: String): Boolean =
    text.length in 1..17 && text.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }

/**
 * Builds the native Nexus telemetry message (`proto/telemetry.proto` in the repository)
 * from VHAL properties. Nothing is invented: no value, no reading.
 */
object TelemetryMessageFactory {
    private const val SCHEMA_VERSION = 1

    /** A number, a boolean or a text as the message carries it; null for anything else. */
    fun valueText(value: Any?): String? = when (value) {
        is Float -> wholeOrFraction(value.toDouble(), value.toString())
        is Double -> wholeOrFraction(value, value.toString())
        is Number -> value.toString()
        is Boolean -> value.toString()
        is String -> value
        else -> null
    }

    /** 42000.0 is written 42000 and 0.0 is written 0; 13.9 stays 13.9. */
    private fun wholeOrFraction(value: Double, text: String): String =
        if (value == value.toLong().toDouble()) value.toLong().toString() else text

    fun reading(property: VhalProperty, nowMillis: Long): SensorReading? {
        val text = valueText(property.value) ?: return null
        return SensorReading.newBuilder()
            .setTimestamp(
                Timestamp.newBuilder()
                    .setSeconds(nowMillis / 1000)
                    .setNanos(((nowMillis % 1000) * 1_000_000).toInt())
            )
            .setValue(text)
            .setDataType(if (property.static) DataType.STATIC else DataType.DYNAMIC)
            .setSensor(property.name)
            .build()
    }

    /** One message for one sending cycle, or null when no ticked property has a value. */
    fun build(vin: String, properties: List<VhalProperty>, ticked: Set<Int>, nowMillis: Long): TelemetryMessage? {
        val readings = properties.filter { it.id in ticked }.mapNotNull { reading(it, nowMillis) }
        if (readings.isEmpty()) return null
        return TelemetryMessage.newBuilder()
            .setMessageId(UUID.randomUUID().toString())
            .setSchemaVersion(SCHEMA_VERSION)
            .setDeviceId(vin)
            .addAllSensorData(readings)
            .build()
    }
}
