package io.nexussdv.vhalexample

import org.junit.Assert.assertEquals
import org.junit.Test

class LinkStatusTest {
    private val clock: (Long) -> String = { "14:03:22" }

    @Test
    fun `before anything is known the line says so and invents nothing`() {
        assertEquals(
            "Leaf: searching · VIN: not known · Sent: 0 · Last: never",
            statusLine(LinkStatus(), clock),
        )
    }

    @Test
    fun `a reachable leaf with VIN, count and time of the last message`() {
        val status = LinkStatus(leaf = LeafState.REACHABLE, vin = "PKG11MESH01", sent = 12, lastSentMillis = 1L)
        assertEquals(
            "Leaf: reachable · VIN: PKG11MESH01 · Sent: 12 · Last: 14:03:22",
            statusLine(status, clock),
        )
    }

    @Test
    fun `a lost leaf is named with its reason, the count stays`() {
        val status = LinkStatus(leaf = LeafState.NOT_REACHABLE, detail = "connection refused", sent = 12, lastSentMillis = 1L)
        assertEquals(
            "Leaf: not reachable (connection refused) · VIN: not known · Sent: 12 · Last: 14:03:22",
            statusLine(status, clock),
        )
    }
}
