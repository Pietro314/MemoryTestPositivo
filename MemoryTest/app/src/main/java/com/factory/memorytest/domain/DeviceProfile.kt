package com.factory.memorytest.domain

import com.factory.memorytest.data.db.DeviceProfileEntity

/**
 * Modelo de dominio: device profile usado pela UI.
 * Espelha a entidade Room mas evita acoplamento direto.
 */
data class DeviceProfile(
    val id: Long = 0L,
    val name: String,
    val manufacturer: String,
    val modelCode: String = "",
    val notes: String = "",

    val expectedRamGb: Int,
    val expectedStorageGb: Int,
    val storageClass: StorageClass,

    val minWriteMbps: Int,
    val minReadMbps: Int,
    val storageTestSizeMb: Int,

    val quickMemtestPercent: Int,
    val quickMemtestMaxMb: Int,
    val quickMemtestMinMb: Int,
    val quickMemtestLoops: Int,
    val quickMemtestTimeoutS: Int,

    val deepMemtestPercent: Int,
    val deepMemtestMaxMb: Int,
    val deepMemtestLoops: Int,
    val deepMemtestTimeoutS: Int,
    val deepMemtestMinMb: Int,

    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
) {
    val displayName: String
        get() = if (manufacturer.isBlank()) name else "$name — $manufacturer"

    fun toEntity(): DeviceProfileEntity = DeviceProfileEntity(
        id = id,
        name = name,
        manufacturer = manufacturer,
        modelCode = modelCode,
        notes = notes,
        expectedRamGb = expectedRamGb,
        expectedStorageGb = expectedStorageGb,
        storageClassName = storageClass.name,
        minWriteMbps = minWriteMbps,
        minReadMbps = minReadMbps,
        storageTestSizeMb = storageTestSizeMb,
        quickMemtestPercent = quickMemtestPercent,
        quickMemtestMaxMb = quickMemtestMaxMb,
        quickMemtestMinMb = quickMemtestMinMb,
        quickMemtestLoops = quickMemtestLoops,
        quickMemtestTimeoutS = quickMemtestTimeoutS,
        deepMemtestPercent = deepMemtestPercent,
        deepMemtestMaxMb = deepMemtestMaxMb,
        deepMemtestLoops = deepMemtestLoops,
        deepMemtestTimeoutS = deepMemtestTimeoutS,
        deepMemtestMinMb = deepMemtestMinMb,
        createdAt = createdAt,
        updatedAt = updatedAt,
    )

    companion object {
        fun fromEntity(e: DeviceProfileEntity) = DeviceProfile(
            id = e.id,
            name = e.name,
            manufacturer = e.manufacturer,
            modelCode = e.modelCode,
            notes = e.notes,
            expectedRamGb = e.expectedRamGb,
            expectedStorageGb = e.expectedStorageGb,
            storageClass = StorageClass.fromNameOrCustom(e.storageClassName),
            minWriteMbps = e.minWriteMbps,
            minReadMbps = e.minReadMbps,
            storageTestSizeMb = e.storageTestSizeMb,
            quickMemtestPercent = e.quickMemtestPercent,
            quickMemtestMaxMb = e.quickMemtestMaxMb,
            quickMemtestMinMb = e.quickMemtestMinMb,
            quickMemtestLoops = e.quickMemtestLoops,
            quickMemtestTimeoutS = e.quickMemtestTimeoutS,
            deepMemtestPercent = e.deepMemtestPercent,
            deepMemtestMaxMb = e.deepMemtestMaxMb,
            deepMemtestLoops = e.deepMemtestLoops,
            deepMemtestTimeoutS = e.deepMemtestTimeoutS,
            deepMemtestMinMb = e.deepMemtestMinMb,
            createdAt = e.createdAt,
            updatedAt = e.updatedAt,
        )

        /**
         * Constroi um perfil novo a partir de presets de RAM e Storage Class.
         * Util para o fluxo "novo device" da UI.
         */
        fun fromPresets(
            name: String = "",
            manufacturer: String = "",
            ramGb: Int,
            storageGb: Int,
            storageClass: StorageClass,
        ): DeviceProfile {
            val ram = RamPresets.forRamGb(ramGb)
            return DeviceProfile(
                name = name,
                manufacturer = manufacturer,
                expectedRamGb = ramGb,
                expectedStorageGb = storageGb,
                storageClass = storageClass,
                minWriteMbps = storageClass.minWriteMbps,
                minReadMbps = storageClass.minReadMbps,
                storageTestSizeMb = storageClass.storageTestSizeMb,
                quickMemtestPercent = ram.quickMemtestPercent,
                quickMemtestMaxMb = ram.quickMemtestMaxMb,
                quickMemtestMinMb = ram.quickMemtestMinMb,
                quickMemtestLoops = ram.quickMemtestLoops,
                quickMemtestTimeoutS = ram.quickMemtestTimeoutS,
                deepMemtestPercent = ram.deepMemtestPercent,
                deepMemtestMaxMb = ram.deepMemtestMaxMb,
                deepMemtestLoops = ram.deepMemtestLoops,
                deepMemtestTimeoutS = ram.deepMemtestTimeoutS,
                deepMemtestMinMb = ram.deepMemtestMinMb,
            )
        }
    }
}
