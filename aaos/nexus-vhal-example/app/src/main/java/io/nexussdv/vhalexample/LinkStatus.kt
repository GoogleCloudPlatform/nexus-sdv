package io.nexussdv.vhalexample

enum class LeafState(val text: String) {
    SEARCHING("searching"),
    REACHABLE("reachable"),
    NOT_REACHABLE("not reachable"),
}

/** What the status line shows: the leaf, the vehicle, and what has been sent. */
data class LinkStatus(
    val leaf: LeafState = LeafState.SEARCHING,
    /** Why the leaf or the VIN is missing, when a reason is known. */
    val detail: String? = null,
    /** The VIN the nexus-connectivity-agent answered with, or null while it is not known. */
    val vin: String? = null,
    val sent: Int = 0,
    val lastSentMillis: Long? = null,
    val sending: Boolean = false,
)

fun statusLine(status: LinkStatus, formatTime: (Long) -> String): String {
    val leaf = status.leaf.text + (status.detail?.let { " ($it)" } ?: "")
    val vin = status.vin ?: "not known"
    val last = status.lastSentMillis?.let(formatTime) ?: "never"
    return "Leaf: $leaf · VIN: $vin · Sent: ${status.sent} · Last: $last"
}
