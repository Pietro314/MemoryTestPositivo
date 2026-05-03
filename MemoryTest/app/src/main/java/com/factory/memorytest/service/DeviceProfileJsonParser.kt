package com.factory.memorytest.service

import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.StorageClass
import org.json.JSONObject
import java.io.InputStream

/**
 * Le um JSON de DeviceProfile. Schema flat — chaves no nivel raiz, batendo com
 * os campos de DeviceProfile.kt. Campos faltantes herdam do perfil fallback.
 *
 * Toleramos numeros vindos como string (alguns servidores serializam tudo como
 * string) usando getIntFlexible.
 */
object DeviceProfileJsonParser {

    fun parse(input: InputStream, fallback: DeviceProfile): DeviceProfile {
        val text = input.bufferedReader(Charsets.UTF_8).use { it.readText() }
        val json = JSONObject(text)

        return fallback.copy(
            name = json.optStringOrNull("name") ?: fallback.name,
            manufacturer = json.optStringOrNull("manufacturer") ?: fallback.manufacturer,
            modelCode = json.optStringOrNull("modelCode") ?: fallback.modelCode,
            notes = json.optStringOrNull("notes") ?: fallback.notes,

            expectedRamGb = json.getIntFlexible("expectedRamGb", fallback.expectedRamGb),
            expectedStorageGb = json.getIntFlexible("expectedStorageGb", fallback.expectedStorageGb),
            storageClass = json.optStringOrNull("storageClass")
                ?.let { StorageClass.fromNameOrCustom(it) }
                ?: fallback.storageClass,

            minWriteMbps = json.getIntFlexible("minWriteMbps", fallback.minWriteMbps),
            minReadMbps = json.getIntFlexible("minReadMbps", fallback.minReadMbps),
            storageTestSizeMb = json.getIntFlexible("storageTestSizeMb", fallback.storageTestSizeMb),

            quickMemtestPercent = json.getIntFlexible("quickMemtestPercent", fallback.quickMemtestPercent),
            quickMemtestMaxMb = json.getIntFlexible("quickMemtestMaxMb", fallback.quickMemtestMaxMb),
            quickMemtestMinMb = json.getIntFlexible("quickMemtestMinMb", fallback.quickMemtestMinMb),
            quickMemtestLoops = json.getIntFlexible("quickMemtestLoops", fallback.quickMemtestLoops),
            quickMemtestTimeoutS = json.getIntFlexible("quickMemtestTimeoutS", fallback.quickMemtestTimeoutS),

            deepMemtestPercent = json.getIntFlexible("deepMemtestPercent", fallback.deepMemtestPercent),
            deepMemtestMaxMb = json.getIntFlexible("deepMemtestMaxMb", fallback.deepMemtestMaxMb),
            deepMemtestMinMb = json.getIntFlexible("deepMemtestMinMb", fallback.deepMemtestMinMb),
            deepMemtestLoops = json.getIntFlexible("deepMemtestLoops", fallback.deepMemtestLoops),
            deepMemtestTimeoutS = json.getIntFlexible("deepMemtestTimeoutS", fallback.deepMemtestTimeoutS),
        )
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        val raw = optString(key, "").trim()
        return raw.ifEmpty { null }
    }

    private fun JSONObject.getIntFlexible(key: String, default: Int): Int {
        if (!has(key) || isNull(key)) return default
        return when (val v = get(key)) {
            is Int -> v
            is Long -> v.toInt()
            is Number -> v.toInt()
            is String -> v.trim().toIntOrNull() ?: default
            else -> default
        }
    }
}
