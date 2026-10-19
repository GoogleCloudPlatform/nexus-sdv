package io.nexussdv.vhalexample

import android.os.Bundle
import android.view.Menu
import android.view.MenuItem
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.SimpleItemAnimator
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {
    private val scope = MainScope()
    private val timeFormat = DateFormat.getTimeInstance()
    private lateinit var adapter: VhalPropertyAdapter
    private var propertyCount: MenuItem? = null
    private var toggleSending: MenuItem? = null
    private var refreshJob: Job? = null
    private var listed = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContentView(R.layout.activity_main)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.main)) { v, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom)
            insets
        }

        VhalWrapper.init(this)
        adapter = VhalPropertyAdapter(SelectionStore.get(this)) { SelectionStore.save(this) }
        findViewById<RecyclerView>(R.id.vhalPropertiesRecyclerView).apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = this@MainActivity.adapter
            // The values change every few seconds; a row must not flash each time.
            (itemAnimator as SimpleItemAnimator).supportsChangeAnimations = false
        }

        // The read permissions a user grants; the answer comes back in onRequestPermissionsResult.
        requestPermissions(RUNTIME_PERMISSIONS, 1)

        VhalExampleService.connect(this)
        val statusText = findViewById<TextView>(R.id.statusLine)
        scope.launch {
            VhalExampleService.state.collect { status ->
                statusText.text = statusLine(status) { timeFormat.format(Date(it)) }
                toggleSending?.setTitle(if (status.sending) R.string.stop_sending else R.string.start_sending)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        reload()
    }

    override fun onStart() {
        super.onStart()
        refreshJob = scope.launch {
            while (isActive) {
                refresh()
                delay(REFRESH_MS)
            }
        }
    }

    override fun onStop() {
        refreshJob?.cancel()
        super.onStop()
    }

    override fun onDestroy() {
        scope.cancel()
        // Keep sending when sending was started; otherwise nothing is left to do.
        if (isFinishing && !VhalExampleService.state.value.sending) VhalExampleService.stop(this)
        super.onDestroy()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.toolbar_menu, menu)
        propertyCount = menu.findItem(R.id.infoAvailableProperties)
        toggleSending = menu.findItem(R.id.actionToggleService)
        if (VhalExampleService.state.value.sending) toggleSending?.setTitle(R.string.stop_sending)
        showCount()
        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        R.id.actionToggleService -> {
            if (VhalExampleService.state.value.sending) {
                VhalExampleService.stopSending(this)
            } else {
                VhalExampleService.startSending(this)
            }
            true
        }
        R.id.actionSendOnce -> {
            VhalExampleService.sendOnce(this)
            true
        }
        R.id.actionReload -> {
            reload()
            true
        }
        R.id.action_select_all -> {
            adapter.toggleAll()
            true
        }
        else -> super.onOptionsItemSelected(item)
    }

    /** Asks the vehicle again which properties there are, then reads them. */
    private fun reload() {
        scope.launch {
            withContext(Dispatchers.IO) { VhalWrapper.reload() }
            refresh()
        }
    }

    /** Reads every listed property and shows the values. */
    private suspend fun refresh() {
        val properties = withContext(Dispatchers.IO) {
            VhalWrapper.getProperties(VhalWrapper.listedIds()).sortedBy { it.name }
        }
        adapter.updateProperties(properties)
        listed = properties.size
        showCount()
    }

    private fun showCount() {
        propertyCount?.title = getString(R.string.available_properties, listed)
    }

    companion object {
        private const val REFRESH_MS = 2000L

        private val RUNTIME_PERMISSIONS = arrayOf(
            "android.car.permission.CAR_SPEED",
            "android.car.permission.CAR_ENERGY",
            "android.car.permission.CAR_MILEAGE_3P",
            "android.car.permission.CAR_ENGINE_DETAILED_3P",
            "android.car.permission.CAR_TIRES_3P",
            "android.car.permission.READ_CAR_STEERING_3P",
            "android.car.permission.READ_WINDSHIELD_WIPERS_3P",
            "android.permission.POST_NOTIFICATIONS",
        )
    }
}
