package com.factory.memorytest.ui.devicelist

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.lifecycle.viewModelScope
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.domain.DeviceProfile
import kotlinx.coroutines.launch

class DeviceListViewModel(app: Application) : AndroidViewModel(app) {

    private val repo = (app as MemoryTestApp).deviceRepo

    val devices: LiveData<List<DeviceProfile>> = repo.observeAll()

    fun delete(profile: DeviceProfile) {
        viewModelScope.launch { repo.delete(profile) }
    }

    fun duplicate(profile: DeviceProfile) {
        viewModelScope.launch {
            repo.upsert(
                profile.copy(
                    id = 0L,
                    name = "${profile.name} (cópia)",
                )
            )
        }
    }
}
