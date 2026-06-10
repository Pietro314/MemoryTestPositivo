package com.factory.memorytest.service

import com.factory.memorytest.domain.ScriptType

/**
 * Parser stateful do output do script. Converte linhas em eventos
 * de UI (StepUpdate, OverallResult, etc).
 *
 * Cada script tem um conjunto fixo de secoes que viram cards na tela.
 */
class ScriptOutputParser(private val script: ScriptType) {

    enum class StepStatus { PENDING, RUNNING, PASS, FAIL, WARN, SKIP }

    data class Step(
        val key: String,
        val label: String,
        val status: StepStatus = StepStatus.PENDING,
        val summary: String = "",
        val details: String = "",
        val orderIndex: Int = 0,
    )

    data class State(
        val steps: List<Step>,
        val overallResult: String? = null,
    )

    private val stepDefs: List<Step> = when (script) {
        ScriptType.FACTORY -> listOf(
            Step("device_id",     "Identificação", orderIndex = 0),
            Step("storage_info",  "Saúde do Storage", orderIndex = 1),
            Step("ram_info",      "RAM detectada", orderIndex = 2),
            Step("dmesg",         "Análise do dmesg", orderIndex = 3),
            Step("final",         "Resultado", orderIndex = 4),
        )
        ScriptType.DEEP_RAM -> listOf(
            Step("device_id",      "Identificação", orderIndex = 0),
            Step("ram_info",       "RAM detectada", orderIndex = 1),
            Step("locate_mt",      "Localizar memtester", orderIndex = 2),
            Step("storage_test",   "Velocidade de Storage", orderIndex = 3),
            Step("ram_test_quick", "Memtester rápido (gate)", orderIndex = 4),
            Step("ram_test",       "Memtester profundo", orderIndex = 5),
            Step("dmesg",          "Análise do dmesg", orderIndex = 6),
            Step("final",          "Resultado", orderIndex = 7),
        )
    }

    private val byOrder = stepDefs.toMutableList()

    private var currentSectionIndex = -1

    private var finalResult: String? = null

    /** Mapeia o numero da secao [N] do script para o indice de step nesta tela. */
    private val sectionMap: Map<Int, Int> = when (script) {
        ScriptType.FACTORY -> mapOf(
            1 to 0, // device id
            2 to 1, // storage info
            3 to 2, // ram info
            4 to 3, // dmesg
            5 to 4, // final
        )
        ScriptType.DEEP_RAM -> mapOf(
            1 to 0, // device id
            2 to 1, // ram info
            3 to 2, // locate memtester
            4 to 3, // storage test (dd + md5)
            5 to 4, // memtester quick (gate)
            6 to 5, // memtester deep
            7 to 6, // dmesg
            8 to 7, // final
        )
    }

    private val sectionRegex = Regex("""^\[(\d+)\]\s+(.+)$""")
    private val failRegex = Regex("""(?i)❌?\s*FAIL\s*:\s*(.+)""")
    private val warnRegex = Regex("""(?i)⚠️?\s*WARNING\s*:\s*(.+)""")
    private val resultPassRegex = Regex("""(?i)(DEVICE OK|RAM DIAGNOSTIC OK)""")
    private val resultFailRegex = Regex("""(?i)(DEVICE FAILED|RAM DIAGNOSTIC FAILED)""")

    // Os hints abaixo usam numeros de SECAO do script (nao indices de step).
    // Como as seções têm significados diferentes entre FACTORY e DEEP_RAM, os
    // hints sao escritos pra so disparar quando a linha exata aparece, e a
    // seção apontada é a correta no script onde a linha é emitida:
    //   - Factory: [2]storage_info, [3]ram_info, [4]dmesg
    //   - Deep:    [2]ram_info, [4]storage_test, [5]quick, [6]deep, [7]dmesg
    // Linhas exclusivas de um script (ex: "Total RAM" só no factory, "MemTotal"
    // só no deep) sao seguras de mapear pra qualquer seção sem conflito.
    private val summaryHints: List<Pair<Regex, (MatchResult) -> Pair<Int, String>>> = listOf(
        // Storage info (factory section [2])
        Regex("""Type\s*:\s*(\S+)""") to { m -> 2 to "Tipo: ${m.groupValues[1]}" },
        Regex("""Vendor\s*:\s*(.+)""") to { m -> 2 to (m.groupValues[1].trim()) },
        Regex("""Pre-EOL\s*:\s*(.+)""") to { m -> 2 to "Pre-EOL: ${m.groupValues[1].trim()}" },
        // RAM info — factory usa "Total RAM", deep usa "MemTotal"
        Regex("""Total RAM\s*:\s*(\d+)\s*MB""") to { m -> 3 to "${m.groupValues[1]} MB total" },
        Regex("""MemTotal\s*:\s*(\d+)\s*MB""") to { m -> 2 to "${m.groupValues[1]} MB total" },
        // Storage test (deep section [4])
        Regex("""Write speed\s*:\s*~?(\d+)\s*MB/s""") to { m -> 4 to "W: ${m.groupValues[1]} MB/s" },
        Regex("""Read speed\s*:\s*~?(\d+)\s*MB/s""") to { m -> 4 to "R: ${m.groupValues[1]} MB/s" },
        Regex("""Integridade\s*:\s*OK""") to { _ -> 4 to "Integridade OK" },
        // Memtester quick (deep section [5])
        Regex("""memtester quick\s*:\s*OK\s*\(exit\s+\d+,\s*duração\s+(\d+)s""") to { m -> 5 to "OK em ${m.groupValues[1]}s" },
        // Memtester deep (deep section [6]) — lookahead negativo pra nao capturar "memtester quick"
        Regex("""memtester(?!\s+quick)\s*:\s*OK\s*\(exit\s+\d+,\s*duração\s+(\d+)s""") to { m -> 6 to "OK em ${m.groupValues[1]}s" },
        // dmesg — labels diferentes entre factory ("sem erros") e deep ("sem eventos")
        Regex("""dmesg\s*:\s*sem erros""") to { _ -> 4 to "Sem erros" },        // factory [4]
        Regex("""dmesg\s*:\s*sem eventos""") to { _ -> 7 to "Sem eventos" },    // deep [7]
    )

    fun feed(line: String): State {
        val sectionMatch = sectionRegex.matchEntire(line.trim())
        if (sectionMatch != null) {
            val n = sectionMatch.groupValues[1].toIntOrNull()
            if (n != null) {
                // Marca step anterior como PASS se ainda estiver RUNNING
                val previous = currentSectionIndex
                if (previous in byOrder.indices) {
                    val prev = byOrder[previous]
                    if (prev.status == StepStatus.RUNNING) {
                        byOrder[previous] = prev.copy(status = StepStatus.PASS)
                    }
                }
                val mapped = sectionMap[n]
                if (mapped != null && mapped in byOrder.indices) {
                    byOrder[mapped] = byOrder[mapped].copy(status = StepStatus.RUNNING)
                    currentSectionIndex = mapped
                }
            }
            return snapshot()
        }

        // FAIL: marca o step atual como FAIL (ou o "final" se nenhum ativo)
        val failMatch = failRegex.find(line)
        if (failMatch != null && currentSectionIndex in byOrder.indices) {
            val cur = byOrder[currentSectionIndex]
            val newDetails = (cur.details + "\n" + failMatch.groupValues[1]).trim()
            byOrder[currentSectionIndex] = cur.copy(
                status = StepStatus.FAIL,
                summary = if (cur.summary.isBlank()) failMatch.groupValues[1].take(60) else cur.summary,
                details = newDetails,
            )
            return snapshot()
        }

        val warnMatch = warnRegex.find(line)
        if (warnMatch != null && currentSectionIndex in byOrder.indices) {
            val cur = byOrder[currentSectionIndex]
            // so promove pra WARN se nao esta FAIL
            if (cur.status != StepStatus.FAIL) {
                val newDetails = (cur.details + "\n" + warnMatch.groupValues[1]).trim()
                byOrder[currentSectionIndex] = cur.copy(
                    status = StepStatus.WARN,
                    summary = if (cur.summary.isBlank()) warnMatch.groupValues[1].take(60) else cur.summary,
                    details = newDetails,
                )
            }
            return snapshot()
        }

        // Resultado final
        val passMatch = resultPassRegex.find(line)
        if (passMatch != null) {
            return finalizeOverall("PASS")
        }
        val failResultMatch = resultFailRegex.find(line)
        if (failResultMatch != null) {
            return finalizeOverall("FAIL")
        }

        // Pistas de summary para cards
        for ((rx, mapper) in summaryHints) {
            val m = rx.find(line)
            if (m != null) {
                val (sectionN, text) = mapper(m)
                val mapped = sectionMap[sectionN] ?: continue
                if (mapped in byOrder.indices) {
                    val cur = byOrder[mapped]
                    val combined = if (cur.summary.isBlank()) text else "${cur.summary} · $text"
                    byOrder[mapped] = cur.copy(summary = combined.take(80))
                }
            }
        }
        return snapshot()
    }

    private fun finalizeOverall(result: String): State {
        // Persiste pra que finalize() / snapshot() subsequentes retornem o mesmo.
        finalResult = result
        for (i in byOrder.indices) {
            val s = byOrder[i]
            if (s.status == StepStatus.RUNNING) {
                byOrder[i] = s.copy(status = StepStatus.PASS)
            }
        }
        val finalIdx = byOrder.indexOfFirst { it.key == "final" }
        if (finalIdx >= 0) {
            byOrder[finalIdx] = byOrder[finalIdx].copy(
                status = if (result == "PASS") StepStatus.PASS else StepStatus.FAIL,
                summary = result,
            )
        }
        return State(byOrder.toList(), overallResult = result)
    }

    fun snapshot(): State = State(byOrder.toList(), overallResult = finalResult)

    fun finalize(exitCode: Int?): State {
        // Se o script ja emitiu DEVICE OK/FAILED ou RAM DIAGNOSTIC OK/FAILED,
        // confia nesse resultado. Caso contrario, deriva do exit code.
        if (finalResult != null) return snapshot()
        val result = when {
            exitCode == 0 -> "PASS"
            exitCode == null -> "FAIL"
            else -> "FAIL"
        }
        return finalizeOverall(result)
    }
}
