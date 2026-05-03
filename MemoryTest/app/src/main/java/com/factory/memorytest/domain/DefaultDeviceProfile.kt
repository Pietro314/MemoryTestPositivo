package com.factory.memorytest.domain

/**
 * Perfil "Default" embutido no APK. Usado como fallback do "Teste Default"
 * quando o XML do servidor local nao puder ser baixado, e tambem semeado
 * na base no primeiro start para que apareca como um device cadastrado normal.
 *
 * O par (name, modelCode) funciona como marcador estavel para localizar
 * a linha no Room (ver DeviceProfileDao.findDefault) — nao alterar.
 */
object DefaultDeviceProfile {
    const val NAME: String = "Default(T2070D)"
    const val MODEL_CODE: String = "KMDH6001DA-B422"

    fun build(): DeviceProfile = DeviceProfile(
        name = NAME,
        manufacturer = "Samsung",
        modelCode = MODEL_CODE,
        notes = "Teste default com dados do T2070D",

        expectedRamGb = 4,
        expectedStorageGb = 64,
        storageClass = StorageClass.EMMC_5_1,

        minWriteMbps = 50,
        minReadMbps = 150,
        storageTestSizeMb = 512,

        quickMemtestPercent = 40,
        quickMemtestMaxMb = 512,
        quickMemtestMinMb = 128,
        quickMemtestLoops = 1,
        quickMemtestTimeoutS = 600,

        deepMemtestPercent = 60,
        deepMemtestMaxMb = 4096,
        deepMemtestMinMb = 128,
        deepMemtestLoops = 3,
        deepMemtestTimeoutS = 3000,
    )
}
