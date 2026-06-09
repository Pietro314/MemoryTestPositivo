package com.factory.memorytest.service

import android.net.LocalSocket
import android.net.LocalSocketAddress
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.ScriptType
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.SocketException

/**
 * Cliente do memtest_daemon. Conecta no socket /dev/socket/memtest_daemon,
 * envia o comando + KEY=VALUE do device, e emite cada linha de output como
 * um DaemonEvent.
 */
class DaemonClient(
    private val socketName: String = "memtest_daemon",
) {

    fun runScript(
        script: ScriptType,
        profile: DeviceProfile,
    ): Flow<DaemonEvent> = callbackFlow {
        val socket = LocalSocket()
        try {
            socket.connect(LocalSocketAddress(socketName, LocalSocketAddress.Namespace.RESERVED))

            val out = socket.outputStream
            val sb = StringBuilder()
            sb.append(script.daemonCommand).append('\n')
            for ((k, v) in buildEnv(script, profile)) {
                sb.append(k).append('=').append(v).append('\n')
            }
            sb.append("END\n")
            out.write(sb.toString().toByteArray(Charsets.UTF_8))
            out.flush()

            val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
            while (true) {
                val line = try { reader.readLine() } catch (e: SocketException) { null }
                if (line == null) {
                    trySend(DaemonEvent.Closed)
                    break
                }
                if (line.startsWith("EXIT:")) {
                    val code = line.removePrefix("EXIT:").trim().toIntOrNull() ?: -1
                    trySend(DaemonEvent.Exit(code))
                    break
                }
                trySend(DaemonEvent.Line(line))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            trySend(DaemonEvent.Error(e.message ?: e.javaClass.simpleName))
        } finally {
            try { socket.close() } catch (_: Exception) {}
            close()
        }

        awaitClose {
            try { socket.close() } catch (_: Exception) {}
        }
    }.flowOn(Dispatchers.IO)

    private fun buildEnv(script: ScriptType, p: DeviceProfile): List<Pair<String, String>> {
        val base = mutableListOf(
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
                base += listOf(
                    "QUICK_MEMTEST_PERCENT"   to p.quickMemtestPercent.toString(),
                    "QUICK_MEMTEST_MAX_MB"    to p.quickMemtestMaxMb.toString(),
                    "QUICK_MEMTEST_MIN_MB"    to p.quickMemtestMinMb.toString(),
                    "QUICK_MEMTEST_LOOPS"     to p.quickMemtestLoops.toString(),
                    "QUICK_MEMTEST_TIMEOUT_S" to p.quickMemtestTimeoutS.toString(),
                )
            }
            ScriptType.DEEP_RAM -> {
                base += listOf(
                    "MEMTEST_PERCENT"   to p.deepMemtestPercent.toString(),
                    "MEMTEST_MAX_MB"    to p.deepMemtestMaxMb.toString(),
                    "MEMTEST_LOOPS"     to p.deepMemtestLoops.toString(),
                    "MEMTEST_TIMEOUT_S" to p.deepMemtestTimeoutS.toString(),
                    "MIN_MEMTEST_MB"    to p.deepMemtestMinMb.toString(),
                )
            }
        }
        return base
    }
}

/** Eventos emitidos durante a execucao remota. */
sealed class DaemonEvent {
    data class Line(val text: String) : DaemonEvent()
    data class Exit(val code: Int) : DaemonEvent()
    data class Error(val message: String) : DaemonEvent()
    object Closed : DaemonEvent()
}

/** Remove caracteres nao-ASCII e os bloqueados pelo daemon (', ", `, $, \). */
private fun String.ascii(): String =
    filter { c ->
        c.code in 32..126 && c != '\'' && c != '"' && c != '`' && c != '$' && c != '\\'
    }
