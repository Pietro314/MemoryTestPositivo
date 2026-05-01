package com.factory.memorytest.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * Perfil de device cadastrado.
 * Os campos numericos guardam o snapshot do que foi configurado;
 * presets de RAM/Storage Class so existem como ponto de partida.
 */
@Entity(tableName = "device_profiles")
data class DeviceProfileEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0L,

    // Identificacao
    val name: String,
    val manufacturer: String,
    val modelCode: String = "",
    val notes: String = "",

    // Hardware esperado
    val expectedRamGb: Int,
    val expectedStorageGb: Int,
    val storageClassName: String, // StorageClass.name

    // Storage thresholds
    val minWriteMbps: Int,
    val minReadMbps: Int,
    val storageTestSizeMb: Int,

    // Quick test (full_memtest.sh)
    val quickMemtestPercent: Int,
    val quickMemtestMaxMb: Int,
    val quickMemtestMinMb: Int,
    val quickMemtestLoops: Int,
    val quickMemtestTimeoutS: Int,

    // Deep test (ram_diagnostic_deep_verbose_root_exec.sh)
    val deepMemtestPercent: Int,
    val deepMemtestMaxMb: Int,
    val deepMemtestLoops: Int,
    val deepMemtestTimeoutS: Int,
    val deepMemtestMinMb: Int,

    // Audit
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
)
