package io.nexussdv.vhalexample

/** One VHAL property as the screen shows it and the message carries it. */
data class VhalProperty(
    val id: Int,
    val areaId: Int,
    /** The name from `VehiclePropertyIds`, e.g. `PERF_VEHICLE_SPEED`. */
    val name: String,
    /** The value read, or null when there is none. */
    val value: Any? = null,
    /** True for a property whose value never changes while the vehicle runs. */
    val static: Boolean = false,
    /** Why the property could not be read, or null when it was. */
    val error: String? = null,
)
