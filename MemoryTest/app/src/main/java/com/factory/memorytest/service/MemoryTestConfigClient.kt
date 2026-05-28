package com.factory.memorytest.service

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/**
 * Le o arquivo de config consolidado escrito por outro app no caminho
 * `/storage/emulated/0/Positivo/MemoryTest/memorytestconfig.json`.
 *
 * Esse arquivo contem perfis de varios devices num unico JSON. O AutoTest
 * identifica o perfil correto pelo (Build.DEVICE, ramGb).
 */
class MemoryTestConfigClient {

    suspend fun read(): Result<JSONObject> = withContext(Dispatchers.IO) {
        val file = File(CONFIG_PATH)
        if (!file.exists()) {
            return@withContext Result.failure(
                FileNotFoundException("Arquivo nao encontrado: $CONFIG_PATH")
            )
        }
        runCatching {
            val text = file.readText(Charsets.UTF_8)
            JSONObject(text)
        }
    }

    companion object {
        const val CONFIG_PATH =
            "/storage/emulated/0/Positivo/MemoryTest/memorytestconfig.json"
    }
}
