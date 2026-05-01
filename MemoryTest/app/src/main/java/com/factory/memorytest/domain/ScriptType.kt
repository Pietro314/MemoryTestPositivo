package com.factory.memorytest.domain

/**
 * Catalogo dos scripts disponiveis. Fonte unica de verdade para nomes
 * e mapeamento entre o comando do daemon e o que mostrar pro usuario.
 */
enum class ScriptType(
    val daemonCommand: String,
    val displayName: String,
    val shortLabel: String,
) {
    FACTORY(
        daemonCommand = "RUN full_memtest",
        displayName = "Teste padrão de fábrica",
        shortLabel = "FACTORY",
    ),
    DEEP_RAM(
        daemonCommand = "RUN ram_diagnostic",
        displayName = "Diagnóstico profundo de RAM",
        shortLabel = "DEEP_RAM",
    );

    companion object {
        fun fromShortLabelOrNull(label: String?): ScriptType? =
            values().firstOrNull { it.shortLabel == label }
    }
}
