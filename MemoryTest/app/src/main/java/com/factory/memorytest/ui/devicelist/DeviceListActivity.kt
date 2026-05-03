package com.factory.memorytest.ui.devicelist

import android.content.Intent
import android.os.Bundle
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivityDeviceListBinding
import com.factory.memorytest.ui.deviceedit.DeviceEditActivity
import com.factory.memorytest.ui.devicedetail.DeviceDetailActivity
import com.factory.memorytest.ui.history.HistoryActivity

class DeviceListActivity : AppCompatActivity() {

    private lateinit var binding: ActivityDeviceListBinding
    private val vm: DeviceListViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityDeviceListBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val adapter = DeviceListAdapter(
            onClick = { profile ->
                startActivity(DeviceDetailActivity.intent(this, profile.id))
            },
            onMenuAction = { profile, action ->
                when (action) {
                    DeviceListAdapter.MenuAction.EDIT -> {
                        startActivity(DeviceEditActivity.editIntent(this, profile.id))
                    }
                    DeviceListAdapter.MenuAction.DUPLICATE -> vm.duplicate(profile)
                    DeviceListAdapter.MenuAction.DELETE -> confirmDelete(profile.id, profile.name) {
                        vm.delete(profile)
                    }
                }
            }
        )

        binding.rvDevices.layoutManager = LinearLayoutManager(this)
        binding.rvDevices.adapter = adapter

        binding.toolbar.setNavigationOnClickListener { finish() }

        binding.fabAdd.setOnClickListener {
            startActivity(DeviceEditActivity.newIntent(this))
        }

        binding.toolbar.setOnMenuItemClickListener { mi ->
            when (mi.itemId) {
                R.id.action_history -> {
                    startActivity(Intent(this, HistoryActivity::class.java))
                    true
                }
                else -> false
            }
        }

        vm.devices.observe(this) { list ->
            adapter.submitList(list)
            binding.emptyView.visibility =
                if (list.isEmpty()) android.view.View.VISIBLE else android.view.View.GONE
            binding.rvDevices.visibility =
                if (list.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE
        }
    }

    private fun confirmDelete(id: Long, name: String, onConfirm: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_delete_title)
            .setMessage(getString(R.string.dialog_delete_message) + "\n\n$name")
            .setPositiveButton(R.string.action_delete) { _, _ -> onConfirm() }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }
}
