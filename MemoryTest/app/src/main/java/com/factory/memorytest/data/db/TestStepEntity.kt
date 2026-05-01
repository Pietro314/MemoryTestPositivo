package com.factory.memorytest.data.db

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Step (etapa) dentro de um run. Alimenta a UI de cards bonitos
 * com status (PENDING / RUNNING / PASS / FAIL / WARN / SKIP).
 */
@Entity(
    tableName = "test_steps",
    foreignKeys = [
        ForeignKey(
            entity = TestRunEntity::class,
            parentColumns = ["id"],
            childColumns = ["runId"],
            onDelete = ForeignKey.CASCADE,
        )
    ],
    indices = [Index("runId")],
)
data class TestStepEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,

    val runId: Long,
    val stepKey: String,           // ex: device_id, storage_info, storage_test...
    val stepLabel: String,         // ex: "Velocidade do storage"
    val status: String,            // PENDING / RUNNING / PASS / FAIL / WARN / SKIP
    val summary: String = "",      // breve, ex: "Write 84 MB/s, Read 142 MB/s"
    val details: String = "",      // texto longo (mensagens FAIL, etc.)
    val orderIndex: Int = 0,

    val startedAt: Long? = null,
    val finishedAt: Long? = null,
)
