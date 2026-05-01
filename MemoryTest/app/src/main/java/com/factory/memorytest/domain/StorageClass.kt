package com.factory.memorytest.domain

/**
 * Classes de storage suportadas. Define os limiares de PASS/FAIL de I/O.
 * Calibrado em ~50% do nominal: pega NAND defeituosa sem rejeitar variacao normal.
 */
enum class StorageClass(
    val displayName: String,
    val minWriteMbps: Int,
    val minReadMbps: Int,
    val storageTestSizeMb: Int,
) {
    EMMC_ENTRY    ("eMMC entry (≤4.5)",  15,   50,  256),
    EMMC_5_0      ("eMMC 5.0",           30,   80,  256),
    EMMC_5_1      ("eMMC 5.1",           50,  150,  512),
    UFS_2_1       ("UFS 2.1",            80,  300,  512),
    UFS_3_1       ("UFS 3.1",           300,  800, 1024),
    UFS_4_0       ("UFS 4.0",          1200, 2000, 2048),
    CUSTOM        ("Personalizado",      50,  100,  512);

    companion object {
        fun fromNameOrCustom(name: String?): StorageClass =
            values().firstOrNull { it.name == name } ?: CUSTOM
    }
}
