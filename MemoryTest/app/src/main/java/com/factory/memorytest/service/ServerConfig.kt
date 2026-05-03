package com.factory.memorytest.service

import android.content.Context
import android.content.SharedPreferences

/**
 * Endereco do servidor local (Wi-Fi) que hospeda os JSONs de configuracao.
 * Persistido em SharedPreferences para que uma tela de Settings futura
 * possa alterar sem mexer no codigo.
 */
class ServerConfig(context: Context) {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    var baseUrl: String
        get() = prefs.getString(KEY_BASE_URL, DEFAULT_BASE_URL) ?: DEFAULT_BASE_URL
        set(value) = prefs.edit().putString(KEY_BASE_URL, normalizeBase(value)).apply()

    fun defaultProfileUrl(): String = baseUrl + DEFAULT_PROFILE_FILE

    fun profileUrlFor(fileName: String): String = baseUrl + fileName

    companion object {
        private const val PREFS = "server_config"
        private const val KEY_BASE_URL = "base_url"

        const val DEFAULT_BASE_URL = "http://192.168.0.1/"
        const val DEFAULT_PROFILE_FILE = "default_memtest.json"

        private fun normalizeBase(value: String): String =
            if (value.endsWith("/")) value else "$value/"
    }
}
