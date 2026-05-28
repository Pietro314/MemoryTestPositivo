package com.factory.memorytest.service

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.ui.autotest.AutoTestViewModel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Escreve resultado consolidado do AutoTest em arquivo local + dispara
 * broadcast pra outros apps consumirem.
 *
 *  - Arquivo: /storage/emulated/0/Positivo/MemoryTest/result.json
 *  - Broadcast: com.factory.memorytest.action.RESULT_READY (sem permission)
 *
 * Hoje o factory app nao consome (decisao C: futuro). Mas ja deixamos o
 * canal aberto pra ele plugar um BroadcastReceiver quando quiser.
 */
class AutoTestResultWriter(private val context: Context) {

    /**
     * Serializa o estado terminal e emite os outputs (arquivo + broadcast).
     * Aceita Stage.Finished | Stopped | ProfileError | erro de BUSY.
     */
    fun writeAndBroadcast(
        device: String,
        ramGb: Int,
        profile: DeviceProfile?,
        overall: String,                                    // PASS | FAIL | STOPPED | ERROR
        factory: AutoTestViewModel.PhaseResult? = null,
        deep: AutoTestViewModel.PhaseResult? = null,
        errorMessage: String? = null,
    ) {
        val json = buildJson(device, ramGb, profile, overall, factory, deep, errorMessage)
        writeFile(json)
        sendBroadcast(overall, factory, deep, device, ramGb, errorMessage)
    }

    private fun buildJson(
        device: String,
        ramGb: Int,
        profile: DeviceProfile?,
        overall: String,
        factory: AutoTestViewModel.PhaseResult?,
        deep: AutoTestViewModel.PhaseResult?,
        errorMessage: String?,
    ): JSONObject = JSONObject().apply {
        put("schema_version", 1)
        put("device", device)
        put("ramGb", ramGb)
        put("serial", safeSerial())
        put("timestamp", isoNow())
        put("overall", overall)
        if (errorMessage != null) put("error_message", errorMessage)
        if (profile != null) {
            put("profile", JSONObject().apply {
                put("name", profile.name)
                put("manufacturer", profile.manufacturer)
                put("modelCode", profile.modelCode)
            })
        }
        put("factory", phaseToJson(factory))
        put("deep", phaseToJson(deep))
    }

    private fun phaseToJson(phase: AutoTestViewModel.PhaseResult?): JSONObject {
        if (phase == null) return JSONObject().apply { put("status", "NOT_RUN") }
        return JSONObject().apply {
            put("status", phase.status)
            put("duration_s", phase.durationMs / 1000)
            val reasons = phase.parserState.steps
                .filter { it.status == ScriptOutputParser.StepStatus.FAIL }
                .map { step -> "${step.label}: ${step.summary.ifBlank { "FAIL" }}" }
            put("reasons", JSONArray(reasons))
            val summaries = phase.parserState.steps
                .filter { it.summary.isNotBlank() }
                .map { it.label + ": " + it.summary }
            put("steps_summary", JSONArray(summaries))
        }
    }

    private fun writeFile(json: JSONObject) {
        try {
            val finalFile = File(OUTPUT_PATH)
            finalFile.parentFile?.mkdirs()
            // Atomic write: escreve em .tmp e renomeia. Evita result.json
            // corrompido se o processo for morto no meio da escrita.
            val tmpFile = File(finalFile.parentFile, finalFile.name + ".tmp")
            tmpFile.writeText(json.toString(2))
            if (finalFile.exists()) finalFile.delete()
            if (!tmpFile.renameTo(finalFile)) {
                // fallback: copia conteudo e apaga tmp
                finalFile.writeText(tmpFile.readText())
                tmpFile.delete()
            }
            Log.i(TAG, "Resultado gravado em $OUTPUT_PATH")
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao gravar $OUTPUT_PATH", e)
        }
    }

    private fun sendBroadcast(
        overall: String,
        factory: AutoTestViewModel.PhaseResult?,
        deep: AutoTestViewModel.PhaseResult?,
        device: String,
        ramGb: Int,
        errorMessage: String?,
    ) {
        try {
            val intent = Intent(ACTION_RESULT_READY).apply {
                putExtra("overall", overall)
                putExtra("factory_status", factory?.status ?: "NOT_RUN")
                putExtra("factory_duration_s", (factory?.durationMs ?: 0L) / 1000)
                putExtra("deep_status", deep?.status ?: "NOT_RUN")
                putExtra("deep_duration_s", (deep?.durationMs ?: 0L) / 1000)
                putExtra("result_file", OUTPUT_PATH)
                putExtra("device", device)
                putExtra("ramGb", ramGb)
                putExtra("serial", safeSerial())
                if (errorMessage != null) putExtra("error_message", errorMessage)
            }
            context.sendBroadcast(intent)
            Log.i(TAG, "Broadcast $ACTION_RESULT_READY emitido (overall=$overall)")
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao emitir broadcast", e)
        }
    }

    private fun isoNow(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    @Suppress("DEPRECATION")
    private fun safeSerial(): String = try {
        Build.SERIAL ?: ""
    } catch (e: Throwable) {
        ""
    }

    companion object {
        private const val TAG = "AutoTest"
        const val OUTPUT_PATH =
            "/storage/emulated/0/Positivo/MemoryTest/result.json"
        const val ACTION_RESULT_READY =
            "com.factory.memorytest.action.RESULT_READY"
    }
}
