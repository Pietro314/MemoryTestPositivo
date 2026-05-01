package com.factory.memorytest.data.db

import androidx.lifecycle.LiveData
import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update

@Dao
interface TestRunDao {

    @Query("SELECT * FROM test_runs ORDER BY startedAt DESC")
    fun observeAll(): LiveData<List<TestRunEntity>>

    @Query("SELECT * FROM test_runs WHERE deviceId = :deviceId ORDER BY startedAt DESC")
    fun observeByDevice(deviceId: Long): LiveData<List<TestRunEntity>>

    @Query("SELECT * FROM test_runs WHERE id = :id")
    suspend fun findById(id: Long): TestRunEntity?

    @Query("SELECT * FROM test_runs WHERE id = :id")
    fun observeById(id: Long): LiveData<TestRunEntity?>

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insert(entity: TestRunEntity): Long

    @Update
    suspend fun update(entity: TestRunEntity)

    @Query("DELETE FROM test_runs WHERE id = :id")
    suspend fun deleteById(id: Long)
}
