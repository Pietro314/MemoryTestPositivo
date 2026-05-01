package com.factory.memorytest.data.repo

import androidx.lifecycle.LiveData
import com.factory.memorytest.data.db.TestRunDao
import com.factory.memorytest.data.db.TestRunEntity
import com.factory.memorytest.data.db.TestStepDao
import com.factory.memorytest.data.db.TestStepEntity

class TestRunRepository(
    private val runDao: TestRunDao,
    private val stepDao: TestStepDao,
) {
    fun observeAll(): LiveData<List<TestRunEntity>> = runDao.observeAll()

    fun observeByDevice(deviceId: Long): LiveData<List<TestRunEntity>> =
        runDao.observeByDevice(deviceId)

    fun observeRun(runId: Long): LiveData<TestRunEntity?> = runDao.observeById(runId)

    fun observeSteps(runId: Long): LiveData<List<TestStepEntity>> = stepDao.observeForRun(runId)

    suspend fun findById(id: Long): TestRunEntity? = runDao.findById(id)

    suspend fun listSteps(runId: Long): List<TestStepEntity> = stepDao.listForRun(runId)

    suspend fun startRun(entity: TestRunEntity): Long = runDao.insert(entity)

    suspend fun updateRun(entity: TestRunEntity) = runDao.update(entity)

    suspend fun upsertStep(step: TestStepEntity): Long = stepDao.insert(step)

    suspend fun upsertSteps(steps: List<TestStepEntity>) = stepDao.insertAll(steps)

    suspend fun updateStep(step: TestStepEntity) = stepDao.update(step)

    suspend fun replaceSteps(runId: Long, steps: List<TestStepEntity>) {
        stepDao.deleteForRun(runId)
        stepDao.insertAll(steps)
    }

    suspend fun deleteRun(runId: Long) = runDao.deleteById(runId)
}
