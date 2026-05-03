package com.factory.memorytest.service

import com.factory.memorytest.domain.DeviceProfile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Faz GET de um JSON de DeviceProfile no servidor local e converte em DeviceProfile.
 * Sucesso/falha encapsulados em Result — chamadores caem no fallback embutido em Failure.
 */
class DeviceProfileJsonClient(
    private val config: ServerConfig,
    private val connectTimeoutMs: Int = 4_000,
    private val readTimeoutMs: Int = 4_000,
) {

    suspend fun fetchDefault(fallback: DeviceProfile): Result<DeviceProfile> =
        fetch(config.defaultProfileUrl(), fallback)

    /**
     * Baixa o JSON específico do device atual usando Build.DEVICE como chave.
     * Convenção: arquivo chamado `<Build.DEVICE>.json` na raiz do servidor.
     * Ex: device TL10 → http://server/TL10.json
     */
    suspend fun fetchForDevice(deviceId: String, fallback: DeviceProfile): Result<DeviceProfile> =
        fetch(config.profileUrlFor("${deviceId}.json"), fallback)

    suspend fun fetch(urlString: String, fallback: DeviceProfile): Result<DeviceProfile> =
        withContext(Dispatchers.IO) {
            runCatching {
                val conn = (URL(urlString).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = connectTimeoutMs
                    readTimeout = readTimeoutMs
                    setRequestProperty("Accept", "application/json")
                    instanceFollowRedirects = true
                }
                try {
                    val code = conn.responseCode
                    if (code !in 200..299) {
                        error("HTTP $code")
                    }
                    conn.inputStream.use { stream ->
                        DeviceProfileJsonParser.parse(stream, fallback)
                    }
                } finally {
                    conn.disconnect()
                }
            }
        }
}
