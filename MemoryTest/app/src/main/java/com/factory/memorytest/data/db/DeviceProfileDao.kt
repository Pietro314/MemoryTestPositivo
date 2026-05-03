package com.factory.memorytest.data.db

import androidx.lifecycle.LiveData
import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update

@Dao
interface DeviceProfileDao {

    @Query("SELECT * FROM device_profiles ORDER BY name COLLATE NOCASE ASC")
    fun observeAll(): LiveData<List<DeviceProfileEntity>>

    @Query("SELECT * FROM device_profiles WHERE id = :id")
    suspend fun findById(id: Long): DeviceProfileEntity?

    @Query("SELECT * FROM device_profiles WHERE id = :id")
    fun observeById(id: Long): LiveData<DeviceProfileEntity?>

    @Query("SELECT * FROM device_profiles WHERE expectedRamGb = :ramGb AND id != :excludeId ORDER BY updatedAt DESC")
    suspend fun similarByRam(ramGb: Int, excludeId: Long = -1L): List<DeviceProfileEntity>

    @Query("SELECT * FROM device_profiles WHERE name = :name AND modelCode = :modelCode LIMIT 1")
    suspend fun findByMarker(name: String, modelCode: String): DeviceProfileEntity?

    @Query("SELECT COUNT(*) FROM device_profiles")
    suspend fun count(): Int

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entity: DeviceProfileEntity): Long

    @Update
    suspend fun update(entity: DeviceProfileEntity)

    @Delete
    suspend fun delete(entity: DeviceProfileEntity)

    @Query("DELETE FROM device_profiles WHERE id = :id")
    suspend fun deleteById(id: Long)
}
