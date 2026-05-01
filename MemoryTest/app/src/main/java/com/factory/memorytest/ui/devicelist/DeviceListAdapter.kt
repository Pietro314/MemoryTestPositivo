package com.factory.memorytest.ui.devicelist

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.PopupMenu
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ItemDeviceCardBinding
import com.factory.memorytest.domain.DeviceProfile

class DeviceListAdapter(
    private val onClick: (DeviceProfile) -> Unit,
    private val onMenuAction: (DeviceProfile, MenuAction) -> Unit,
) : ListAdapter<DeviceProfile, DeviceListAdapter.VH>(DIFF) {

    enum class MenuAction { EDIT, DUPLICATE, DELETE }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val b = ItemDeviceCardBinding.inflate(
            LayoutInflater.from(parent.context), parent, false
        )
        return VH(b)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.bind(getItem(position))
    }

    inner class VH(private val b: ItemDeviceCardBinding) : RecyclerView.ViewHolder(b.root) {
        fun bind(item: DeviceProfile) {
            b.tvName.text = item.name
            b.tvManufacturer.text = item.manufacturer.ifBlank { "—" }
            b.chipRam.text = "${item.expectedRamGb} GB RAM"
            b.chipStorage.text = "${item.expectedStorageGb} GB · ${item.storageClass.displayName}"
            b.root.setOnClickListener { onClick(item) }
            b.btnMore.setOnClickListener { v -> showMenu(v, item) }
        }

        private fun showMenu(anchor: View, item: DeviceProfile) {
            val popup = PopupMenu(anchor.context, anchor)
            popup.menuInflater.inflate(R.menu.menu_device_card, popup.menu)
            popup.setOnMenuItemClickListener { mi ->
                val action = when (mi.itemId) {
                    R.id.action_edit -> MenuAction.EDIT
                    R.id.action_duplicate -> MenuAction.DUPLICATE
                    R.id.action_delete -> MenuAction.DELETE
                    else -> return@setOnMenuItemClickListener false
                }
                onMenuAction(item, action)
                true
            }
            popup.show()
        }
    }

    companion object {
        private val DIFF = object : DiffUtil.ItemCallback<DeviceProfile>() {
            override fun areItemsTheSame(o: DeviceProfile, n: DeviceProfile) = o.id == n.id
            override fun areContentsTheSame(o: DeviceProfile, n: DeviceProfile) = o == n
        }
    }
}
