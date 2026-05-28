package com.factory.memorytest.ui.autotest

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.ScriptType
import com.factory.memorytest.service.MemoryTestConfigClient
import com.factory.memorytest.service.MemoryTestConfigParser
import com.factory.memorytest.service.RunnerEvent
import com.factory.memorytest.service.ScriptOutputParser
import com.factory.memorytest.service.ScriptRunner
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import java.io.File

/**
 * Orquestra o teste automatico: carrega perfil do JSON, roda factory,
 * depois roda deep (sempre, mesmo se factory falhou — decisao 1).
 *
 * Estado exposto via [state] StateFlow. UI observa e renderiza.
 */
class AutoTestViewModel(app: Application) : AndroidViewModel(app) {

    enum class Phase { FACTORY, DEEP }

    data class PhaseResult(
        val phase: Phase,
        val status: String,            // "PASS" | "FAIL" | "STOPPED"
        val durationMs: Long,
        val parserState: ScriptOutputParser.State,
        val output: List<String>,      // todas as linhas do script (pra logs em disco)
    )

    sealed class Stage {
        object Idle : Stage()
        object LoadingProfile : Stage()
        data class ProfileError(val message: String) : Stage()
        data class Running(
            val profile: DeviceProfile,
            val device: String,
            val ramGb: Int,
            val phase: Phase,
            val parserState: ScriptOutputParser.State,
            val elapsedMs: Long,
            val factoryDone: PhaseResult? = null,
        ) : Stage()
        data class Finished(
            val profile: DeviceProfile,
            val device: String,
            val ramGb: Int,
            val factory: PhaseResult,
            val deep: PhaseResult?,     // null se factory falhou (decisao atual: nao roda deep)
            val overall: String,        // "PASS" | "FAIL"
        ) : Stage()
        data class Stopped(
            val profile: DeviceProfile?,
            val device: String,
            val ramGb: Int,
            val factory: PhaseResult?,
            val deep: PhaseResult?,
        ) : Stage()
    }

    private val _stage = MutableStateFlow<Stage>(Stage.Idle)
    val stage: StateFlow<Stage> = _stage.asStateFlow()

    private var job: Job? = null

    /**
     * Inicia o fluxo: le JSON → identifica perfil → roda factory → roda deep.
     * Idempotente: se ja esta rodando, nao faz nada.
     */
    fun start() {
        if (job?.isActive == true) return

        job = viewModelScope.launch {
            _stage.value = Stage.LoadingProfile

            val device = Build.DEVICE ?: ""
            val ramGb = readTotalRamGb()

            val readResult = MemoryTestConfigClient().read()
            val profile = readResult.fold(
                onSuccess = { json ->
                    when (val match = MemoryTestConfigParser.findProfile(json, device, ramGb)) {
                        is MemoryTestConfigParser.LookupResult.Found -> match.profile
                        is MemoryTestConfigParser.LookupResult.NotFound -> {
                            _stage.value = Stage.ProfileError(
                                "Device '$device' com $ramGb GB nao encontrado em memorytestconfig.json"
                            )
                            return@launch
                        }
                        is MemoryTestConfigParser.LookupResult.Invalid -> {
                            _stage.value = Stage.ProfileError("JSON invalido: ${match.reason}")
                            return@launch
                        }
                    }
                },
                onFailure = {
                    _stage.value = Stage.ProfileError(
                        "Erro ao ler ${MemoryTestConfigClient.CONFIG_PATH}: ${it.message}"
                    )
                    return@launch
                }
            )

            // Roda factory
            val factoryResult = runScript(profile, device, ramGb, Phase.FACTORY, factoryDone = null)

            // Cancelado durante factory: para tudo
            if (factoryResult.status == "STOPPED") {
                _stage.value = Stage.Stopped(profile, device, ramGb, factoryResult, deep = null)
                return@launch
            }

            // MUDANCA: se factory FAIL, NAO roda deep — para imediatamente
            if (factoryResult.status == "FAIL") {
                _stage.value = Stage.Finished(
                    profile = profile, device = device, ramGb = ramGb,
                    factory = factoryResult, deep = null, overall = "FAIL"
                )
                return@launch
            }

            val deepResult = runScript(profile, device, ramGb, Phase.DEEP, factoryDone = factoryResult)

            if (deepResult.status == "STOPPED") {
                _stage.value = Stage.Stopped(profile, device, ramGb, factoryResult, deepResult)
                return@launch
            }

            // Overall: PASS so se ambos passaram
            val overall = if (factoryResult.status == "PASS" && deepResult.status == "PASS") "PASS" else "FAIL"
            _stage.value = Stage.Finished(profile, device, ramGb, factoryResult, deepResult, overall)
        }
    }

    /** Cancela o teste em curso. Preserva resultados parciais ja obtidos. */
    fun stop() {
        job?.cancel()
    }

    private suspend fun runScript(
        profile: DeviceProfile,
        device: String,
        ramGb: Int,
        phase: Phase,
        factoryDone: PhaseResult?,
    ): PhaseResult {
        val scriptType = if (phase == Phase.FACTORY) ScriptType.FACTORY else ScriptType.DEEP_RAM
        val parser = ScriptOutputParser(scriptType)
        val runner = ScriptRunner(getApplication())

        // Mantem TODAS as linhas pra salvar em log de disco depois.
        // Tipico: factory ~200 linhas, deep ~500 linhas — sem pressao real de memoria.
        val allOutput = ArrayList<String>()
        val startMs = System.currentTimeMillis()
        var exitCode: Int? = null

        _stage.value = Stage.Running(
            profile = profile, device = device, ramGb = ramGb,
            phase = phase, parserState = parser.snapshot(),
            elapsedMs = 0, factoryDone = factoryDone,
        )

        try {
            runner.runScript(scriptType, profile).collect { event ->
                when (event) {
                    is RunnerEvent.Line -> {
                        val state = parser.feed(event.text)
                        allOutput.add(event.text)
                        _stage.value = Stage.Running(
                            profile = profile, device = device, ramGb = ramGb,
                            phase = phase, parserState = state,
                            elapsedMs = System.currentTimeMillis() - startMs,
                            factoryDone = factoryDone,
                        )
                    }
                    is RunnerEvent.Exit -> {
                        exitCode = event.code
                    }
                    is RunnerEvent.Error -> {
                        allOutput.add("[ERROR] ${event.message}")
                    }
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            // Cancelado pelo stop()
            return PhaseResult(
                phase = phase,
                status = "STOPPED",
                durationMs = System.currentTimeMillis() - startMs,
                parserState = parser.snapshot(),
                output = allOutput.toList(),
            )
        }

        val finalState = parser.finalize(exitCode)
        val status = finalState.overallResult ?: "FAIL"
        return PhaseResult(
            phase = phase,
            status = status,
            durationMs = System.currentTimeMillis() - startMs,
            parserState = finalState,
            output = allOutput.toList(),
        )
    }

    private fun readTotalRamGb(): Int {
        return try {
            val text = File("/proc/meminfo").readText()
            val line = text.lines().firstOrNull { it.startsWith("MemTotal:") } ?: return 0
            val kb = line.split(Regex("\\s+")).getOrNull(1)?.toLongOrNull() ?: 0L
            val mb = (kb / 1024).toInt()
            (mb + 1023) / 1024
        } catch (e: Exception) {
            0
        }
    }
}
