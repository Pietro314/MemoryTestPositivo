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
            Step("storage_test",  "Velocidade de Storage", orderIndex = 3),
            Step("ram_test",      "Memtester (rápido)", orderIndex = 4),
            Step("dmesg",         "Análise do dmesg", orderIndex = 5),
            Step("final",         "Resultado", orderIndex = 6),
        )
        ScriptType.DEEP_RAM -> listOf(
            Step("device_id",     "Identificação", orderIndex = 0),
            Step("ram_info",      "RAM detectada", orderIndex = 1),
            Step("locate_mt",     "Localizar memtester", orderIndex = 2),
            Step("ram_test",      "Memtester profundo", orderIndex = 3),
            Step("final",         "Resultado", orderIndex = 4),
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
            4 to 3, // storage test
            5 to 4, // ram test
            6 to 5, // dmesg
            7 to 6, // final
        )
        ScriptType.DEEP_RAM -> mapOf(
            1 to 0, // device id
            2 to 1, // ram info
            3 to 2, // locate memtester
            4 to 3, // deep ram test
            5 to 4, // final (heuristico — script nao tem secao 5 fixa, tratado por DEVICE OK/FAILED)
        )
    }

    private val sectionRegex = Regex("""^\[(\d+)\]\s+(.+)$""")
    private val failRegex = Regex("""(?i)❌?\s*FAIL\s*:\s*(.+)""")
    private val warnRegex = Regex("""(?i)⚠️?\s*WARNING\s*:\s*(.+)""")
    private val resultPassRegex = Regex("""(?i)(DEVICE OK|RAM DIAGNOSTIC OK)""")
    private val resultFailRegex = Regex("""(?i)(DEVICE FAILED|RAM DIAGNOSTIC FAILED)""")

    private val summaryHints: List<Pair<Regex, (MatchResult) -> Pair<Int, String>>> = listOf(
        Regex("""Type\s*:\s*(\S+)""") to { m -> 1 to "Tipo: ${m.groupValues[1]}" },
        Regex("""Vendor\s*:\s*(.+)""") to { m -> 1 to (m.groupValues[1].trim()) },
        Regex("""Pre-EOL\s*:\s*(.+)""") to { m -> 1 to "Pre-EOL: ${m.groupValues[1].trim()}" },
        Regex("""Total RAM\s*:\s*(\d+)\s*MB""") to { m -> 2 to "${m.groupValues[1]} MB total" },
        Regex("""MemTotal\s*:\s*(\d+)\s*MB""") to { m -> 1 to "${m.groupValues[1]} MB total" },
        Regex("""Write speed\s*:\s*~?(\d+)\s*MB/s""") to { m -> 3 to "W: ${m.groupValues[1]} MB/s" },
        Regex("""Read speed\s*:\s*~?(\d+)\s*MB/s""") to { m -> 3 to "R: ${m.groupValues[1]} MB/s" },
        Regex("""memtester\s*:\s*OK\s*\(exit\s+\d+,\s*duração\s+(\d+)s""") to { m -> 4 to "OK em ${m.groupValues[1]}s" },
        Regex("""dmesg\s*:\s*sem erros""") to { _ -> 5 to "Sem erros" },
        Regex("""dmesg\s*:\s*não disponível""") to { _ -> 5 to "Sem permissão" },
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
