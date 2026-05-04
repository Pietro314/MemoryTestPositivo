package com.factory.memorytest.ui.testrun

import android.app.Application
import android.os.Environment
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.viewModelScope
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.data.db.TestRunEntity
import com.factory.memorytest.data.db.TestStepEntity
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.ScriptType
import com.factory.memorytest.service.RunnerEvent
import com.factory.memorytest.service.ScriptOutputParser
import com.factory.memorytest.service.ScriptRunner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class TestRunViewModel(app: Application) : AndroidViewModel(app) {

    private val mtApp = app as MemoryTestApp
    private val deviceRepo = mtApp.deviceRepo
    private val runRepo = mtApp.runRepo

    val log = MutableLiveData<String>("")
    val parserState = MutableLiveData(ScriptOutputParser.State(emptyList(), null))
    val phase = MutableLiveData(Phase.PREPARING)
    val elapsedMs = MutableLiveData(0L)
    val device = MutableLiveData<DeviceProfile?>(null)
    val scriptType = MutableLiveData<ScriptType?>(null)
    val finalResult = MutableLiveData<String?>(null)
    val reportPath = MutableLiveData<String?>(null)
    val runId = MutableLiveData<Long?>(null)

    private val logBuilder = StringBuilder()
    private var collectJob: Job? = null
    private var elapsedJob: Job? = null
    private var startedAt: Long = 0L
    private var parser: ScriptOutputParser? = null

    enum class Phase { PREPARING, RUNNING, FINISHED, ERROR }

    fun start(deviceId: Long, type: ScriptType) {
        if (phase.value != Phase.PREPARING) return
        viewModelScope.launch {
            val profile = deviceRepo.findById(deviceId)
            if (profile == null) {
                phase.value = Phase.ERROR
                appendLog("[APP] Device id=$deviceId não encontrado.\n")
                return@launch
            }
            device.value = profile
            scriptType.value = type
            beginRun(profile, type)
        }
    }

    private suspend fun beginRun(profile: DeviceProfile, type: ScriptType) {
        parser = ScriptOutputParser(type)
        parserState.value = parser!!.snapshot()
        phase.value = Phase.RUNNING
        startedAt = System.currentTimeMillis()

        // Persiste run inicial
        val entity = TestRunEntity(
            deviceId = profile.id,
            deviceNameSnapshot = profile.name,
            deviceManufacturerSnapshot = profile.manufacturer,
            scriptType = type.shortLabel,
            startedAt = startedAt,
            result = "RUNNING",
        )
        val newRunId = runRepo.startRun(entity)
        runId.value = newRunId

        elapsedJob = viewModelScope.launch {
            while (isActive && phase.value == Phase.RUNNING) {
                elapsedMs.value = System.currentTimeMillis() - startedAt
                delay(1000)
            }
        }

        collectJob = viewModelScope.launch {
            val runner = ScriptRunner(getApplication())
            try {
                runner.runScript(type, profile).collectLatest { event ->
                    handleEvent(event, profile, type, newRunId)
                }
            } catch (e: Exception) {
                appendLog("\n[APP] Erro: ${e.message}\n")
                onFinish(null, profile, type, newRunId)
            }
        }
    }

    private suspend fun handleEvent(
        event: RunnerEvent,
        profile: DeviceProfile,
        type: ScriptType,
        runId: Long,
    ) {
        when (event) {
            is RunnerEvent.Line -> {
                appendLog(event.text + "\n")
                val newState = parser?.feed(event.text) ?: return
                parserState.postValue(newState)
            }
            is RunnerEvent.Exit -> {
                onFinish(event.code, profile, type, runId)
            }
            is RunnerEvent.Error -> {
                appendLog("\n[APP] Erro de execução: ${event.message}\n")
                onFinish(null, profile, type, runId)
            }
        }
    }

    private suspend fun onFinish(
        exitCode: Int?,
        profile: DeviceProfile,
        type: ScriptType,
        runId: Long,
    ) {
        if (phase.value == Phase.FINISHED) return
        val state = parser?.finalize(exitCode) ?: return
        parserState.postValue(state)

        val result = state.overallResult ?: "FAIL"
        val finishedAt = System.currentTimeMillis()
        val duration = finishedAt - startedAt

        val reportFile = saveReport(profile, type, result, finishedAt)

        runRepo.updateRun(
            TestRunEntity(
                id = runId,
                deviceId = profile.id,
                deviceNameSnapshot = profile.name,
                deviceManufacturerSnapshot = profile.manufacturer,
                scriptType = type.shortLabel,
                serialNo = "",
                startedAt = startedAt,
                finishedAt = finishedAt,
                durationMs = duration,
                result = result,
                exitCode = exitCode,
                logFilePath = reportFile?.absolutePath,
                failReasons = state.steps.filter { it.status == ScriptOutputParser.StepStatus.FAIL }
                    .joinToString("\n") { "${it.label}: ${it.details.ifBlank { it.summary }}" },
            )
        )

        runRepo.replaceSteps(
            runId,
            state.steps.map { s ->
                TestStepEntity(
                    runId = runId,
                    stepKey = s.key,
                    stepLabel = s.label,
                    status = s.status.name,
                    summary = s.summary,
                    details = s.details,
                    orderIndex = s.orderIndex,
                )
            }
        )

        finalResult.postValue(result)
        reportPath.postValue(reportFile?.absolutePath)
        phase.postValue(Phase.FINISHED)
    }

    private suspend fun saveReport(
        profile: DeviceProfile,
        type: ScriptType,
        result: String,
        finishedAt: Long,
    ): File? = withContext(Dispatchers.IO) {
        val ts = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(Date(finishedAt))
        val safeName = profile.name.filter { it.isLetterOrDigit() || it == '_' || it == '-' }
            .ifBlank { "device" }
        val fileName = "memtest_${type.shortLabel.lowercase()}_${safeName}_${ts}_$result.txt"
        val dir = File(Environment.getExternalStorageDirectory(), "MemoryTest")
        runCatching { dir.mkdirs() }
        val file = File(dir, fileName)
        try {
            file.writeText(buildReportText(profile, type, result, finishedAt))
            file
        } catch (e: Exception) {
            // fallback no diretorio interno do app
            try {
                val internal = File(getApplication<Application>().filesDir, fileName)
                internal.writeText(buildReportText(profile, type, result, finishedAt))
                internal
            } catch (e2: Exception) {
                null
            }
        }
    }

    private fun buildReportText(
        profile: DeviceProfile,
        type: ScriptType,
        result: String,
        finishedAt: Long,
    ): String = buildString {
        append("MemoryTest Factory App — Relatório\n")
        append("===================================\n")
        append("Device      : ${profile.name}\n")
        append("Fabricante  : ${profile.manufacturer}\n")
        append("Modelo      : ${profile.modelCode}\n")
        append("Teste       : ${type.displayName}\n")
        append("Iniciado em : ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(startedAt))}\n")
        append("Terminou em : ${SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(finishedAt))}\n")
        append("Resultado   : $result\n")
        append("===================================\n\n")
        append(logBuilder.toString())
    }

    private fun appendLog(text: String) {
        logBuilder.append(text)
        log.postValue(logBuilder.toString())
    }

    fun abort() {
        if (phase.value != Phase.RUNNING) return
        appendLog("\n[APP] Aborto solicitado pelo usuário.\n")
        collectJob?.cancel()
        elapsedJob?.cancel()
        viewModelScope.launch {
            val rid = runId.value
            if (rid != null) {
                val profile = device.value
                val type = scriptType.value
                if (profile != null && type != null) {
                    val finishedAt = System.currentTimeMillis()
                    runRepo.updateRun(
                        TestRunEntity(
                            id = rid,
                            deviceId = profile.id,
                            deviceNameSnapshot = profile.name,
                            deviceManufacturerSnapshot = profile.manufacturer,
                            scriptType = type.shortLabel,
                            startedAt = startedAt,
                            finishedAt = finishedAt,
                            durationMs = finishedAt - startedAt,
                            result = "ABORTED",
                            exitCode = null,
                        )
                    )
                }
            }
            finalResult.postValue("ABORTED")
            phase.postValue(Phase.FINISHED)
        }
    }

    override fun onCleared() {
        super.onCleared()
        collectJob?.cancel()
        elapsedJob?.cancel()
    }
}
