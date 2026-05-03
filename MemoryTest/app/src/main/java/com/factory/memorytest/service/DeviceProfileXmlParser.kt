package com.factory.memorytest.service

import android.util.Xml
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.StorageClass
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream

/**
 * Le um XML de DeviceProfile. Schema flat (todos os campos como elementos diretos
 * de <deviceProfile>). Nomes batem com os campos de DeviceProfile.kt.
 *
 * Campos faltantes herdam do default embutido — tolerante a XMLs minimos do servidor.
 */
object DeviceProfileXmlParser {

    fun parse(input: InputStream, fallback: DeviceProfile): DeviceProfile {
        val parser = Xml.newPullParser().apply {
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            setInput(input, null)
        }

        val values = mutableMapOf<String, String>()
        var event = parser.eventType
        var currentTag: String? = null

        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> currentTag = parser.name
                XmlPullParser.TEXT -> {
                    val tag = currentTag
                    if (tag != null && tag != "deviceProfile") {
                        val text = parser.text?.trim().orEmpty()
                        if (text.isNotEmpty()) values[tag] = text
                    }
                }
                XmlPullParser.END_TAG -> currentTag = null
            }
            event = parser.next()
        }

        return fallback.copy(
            name = values["name"] ?: fallback.name,
            manufacturer = values["manufacturer"] ?: fallback.manufacturer,
            modelCode = values["modelCode"] ?: fallback.modelCode,
            notes = values["notes"] ?: fallback.notes,

            expectedRamGb = values.intOr("expectedRamGb", fallback.expectedRamGb),
            expectedStorageGb = values.intOr("expectedStorageGb", fallback.expectedStorageGb),
            storageClass = values["storageClass"]?.let { StorageClass.fromNameOrCustom(it) }
                ?: fallback.storageClass,

            minWriteMbps = values.intOr("minWriteMbps", fallback.minWriteMbps),
            minReadMbps = values.intOr("minReadMbps", fallback.minReadMbps),
            storageTestSizeMb = values.intOr("storageTestSizeMb", fallback.storageTestSizeMb),

            quickMemtestPercent = values.intOr("quickMemtestPercent", fallback.quickMemtestPercent),
            quickMemtestMaxMb = values.intOr("quickMemtestMaxMb", fallback.quickMemtestMaxMb),
            quickMemtestMinMb = values.intOr("quickMemtestMinMb", fallback.quickMemtestMinMb),
            quickMemtestLoops = values.intOr("quickMemtestLoops", fallback.quickMemtestLoops),
            quickMemtestTimeoutS = values.intOr("quickMemtestTimeoutS", fallback.quickMemtestTimeoutS),

            deepMemtestPercent = values.intOr("deepMemtestPercent", fallback.deepMemtestPercent),
            deepMemtestMaxMb = values.intOr("deepMemtestMaxMb", fallback.deepMemtestMaxMb),
            deepMemtestMinMb = values.intOr("deepMemtestMinMb", fallback.deepMemtestMinMb),
            deepMemtestLoops = values.intOr("deepMemtestLoops", fallback.deepMemtestLoops),
            deepMemtestTimeoutS = values.intOr("deepMemtestTimeoutS", fallback.deepMemtestTimeoutS),
        )
    }

    private fun Map<String, String>.intOr(key: String, default: Int): Int =
        this[key]?.toIntOrNull() ?: default
}
