package com.factory.memorytest.ui.devicedetail

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.viewModelScope
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivityDeviceDetailBinding
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.ScriptType
import com.factory.memorytest.ui.deviceedit.DeviceEditActivity
import com.factory.memorytest.ui.history.HistoryActivity
import com.factory.memorytest.ui.testrun.TestRunActivity
import kotlinx.coroutines.launch

class DeviceDetailActivity : AppCompatActivity() {

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"
        fun intent(ctx: Context, id: Long) =
            Intent(ctx, DeviceDetailActivity::class.java).putExtra(EXTRA_DEVICE_ID, id)
    }

    private lateinit var binding: ActivityDeviceDetailBinding
    private val vm: DeviceDetailViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityDeviceDetailBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.toolbar.setNavigationOnClickListener { finish() }

        val deviceId = intent.getLongExtra(EXTRA_DEVICE_ID, 0L)

        binding.toolbar.setOnMenuItemClickListener { mi ->
            val current = vm.profile.value ?: return@setOnMenuItemClickListener false
            when (mi.itemId) {
                R.id.action_edit -> {
                    startActivity(DeviceEditActivity.editIntent(this, current.id))
                    true
                }
                R.id.action_duplicate -> {
                    vm.duplicate(current)
                    finish()
                    true
                }
                R.id.action_delete -> {
                    confirmDelete(current)
                    true
                }
                else -> false
            }
        }

        vm.loadProfile(deviceId).observe(this) { profile ->
            if (profile == null) {
                finish(); return@observe
            }
            renderProfile(profile)
        }

        binding.btnRunFactory.setOnClickListener {
            vm.profile.value?.let { startActivity(TestRunActivity.intent(this, it.id, ScriptType.FACTORY)) }
        }
        binding.btnRunDeep.setOnClickListener {
            vm.profile.value?.let { startActivity(TestRunActivity.intent(this, it.id, ScriptType.DEEP_RAM)) }
        }
        binding.btnHistory.setOnClickListener {
            vm.profile.value?.let { startActivity(HistoryActivity.intent(this, it.id)) }
        }
    }

    private fun renderProfile(profile: DeviceProfile) {
        binding.toolbar.title = profile.name
        binding.tvName.text = profile.name
        binding.tvManufacturer.text = profile.manufacturer.ifBlank { "—" }
        binding.chipRam.text = "${profile.expectedRamGb} GB RAM"
        binding.chipStorage.text = "${profile.expectedStorageGb} GB · ${profile.storageClass.displayName}"

        renderRows(binding.storageRows, listOf(
            "MIN_WRITE_MBPS" to "${profile.minWriteMbps} MB/s",
            "MIN_READ_MBPS" to "${profile.minReadMbps} MB/s",
            "STORAGE_TEST_SIZE_MB" to "${profile.storageTestSizeMb} MB",
        ))
        renderRows(binding.quickRows, listOf(
            "QUICK_MEMTEST_PERCENT" to "${profile.quickMemtestPercent} %",
            "QUICK_MEMTEST_MAX_MB" to "${profile.quickMemtestMaxMb} MB",
            "QUICK_MEMTEST_MIN_MB" to "${profile.quickMemtestMinMb} MB",
            "QUICK_MEMTEST_LOOPS" to "${profile.quickMemtestLoops}",
            "QUICK_MEMTEST_TIMEOUT_S" to "${profile.quickMemtestTimeoutS} s",
        ))
        renderRows(binding.deepRows, listOf(
            "MEMTEST_PERCENT" to "${profile.deepMemtestPercent} %",
            "MEMTEST_MAX_MB" to "${profile.deepMemtestMaxMb} MB",
            "MEMTEST_LOOPS" to "${profile.deepMemtestLoops}",
            "MEMTEST_TIMEOUT_S" to "${profile.deepMemtestTimeoutS} s",
            "MIN_MEMTEST_MB" to "${profile.deepMemtestMinMb} MB",
        ))
    }

    private fun renderRows(parent: LinearLayout, rows: List<Pair<String, String>>) {
        parent.removeAllViews()
        val inflater = LayoutInflater.from(this)
        rows.forEachIndexed { idx, (key, value) ->
            val view = inflater.inflate(R.layout.row_kv, parent, false)
            view.findViewById<TextView>(R.id.tvKey).text = key
            view.findViewById<TextView>(R.id.tvValue).text = value
            view.findViewById<View>(R.id.divider).visibility =
                if (idx == rows.lastIndex) View.GONE else View.VISIBLE
            parent.addView(view)
        }
    }

    private fun confirmDelete(profile: DeviceProfile) {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_delete_title)
            .setMessage(getString(R.string.dialog_delete_message) + "\n\n${profile.name}")
            .setPositiveButton(R.string.action_delete) { _, _ ->
                vm.delete(profile)
                finish()
            }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }
}

class DeviceDetailViewModel(app: android.app.Application) : AndroidViewModel(app) {
    private val repo = (app as MemoryTestApp).deviceRepo

    private var liveProfile: LiveData<DeviceProfile?>? = null
    val profile: LiveData<DeviceProfile?>
        get() = liveProfile ?: error("loadProfile() must be called first")

    fun loadProfile(id: Long): LiveData<DeviceProfile?> {
        val live = liveProfile
        if (live != null) return live
        val newLive = repo.observeById(id)
        liveProfile = newLive
        return newLive
    }

    fun duplicate(profile: DeviceProfile) {
        viewModelScope.launch {
            repo.upsert(profile.copy(id = 0L, name = "${profile.name} (cópia)"))
        }
    }

    fun delete(profile: DeviceProfile) {
        viewModelScope.launch { repo.delete(profile) }
    }
}
