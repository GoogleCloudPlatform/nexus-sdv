package io.nexussdv.vhalexample

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import io.nexussdv.vhalexample.nexusconnector.TelemetryMessageFactory

class VhalPropertyAdapter(
    private val selection: Selection,
    /** Called after a tick was set or removed, so the selection can be stored. */
    private val onSelectionChanged: () -> Unit,
) : RecyclerView.Adapter<VhalPropertyAdapter.PropertyViewHolder>() {
    private var properties = listOf<VhalProperty>()

    fun updateProperties(newProperties: List<VhalProperty>) {
        val diffResult = DiffUtil.calculateDiff(VhalPropertyDiffCallback(properties, newProperties))
        properties = newProperties
        diffResult.dispatchUpdatesTo(this)
    }

    fun toggleAll() {
        selection.toggleAll(properties.map { it.id })
        onSelectionChanged()
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PropertyViewHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.item_vhal_property, parent, false)
        return PropertyViewHolder(view)
    }

    override fun onBindViewHolder(holder: PropertyViewHolder, position: Int) = holder.bind(properties[position])

    override fun getItemCount(): Int = properties.size

    inner class PropertyViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val nameTextView: TextView = itemView.findViewById(R.id.propertyName)
        private val valueTextView: TextView = itemView.findViewById(R.id.propertyValue)
        private val idTextView: TextView = itemView.findViewById(R.id.propertyId)
        private val areaIdTextView: TextView = itemView.findViewById(R.id.areaId)
        private val statusTextView: TextView = itemView.findViewById(R.id.status)
        private val sendCheckBox: CheckBox = itemView.findViewById(R.id.send)

        fun bind(property: VhalProperty) {
            nameTextView.text = property.name
            idTextView.text = "ID: ${property.id}"
            areaIdTextView.text = "Area ID: ${property.areaId}"

            // A reused row still has the listener of the property it showed before.
            sendCheckBox.setOnCheckedChangeListener(null)
            sendCheckBox.isChecked = selection.isTicked(property.id)
            sendCheckBox.setOnCheckedChangeListener { _, isChecked ->
                selection.set(property.id, isChecked)
                onSelectionChanged()
            }

            val context = itemView.context
            val sendable = TelemetryMessageFactory.valueText(property.value)
            when {
                property.error != null -> {
                    valueTextView.text = "not readable"
                    statusTextView.text = "Not readable (${property.error}); not sent."
                    statusTextView.setTextColor(context.getColor(android.R.color.holo_red_dark))
                }
                sendable != null -> {
                    valueTextView.text = sendable
                    statusTextView.text = "Read from the VHAL."
                    statusTextView.setTextColor(context.getColor(android.R.color.holo_green_dark))
                }
                else -> {
                    // No value, or a list of values: shown, but there is no single reading to send.
                    valueTextView.text = when (val value = property.value) {
                        null -> "no value"
                        is Array<*> -> value.joinToString()
                        else -> value.toString()
                    }
                    statusTextView.text = "Read from the VHAL; not a number, boolean or text, not sent."
                    statusTextView.setTextColor(context.getColor(android.R.color.darker_gray))
                }
            }
        }
    }
}

class VhalPropertyDiffCallback(
    private val oldList: List<VhalProperty>,
    private val newList: List<VhalProperty>,
) : DiffUtil.Callback() {
    override fun getOldListSize() = oldList.size
    override fun getNewListSize() = newList.size

    override fun areItemsTheSame(oldPos: Int, newPos: Int): Boolean =
        oldList[oldPos].id == newList[newPos].id && oldList[oldPos].areaId == newList[newPos].areaId

    override fun areContentsTheSame(oldPos: Int, newPos: Int): Boolean {
        val old = oldList[oldPos]
        val new = newList[newPos]
        // Array values have no equals of their own; compare what the row shows.
        return old.error == new.error && shown(old.value) == shown(new.value)
    }

    private fun shown(value: Any?): String? = if (value is Array<*>) value.joinToString() else value?.toString()
}
