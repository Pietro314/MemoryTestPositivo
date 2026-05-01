package com.factory.memorytest

import android.app.Application
import com.factory.memorytest.data.db.AppDatabase
import com.factory.memorytest.data.repo.DeviceRepository
import com.factory.memorytest.data.repo.TestRunRepository

/**
 * Application root. Mantem um Service Locator simples para
 * Repositories — evita Hilt/Dagger sem necessidade neste app.
 */
class MemoryTestApp : Application() {

    private lateinit var db: AppDatabase

    val deviceRepo: DeviceRepository by lazy { DeviceRepository(db.deviceProfileDao()) }
    val runRepo: TestRunRepository by lazy {
        TestRunRepository(db.testRunDao(), db.testStepDao())
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        db = AppDatabase.get(this)
    }

    companion object {
        lateinit var instance: MemoryTestApp
            private set
    }
}
