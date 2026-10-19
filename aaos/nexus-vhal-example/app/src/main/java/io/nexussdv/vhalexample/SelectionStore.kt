package io.nexussdv.vhalexample

import android.content.Context

/** Keeps the selection across starts of the app. One selection per process: screen and service share it. */
object SelectionStore {
    private const val PREFERENCES = "selection"
    private const val KEY = "ticked"
    private var selection: Selection? = null

    @Synchronized
    fun get(context: Context): Selection =
        selection ?: Selection(
            preferences(context).getStringSet(KEY, null)?.map { it.toInt() }?.toSet()
        ).also { selection = it }

    fun save(context: Context) {
        val ticked = get(context).ticked.map { it.toString() }.toSet()
        preferences(context).edit().putStringSet(KEY, ticked).apply()
    }

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}
