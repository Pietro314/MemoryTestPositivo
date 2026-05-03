package com.factory.memorytest

import android.app.Application
import com.factory.memorytest.data.db.AppDatabase
import com.factory.memorytest.data.repo.DeviceRepository
import com.factory.memorytest.data.repo.TestRunRepository
import com.factory.memorytest.domain.DefaultDeviceProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Application root. Mantem um Service Locator simples para
 * Repositories — evita Hilt/Dagger sem necessidade neste app.
 */
class MemoryTestApp : Application() {

    private lateinit var db: AppDatabase
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val deviceRepo: DeviceRepository by lazy { DeviceRepository(db.deviceProfileDao()) }
    val runRepo: TestRunRepository by lazy {
        TestRunRepository(db.testRunDao(), db.testStepDao())
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        db = AppDatabase.get(this)
        seedDefaultDeviceIfMissing()
    }

    private fun seedDefaultDeviceIfMissing() {
        appScope.launch {
            val existing = deviceRepo.findByMarker(
                DefaultDeviceProfile.NAME, DefaultDeviceProfile.MODEL_CODE
            )
            if (existing == null) {
                deviceRepo.upsert(DefaultDeviceProfile.build())
            }
        }
    }

    companion object {
        lateinit var instance: MemoryTestApp
            private set
    }
}
