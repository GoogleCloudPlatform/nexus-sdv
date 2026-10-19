package io.nexussdv.vhalexample

import io.nexussdv.vhalexample.nexusconnector.BootProperty
import java.util.concurrent.TimeUnit

/**
 * Reads a system property with `getprop`: Android has no public call for it, and this
 * app uses no hidden one.
 */
object GetpropBootProperty : BootProperty {
    override fun read(name: String): String? = try {
        val process = ProcessBuilder("/system/bin/getprop", name).redirectErrorStream(true).start()
        if (process.waitFor(2, TimeUnit.SECONDS)) {
            process.inputStream.bufferedReader().readText()
        } else {
            process.destroy()
            null
        }
    } catch (e: Exception) {
        null
    }
}
