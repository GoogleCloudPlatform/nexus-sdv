package io.nexussdv.vhalexample.nexusconnector

/**
 * Where the leaf is: the boot configuration of this VM carries one line,
 * `androidboot.nexus.leaf=<address>:<port>`, which Android shows as the system property
 * `ro.boot.nexus.leaf`. The nexus-telemetry-client reads the same line. There is no other
 * source: without the line the app has no leaf.
 */
const val LEAF_PROPERTY = "ro.boot.nexus.leaf"

const val NO_LEAF_CONFIGURED = "no leaf configured for this VM: androidboot.nexus.leaf is not set"

/** Reads one system property; null when it cannot be read. */
fun interface BootProperty {
    fun read(name: String): String?
}

/**
 * `host:port` with a port from 1 to 65535 and a host without blanks or a scheme; null for
 * anything else. The rules of the nexus-telemetry-client (`core/src/leaf_addr.rs`).
 */
fun parseLeafAddress(value: String): String? {
    val v = value.trim()
    val colon = v.lastIndexOf(':')
    if (colon < 0) return null
    val host = v.substring(0, colon)
    val port = v.substring(colon + 1).toIntOrNull() ?: return null
    val hostOk = host.isNotEmpty() && '/' !in host && ':' !in host && host.none { it.isWhitespace() }
    return if (hostOk && port in 1..65535) v else null
}

/** The leaf's NATS address, or null when the boot configuration names none. */
fun leafUrl(property: BootProperty): String? =
    property.read(LEAF_PROPERTY)?.let(::parseLeafAddress)?.let { "nats://$it" }
