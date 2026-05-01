package com.factory.memorytest.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Resultado de uma execucao de teste.
 * Snapshot do device armazenado para sobreviver a edicoes/exclusao.
 */
@Entity(
    tableName = "test_runs",
    foreignKeys = [
        ForeignKey(
            entity = DeviceProfileEntity::class,
            parentColumns = ["id"],
            childColumns = ["deviceId"],
            onDelete = ForeignKey.SET_NULL,
        )
    ],
    indices = [Index("deviceId")],
)
data class TestRunEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,

    val deviceId: Long?,                  // pode ficar null se device for excluido
    val deviceNameSnapshot: String,
    val deviceManufacturerSnapshot: String,
    val scriptType: String,                // "FACTORY" ou "DEEP_RAM"
    val serialNo: String = "",
    val operatorName: String = "",

    val startedAt: Long,
    val finishedAt: Long? = null,
    val durationMs: Long? = null,

    val result: String,                    // PASS / FAIL / ABORTED / RUNNING
    val exitCode: Int? = null,
    val logFilePath: String? = null,
    val failReasons: String = "",
)
