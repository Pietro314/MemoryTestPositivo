package com.factory.memorytest.service

import android.util.Log
import com.factory.memorytest.ui.autotest.AutoTestViewModel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Grava logs detalhados de cada fase (factory, deep) no storage publico:
 *
 *   /storage/emulated/0/Positivo/MemoryTest/logs/<timestamp>_<phase>_<device>_<serial>_<status>.log
 *
 * Tanto em PASS quanto em FAIL/STOPPED — sem distincao. O arquivo contem
 * o output completo do script (stdout + stderr mergeados) que o
 * ScriptRunner emitiu durante a execucao.
 */
class AutoTestLogWriter {

    /**
     * Grava o log de uma fase no disco. Idempotente em chamadas repetidas
     * (sobrescreve o arquivo com o mesmo nome).
     */
    fun writePhaseLog(
        timestamp: String,
        device: String,
        serial: String,
        phaseResult: AutoTestViewModel.PhaseResult,
    ) {
        try {
            val dir = File(LOG_DIR)
            if (!dir.exists()) dir.mkdirs()

            val phaseStr = if (phaseResult.phase == AutoTestViewModel.Phase.FACTORY) "factory" else "deep"
            val safeDevice = sanitize(device.ifBlank { "unknown" })
            val safeSerial = sanitize(serial.ifBlank { "unknown" })
            val filename = "${timestamp}_${phaseStr}_${safeDevice}_${safeSerial}_${phaseResult.status}.log"
            val file = File(dir, filename)

            // Cabecalho + corpo
            val header = buildString {
                appendLine("============================================================")
                appendLine("  AutoTest log — ${phaseStr.uppercase()}")
                appendLine("  Device   : $device")
                appendLine("  Serial   : $serial")
                appendLine("  Status   : ${phaseResult.status}")
                appendLine("  Duration : ${phaseResult.durationMs / 1000}s")
                appendLine("  Timestamp: $timestamp")
                appendLine("============================================================")
                appendLine()
            }
            val body = phaseResult.output.joinToString("\n")

            file.writeText(header + body, Charsets.UTF_8)
            Log.i(TAG, "Log gravado: ${file.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "Falha ao gravar log da fase ${phaseResult.phase}", e)
        }
    }

    /**
     * Gera timestamp consistente pra todos os arquivos da mesma execucao
     * de AUTO_TEST. Use uma vez por run e passe pra cada writePhaseLog.
     */
    fun newRunTimestamp(): String {
        val fmt = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
        return fmt.format(Date())
    }

    private fun sanitize(s: String): String =
        s.replace(Regex("[^A-Za-z0-9._-]"), "_").take(40)

    companion object {
        private const val TAG = "AutoTest"
        const val LOG_DIR = "/storage/emulated/0/Positivo/MemoryTest/logs"
    }
}
