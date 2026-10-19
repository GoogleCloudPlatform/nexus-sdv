package io.nexussdv.vhalexample

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SelectionTest {
    @Test
    fun `at first start speed, gear and fuel level are ticked`() {
        // android.car.VehiclePropertyIds: PERF_VEHICLE_SPEED, GEAR_SELECTION, FUEL_LEVEL.
        // No door property: reading one needs a permission that controls the doors.
        assertEquals(setOf(291504647, 289408000, 291504903), Selection(stored = null).ticked)
    }

    @Test
    fun `a stored selection replaces the first-start one, an empty one too`() {
        assertEquals(setOf(7), Selection(stored = setOf(7)).ticked)
        assertEquals(emptySet<Int>(), Selection(stored = emptySet()).ticked)
    }

    @Test
    fun `ticking and unticking one property leaves the others`() {
        val s = Selection(stored = setOf(1, 2))
        s.set(3, true)
        s.set(1, false)
        assertEquals(setOf(2, 3), s.ticked)
        assertTrue(s.isTicked(3))
        assertFalse(s.isTicked(1))
    }

    @Test
    fun `toggle all ticks everything, and unticks everything once all are ticked`() {
        val s = Selection(stored = setOf(1))
        s.toggleAll(listOf(1, 2, 3))
        assertEquals(setOf(1, 2, 3), s.ticked)
        s.toggleAll(listOf(1, 2, 3))
        assertEquals(emptySet<Int>(), s.ticked)
    }
}
