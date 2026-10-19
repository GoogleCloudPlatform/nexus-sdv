package io.nexussdv.vhalexample

/**
 * Which properties are ticked. What is ticked is what is sent, and nothing else.
 * [stored] is the selection kept from an earlier start, or null at the first start.
 */
class Selection(stored: Set<Int>?) {
    @Volatile
    var ticked: Set<Int> = stored ?: FIRST_START
        private set

    fun isTicked(id: Int): Boolean = id in ticked

    @Synchronized
    fun set(id: Int, ticked: Boolean) {
        this.ticked = if (ticked) this.ticked + id else this.ticked - id
    }

    /** Ticks every property of [ids]; unticks them all when all are ticked already. */
    @Synchronized
    fun toggleAll(ids: Collection<Int>) {
        ticked = if (ticked.containsAll(ids)) ticked - ids.toSet() else ticked + ids
    }

    companion object {
        // android.car.VehiclePropertyIds, as numbers so this class needs no Android runtime.
        const val PERF_VEHICLE_SPEED = 291504647
        const val GEAR_SELECTION = 289408000
        const val FUEL_LEVEL = 291504903

        val FIRST_START = setOf(PERF_VEHICLE_SPEED, GEAR_SELECTION, FUEL_LEVEL)
    }
}
