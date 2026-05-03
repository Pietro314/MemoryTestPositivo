package com.factory.memorytest.data.repo

import androidx.lifecycle.LiveData
import androidx.lifecycle.map
import com.factory.memorytest.data.db.DeviceProfileDao
import com.factory.memorytest.domain.DeviceProfile

class DeviceRepository(private val dao: DeviceProfileDao) {

    fun observeAll(): LiveData<List<DeviceProfile>> =
        dao.observeAll().map { list -> list.map { DeviceProfile.fromEntity(it) } }

    fun observeById(id: Long): LiveData<DeviceProfile?> =
        dao.observeById(id).map { it?.let(DeviceProfile::fromEntity) }

    suspend fun findById(id: Long): DeviceProfile? =
        dao.findById(id)?.let(DeviceProfile::fromEntity)

    suspend fun count(): Int = dao.count()

    suspend fun similarByRam(ramGb: Int, excludeId: Long = -1L): List<DeviceProfile> =
        dao.similarByRam(ramGb, excludeId).map(DeviceProfile::fromEntity)

    suspend fun findByMarker(name: String, modelCode: String): DeviceProfile? =
        dao.findByMarker(name, modelCode)?.let(DeviceProfile::fromEntity)

    suspend fun upsert(profile: DeviceProfile): Long {
        val now = System.currentTimeMillis()
        val toSave = profile.copy(updatedAt = now)
        return if (toSave.id == 0L) {
            dao.insert(toSave.copy(createdAt = now).toEntity())
        } else {
            dao.update(toSave.toEntity())
            toSave.id
        }
    }

    suspend fun delete(profile: DeviceProfile) {
        if (profile.isDefaultEmbedded) return
        dao.delete(profile.toEntity())
    }

    suspend fun deleteById(id: Long) {
        val existing = dao.findById(id) ?: return
        if (DeviceProfile.fromEntity(existing).isDefaultEmbedded) return
        dao.deleteById(id)
    }
}
