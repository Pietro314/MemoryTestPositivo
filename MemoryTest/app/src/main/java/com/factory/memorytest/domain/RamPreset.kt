package com.factory.memorytest.domain

/**
 * Preset de parametros de RAM por capacidade.
 *
 * - Quick (factory test): rapido, ~30-60s, 1 loop, MAX_MB pequeno.
 * - Deep  (diagnostic):   pesado, varios minutos, 2-3 loops, MAX_MB maior.
 *
 * Os MAX sao tetos folgados. O PERCENT eh quem dita a escala real
 * em cada device. PERCENT cai em devices grandes para evitar tempo
 * de teste explodir (memtester eh nao-linear).
 */
data class RamPreset(
    val ramGb: Int,

    // Quick (full_memtest.sh)
    val quickMemtestPercent: Int,
    val quickMemtestMaxMb: Int,
    val quickMemtestMinMb: Int,
    val quickMemtestLoops: Int,
    val quickMemtestTimeoutS: Int,

    // Deep (ram_diagnostic_deep_verbose_root_exec.sh)
    val deepMemtestPercent: Int,
    val deepMemtestMaxMb: Int,
    val deepMemtestLoops: Int,
    val deepMemtestTimeoutS: Int,
    val deepMemtestMinMb: Int,
)

object RamPresets {
    val ALL: List<RamPreset> = listOf(
        RamPreset(
            ramGb = 1,
            quickMemtestPercent = 50, quickMemtestMaxMb = 384,
            quickMemtestMinMb = 64, quickMemtestLoops = 1, quickMemtestTimeoutS = 300,
            deepMemtestPercent = 60, deepMemtestMaxMb = 512,
            deepMemtestLoops = 3, deepMemtestTimeoutS = 1200, deepMemtestMinMb = 64,
        ),
        RamPreset(
            ramGb = 2,
            quickMemtestPercent = 40, quickMemtestMaxMb = 512,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 600,
            deepMemtestPercent = 60, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 3, deepMemtestTimeoutS = 1800, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 3,
            quickMemtestPercent = 40, quickMemtestMaxMb = 512,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 600,
            deepMemtestPercent = 60, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 3, deepMemtestTimeoutS = 2400, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 4,
            quickMemtestPercent = 40, quickMemtestMaxMb = 512,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 600,
            deepMemtestPercent = 60, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 3, deepMemtestTimeoutS = 3000, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 6,
            quickMemtestPercent = 30, quickMemtestMaxMb = 1024,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 900,
            deepMemtestPercent = 50, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 3, deepMemtestTimeoutS = 3600, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 8,
            quickMemtestPercent = 25, quickMemtestMaxMb = 1024,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 900,
            deepMemtestPercent = 45, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 4500, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 10,
            quickMemtestPercent = 22, quickMemtestMaxMb = 2048,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 1100,
            deepMemtestPercent = 40, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 5000, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 12,
            quickMemtestPercent = 20, quickMemtestMaxMb = 2048,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 1200,
            deepMemtestPercent = 35, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 5400, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 16,
            quickMemtestPercent = 15, quickMemtestMaxMb = 2048,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 1200,
            deepMemtestPercent = 30, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 7200, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 18,
            quickMemtestPercent = 13, quickMemtestMaxMb = 2048,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 1300,
            deepMemtestPercent = 28, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 7800, deepMemtestMinMb = 128,
        ),
        RamPreset(
            ramGb = 24,
            quickMemtestPercent = 12, quickMemtestMaxMb = 2048,
            quickMemtestMinMb = 128, quickMemtestLoops = 1, quickMemtestTimeoutS = 1500,
            deepMemtestPercent = 25, deepMemtestMaxMb = 4096,
            deepMemtestLoops = 2, deepMemtestTimeoutS = 7200, deepMemtestMinMb = 128,
        ),
    )

    /** Encontra o preset exato ou o mais proximo (interpolando para cima). */
    fun forRamGb(ramGb: Int): RamPreset {
        val exact = ALL.firstOrNull { it.ramGb == ramGb }
        if (exact != null) return exact
        // pega o menor preset >= ramGb (mais conservador) ou o ultimo se acima de tudo
        return ALL.firstOrNull { it.ramGb >= ramGb } ?: ALL.last()
    }

    val ramOptions: List<Int> = ALL.map { it.ramGb }
}
