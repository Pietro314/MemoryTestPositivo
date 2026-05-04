package com.factory.memorytest.service

import android.content.Context
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.ScriptType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader

/**
 * Executa o script de teste embarcado em assets/, sem depender de daemon
 * nativo nem socket Unix. Extrai o script pra filesDir/scripts/ e roda via
 * ProcessBuilder com env vars derivadas do DeviceProfile. Cada linha de
 * stdout (com stderr mergeado) vira um RunnerEvent.Line; o exit code do
 * processo vira um RunnerEvent.Exit.
 */
class ScriptRunner(private val context: Context) {

    fun runScript(
        script: ScriptType,
        profile: DeviceProfile,
    ): Flow<RunnerEvent> = callbackFlow {
        var process: Process? = null
        try {
            val scriptFile = extractAsset(script.assetName)
            val workDir = File(context.filesDir, "memtest_work").apply { mkdirs() }

            val pb = ProcessBuilder("/system/bin/sh", scriptFile.absolutePath).apply {
                directory(workDir)
                redirectErrorStream(true)
                buildEnv(script, profile).forEach { (k, v) -> environment()[k] = v }
            }

            process = pb.start()
            val reader = BufferedReader(InputStreamReader(process.inputStream, Charsets.UTF_8))
            while (true) {
                val line = try { reader.readLine() } catch (_: Exception) { null }
                if (line == null) {
                    val exit = try { process.waitFor() } catch (_: Exception) { -1 }
                    trySend(RunnerEvent.Exit(exit))
                    break
                }
                trySend(RunnerEvent.Line(line))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            trySend(RunnerEvent.Error(e.message ?: e.javaClass.simpleName))
        } finally {
            try { process?.destroyForcibly() } catch (_: Exception) {}
            close()
        }

        awaitClose {
            try { process?.destroyForcibly() } catch (_: Exception) {}
        }
    }.flowOn(Dispatchers.IO)

    private fun extractAsset(name: String): File {
        val outDir = File(context.filesDir, "scripts").apply { mkdirs() }
        val out = File(outDir, name)
        // Re-extrai sempre — garante que o script bate com a versao do APK
        // mesmo apos atualizacao.
        context.assets.open(name).use { input ->
            out.outputStream().use { output -> input.copyTo(output) }
        }
        out.setExecutable(true, false)
        out.setReadable(true, false)
        return out
    }

    private fun buildEnv(script: ScriptType, p: DeviceProfile): Map<String, String> {
        val base = mutableMapOf(
            "EXPECTED_RAM_GB"      to p.expectedRamGb.toString(),
            "EXPECTED_STORAGE_GB"  to p.expectedStorageGb.toString(),
            "MIN_WRITE_MBPS"       to p.minWriteMbps.toString(),
            "MIN_READ_MBPS"        to p.minReadMbps.toString(),
            "STORAGE_TEST_SIZE_MB" to p.storageTestSizeMb.toString(),
            "DEVICE_NAME"          to p.name.ascii(),
            "DEVICE_MANUFACTURER"  to p.manufacturer.ascii(),
        )
        when (script) {
            ScriptType.FACTORY -> {
                base["QUICK_MEMTEST_PERCENT"]   = p.quickMemtestPercent.toString()
                base["QUICK_MEMTEST_MAX_MB"]    = p.quickMemtestMaxMb.toString()
                base["QUICK_MEMTEST_MIN_MB"]    = p.quickMemtestMinMb.toString()
                base["QUICK_MEMTEST_LOOPS"]     = p.quickMemtestLoops.toString()
                base["QUICK_MEMTEST_TIMEOUT_S"] = p.quickMemtestTimeoutS.toString()
            }
            ScriptType.DEEP_RAM -> {
                base["MEMTEST_PERCENT"]   = p.deepMemtestPercent.toString()
                base["MEMTEST_MAX_MB"]    = p.deepMemtestMaxMb.toString()
                base["MEMTEST_LOOPS"]     = p.deepMemtestLoops.toString()
                base["MEMTEST_TIMEOUT_S"] = p.deepMemtestTimeoutS.toString()
                base["MIN_MEMTEST_MB"]    = p.deepMemtestMinMb.toString()
            }
        }
        return base
    }
}

/** Eventos emitidos durante a execucao do script. */
sealed class RunnerEvent {
    data class Line(val text: String) : RunnerEvent()
    data class Exit(val code: Int) : RunnerEvent()
    data class Error(val message: String) : RunnerEvent()
}

/** Remove caracteres nao-ASCII e os que quebram parsing do shell. */
private fun String.ascii(): String =
    filter { c ->
        c.code in 32..126 && c != '\'' && c != '"' && c != '`' && c != '$' && c != '\\'
    }
