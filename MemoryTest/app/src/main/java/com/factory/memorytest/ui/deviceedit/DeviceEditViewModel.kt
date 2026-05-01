package com.factory.memorytest.ui.deviceedit

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.viewModelScope
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.RamPresets
import com.factory.memorytest.domain.StorageClass
import kotlinx.coroutines.launch

class DeviceEditViewModel(app: Application) : AndroidViewModel(app) {

    private val repo = (app as MemoryTestApp).deviceRepo

    val current = MutableLiveData<DeviceProfile?>(null)

    val similarDevices = MutableLiveData<List<DeviceProfile>>(emptyList())

    private var loadedId: Long = 0L

    fun load(id: Long) {
        loadedId = id
        if (id == 0L) {
            // Novo device: tudo zerado. Os campos sao preenchidos quando o
            // usuario escolhe a RAM e a classe de storage.
            current.value = DeviceProfile(
                name = "",
                manufacturer = "",
                expectedRamGb = 0,
                expectedStorageGb = 0,
                storageClass = StorageClass.CUSTOM,
                minWriteMbps = 0,
                minReadMbps = 0,
                storageTestSizeMb = 0,
                quickMemtestPercent = 0,
                quickMemtestMaxMb = 0,
                quickMemtestMinMb = 0,
                quickMemtestLoops = 0,
                quickMemtestTimeoutS = 0,
                deepMemtestPercent = 0,
                deepMemtestMaxMb = 0,
                deepMemtestLoops = 0,
                deepMemtestTimeoutS = 0,
                deepMemtestMinMb = 0,
            )
        } else {
            viewModelScope.launch {
                current.value = repo.findById(id)
            }
        }
    }

    /** Indica que o usuario ainda nao escolheu RAM (estado "vazio"). */
    fun isRamUnselected(profile: DeviceProfile): Boolean = profile.expectedRamGb <= 0

    /** Indica que o usuario ainda nao escolheu Storage Class real. */
    fun isStorageClassUnselected(profile: DeviceProfile): Boolean =
        profile.storageClass == StorageClass.CUSTOM &&
            profile.minWriteMbps == 0 &&
            profile.minReadMbps == 0 &&
            profile.storageTestSizeMb == 0

    fun applyRamPreset(ramGb: Int) {
        val cur = current.value ?: return
        val ram = RamPresets.forRamGb(ramGb)
        current.value = cur.copy(
            expectedRamGb = ramGb,
            quickMemtestPercent = ram.quickMemtestPercent,
            quickMemtestMaxMb = ram.quickMemtestMaxMb,
            quickMemtestMinMb = ram.quickMemtestMinMb,
            quickMemtestLoops = ram.quickMemtestLoops,
            quickMemtestTimeoutS = ram.quickMemtestTimeoutS,
            deepMemtestPercent = ram.deepMemtestPercent,
            deepMemtestMaxMb = ram.deepMemtestMaxMb,
            deepMemtestLoops = ram.deepMemtestLoops,
            deepMemtestTimeoutS = ram.deepMemtestTimeoutS,
            deepMemtestMinMb = ram.deepMemtestMinMb,
        )
        refreshSimilar(ramGb)
    }

    fun applyStorageClass(cls: StorageClass) {
        val cur = current.value ?: return
        if (cls == StorageClass.CUSTOM) {
            current.value = cur.copy(storageClass = cls)
            return
        }
        current.value = cur.copy(
            storageClass = cls,
            minWriteMbps = cls.minWriteMbps,
            minReadMbps = cls.minReadMbps,
            storageTestSizeMb = cls.storageTestSizeMb,
        )
    }

    fun applyFullProfile(base: DeviceProfile) {
        val cur = current.value ?: return
        current.value = base.copy(
            id = cur.id,
            name = cur.name,
            manufacturer = cur.manufacturer,
            modelCode = cur.modelCode,
            notes = cur.notes,
            createdAt = cur.createdAt,
        )
    }

    fun update(transform: (DeviceProfile) -> DeviceProfile) {
        val cur = current.value ?: return
        current.value = transform(cur)
    }

    fun refreshSimilar(ramGb: Int) {
        viewModelScope.launch {
            similarDevices.value = repo.similarByRam(ramGb, excludeId = loadedId)
        }
    }

    suspend fun save(profile: DeviceProfile): Long = repo.upsert(profile)
}
