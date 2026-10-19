package io.nexussdv.vhalexample.nexusconnector

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LeafAddressTest {
    @Test
    fun `an address and a port are accepted`() {
        assertEquals("192.168.98.5:4222", parseLeafAddress("192.168.98.5:4222"))
        assertEquals("nexus-leaf:4222", parseLeafAddress(" nexus-leaf:4222 \n"))
        assertEquals("h:65535", parseLeafAddress("h:65535"))
    }

    @Test
    fun `anything else is refused`() {
        // The same values the nexus-telemetry-client refuses (core/src/leaf_addr.rs).
        for (bad in listOf("", "192.168.98.5", ":4222", "host:", "host:port", "host:70000", "a b:4222", "nats://h:4222", "h:0", "h:-1", "h:65536")) {
            assertNull(bad, parseLeafAddress(bad))
        }
    }

    @Test
    fun `the leaf is where the boot configuration says, read from ro_boot_nexus_leaf`() {
        val asked = mutableListOf<String>()
        val url = leafUrl { name -> asked += name; "192.168.98.5:4222\n" }
        assertEquals("nats://192.168.98.5:4222", url)
        assertEquals(listOf("ro.boot.nexus.leaf"), asked)
    }

    @Test
    fun `no line, an empty line or a wrong line gives no leaf and nothing else stands in`() {
        assertNull(leafUrl { null })
        assertNull(leafUrl { "" })
        assertNull(leafUrl { "192.168.98.5" })
    }

    @Test
    fun `the reason names the boot configuration line`() {
        assertEquals("no leaf configured for this VM: androidboot.nexus.leaf is not set", NO_LEAF_CONFIGURED)
    }
}
