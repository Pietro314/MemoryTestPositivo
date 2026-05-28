package com.factory.memorytest.service

import com.factory.memorytest.domain.DefaultDeviceProfile
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.StorageClass
import org.json.JSONObject

/**
 * Parseia o JSON consolidado de varios devices. O JSON tem o formato:
 *
 * ```
 * {
 *   "schema_version": 1,
 *   "profiles": [
 *     { "device": "T2070D", "ramGb": 4, ... },
 *     { "device": "T2070D", "ramGb": 8, ... },
 *     { "device": "TL10", "ramGb": 8, ... }
 *   ]
 * }
 * ```
 *
 * O match e por (device, ramGb) — permite ter o mesmo device com SKUs de
 * RAM diferentes (ex: T2070D-4GB e T2070D-8GB).
 */
object MemoryTestConfigParser {

    sealed class LookupResult {
        data class Found(val profile: DeviceProfile) : LookupResult()
        data class NotFound(val device: String, val ramGb: Int) : LookupResult()
        data class Invalid(val reason: String) : LookupResult()
    }

    fun findProfile(root: JSONObject, device: String, ramGb: Int): LookupResult {
        val profiles = root.optJSONArray("profiles")
            ?: return LookupResult.Invalid("JSON nao contem array 'profiles'")

        for (i in 0 until profiles.length()) {
            val entry = profiles.optJSONObject(i) ?: continue
            val entryDevice = entry.optString("device").trim()
            val entryRamGb = entry.optInt("ramGb", -1)

            if (entryDevice.equals(device, ignoreCase = false) && entryRamGb == ramGb) {
                val profile = entryToProfile(entry) ?: return LookupResult.Invalid(
                    "Entrada para $device/$ramGb GB esta malformada"
                )
                return LookupResult.Found(profile)
            }
        }
        return LookupResult.NotFound(device, ramGb)
    }

    private fun entryToProfile(entry: JSONObject): DeviceProfile? {
        // DefaultDeviceProfile e usado como base pra herdar shapes/copy(),
        // mas campos descritivos (name, manufacturer, modelCode, notes)
        // NAO devem herdar valores do default — quando o JSON nao trouxer,
        // ficam vazios ou auto-gerados (o teste detecta sozinho via
        // getprop / sysfs e poe o valor real no relatorio).
        val fallback = DefaultDeviceProfile.build()

        val storageClass = entry.optStringOrNull("storageClass")
            ?.let { StorageClass.fromNameOrCustom(it) }
            ?: fallback.storageClass

        return fallback.copy(
            name = entry.optStringOrNull("name")
                ?: "${entry.optString("device")} (${entry.optInt("ramGb")}GB)",
            manufacturer = entry.optStringOrNull("manufacturer") ?: "",
            modelCode = entry.optStringOrNull("modelCode") ?: "",
            notes = entry.optStringOrNull("notes") ?: "",

            expectedRamGb = entry.optInt("ramGb", fallback.expectedRamGb),
            expectedStorageGb = entry.getIntFlexible("expectedStorageGb", fallback.expectedStorageGb),
            storageClass = storageClass,

            minWriteMbps = entry.getIntFlexible("minWriteMbps", fallback.minWriteMbps),
            minReadMbps = entry.getIntFlexible("minReadMbps", fallback.minReadMbps),
            storageTestSizeMb = entry.getIntFlexible("storageTestSizeMb", fallback.storageTestSizeMb),

            quickMemtestPercent = entry.nestedInt("quickMemtest", "percent", fallback.quickMemtestPercent),
            quickMemtestMaxMb = entry.nestedInt("quickMemtest", "maxMb", fallback.quickMemtestMaxMb),
            quickMemtestMinMb = entry.nestedInt("quickMemtest", "minMb", fallback.quickMemtestMinMb),
            quickMemtestLoops = entry.nestedInt("quickMemtest", "loops", fallback.quickMemtestLoops),
            quickMemtestTimeoutS = entry.nestedInt("quickMemtest", "timeoutS", fallback.quickMemtestTimeoutS),

            deepMemtestPercent = entry.nestedInt("deepMemtest", "percent", fallback.deepMemtestPercent),
            deepMemtestMaxMb = entry.nestedInt("deepMemtest", "maxMb", fallback.deepMemtestMaxMb),
            deepMemtestMinMb = entry.nestedInt("deepMemtest", "minMb", fallback.deepMemtestMinMb),
            deepMemtestLoops = entry.nestedInt("deepMemtest", "loops", fallback.deepMemtestLoops),
            deepMemtestTimeoutS = entry.nestedInt("deepMemtest", "timeoutS", fallback.deepMemtestTimeoutS),
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

    private fun JSONObject.nestedInt(parentKey: String, childKey: String, default: Int): Int {
        val parent = optJSONObject(parentKey) ?: return default
        return parent.getIntFlexible(childKey, default)
    }
}
