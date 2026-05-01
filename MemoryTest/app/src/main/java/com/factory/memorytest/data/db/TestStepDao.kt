package com.factory.memorytest.data.db

import androidx.lifecycle.LiveData
import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update

@Dao
interface TestStepDao {

    @Query("SELECT * FROM test_steps WHERE runId = :runId ORDER BY orderIndex ASC")
    fun observeForRun(runId: Long): LiveData<List<TestStepEntity>>

    @Query("SELECT * FROM test_steps WHERE runId = :runId ORDER BY orderIndex ASC")
    suspend fun listForRun(runId: Long): List<TestStepEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: TestStepEntity): Long

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entities: List<TestStepEntity>): List<Long>

    @Update
    suspend fun update(entity: TestStepEntity)

    @Query("DELETE FROM test_steps WHERE runId = :runId")
    suspend fun deleteForRun(runId: Long)
}
