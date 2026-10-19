package io.nexussdv.vhalexample

import android.car.Car
import android.car.VehiclePropertyIds
import android.car.hardware.CarPropertyConfig
import android.car.hardware.property.CarPropertyManager
import android.content.Context
import android.util.Log

/** Reads the VHAL through the Car API. It reads only; nothing here writes a property. */
object VhalWrapper {
    private const val TAG = "VhalWrapper"
    private var manager: CarPropertyManager? = null

    @Volatile
    private var configs: Map<Int, CarPropertyConfig<*>> = emptyMap()

    @Synchronized
    fun init(context: Context) {
        if (manager != null) return
        try {
            val car = Car.createCar(context.applicationContext)
            manager = car.getCarManager(Car.PROPERTY_SERVICE) as CarPropertyManager
            reload()
        } catch (e: Exception) {
            Log.w(TAG, "Car API not available: ${e.message}")
        }
    }

    /** Asks the vehicle again which properties this app may see, e.g. after a permission was granted. */
    fun reload() {
        val manager = manager ?: return
        configs = try {
            manager.propertyList.associateBy { it.propertyId }
        } catch (e: Exception) {
            Log.w(TAG, "property list not available: ${e.message}")
            emptyMap()
        }
    }

    /** The properties the screen lists: what the vehicle lets this app see. */
    fun listedIds(): List<Int> = configs.keys.toList()

    fun getProperties(ids: Collection<Int>): List<VhalProperty> = ids.map { getProperty(it) }

    /** Reads the property in its first area. A failed read gives a property with an error and no value. */
    fun getProperty(id: Int): VhalProperty {
        val name = VehiclePropertyIds.toString(id)
        val config = configs[id]
        val areaId = config?.areaIds?.firstOrNull() ?: 0
        val manager = manager
        if (manager == null || config == null) {
            return VhalProperty(id, areaId, name, error = "not offered to this app")
        }
        return try {
            VhalProperty(
                id = id,
                areaId = areaId,
                name = name,
                value = manager.getProperty<Any>(id, areaId)?.value,
                static = config.changeMode == CarPropertyConfig.VEHICLE_PROPERTY_CHANGE_MODE_STATIC,
            )
        } catch (e: Exception) {
            VhalProperty(id, areaId, name, error = e.javaClass.simpleName)
        }
    }
}
