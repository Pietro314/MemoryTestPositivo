package com.factory.memorytest.domain

/**
 * Catalogo dos scripts disponiveis. Cada entrada aponta para um asset
 * embarcado no APK que e extraido pra filesDir/scripts/ em runtime.
 */
enum class ScriptType(
    val displayName: String,
    val shortLabel: String,
    val assetName: String,
    val daemonCommand: String,
) {
    FACTORY(
        displayName = "Teste padrão de fábrica",
        shortLabel = "FACTORY",
        assetName = "full_memtest.sh",
        daemonCommand = "RUN full_memtest",
    ),
    DEEP_RAM(
        displayName = "Diagnóstico profundo de RAM",
        shortLabel = "DEEP_RAM",
        assetName = "ram_diagnostic_deep_verbose_root_exec.sh",
        daemonCommand = "RUN ram_diagnostic",
    );

    companion object {
        fun fromShortLabelOrNull(label: String?): ScriptType? =
            values().firstOrNull { it.shortLabel == label }
    }
}
