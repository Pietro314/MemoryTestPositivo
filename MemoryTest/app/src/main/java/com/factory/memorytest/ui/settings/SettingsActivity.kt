package com.factory.memorytest.ui.settings

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivitySettingsBinding
import com.factory.memorytest.service.ServerConfig
import com.google.android.material.snackbar.Snackbar

class SettingsActivity : AppCompatActivity() {

    private lateinit var binding: ActivitySettingsBinding
    private lateinit var serverConfig: ServerConfig

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        serverConfig = ServerConfig(this)

        binding.toolbar.setNavigationOnClickListener { finish() }

        binding.etServerUrl.setText(serverConfig.baseUrl)
        updatePreview(serverConfig.baseUrl)

        binding.etServerUrl.addTextChangedListener(
            afterTextChanged = { text -> updatePreview(text) }
        )

        binding.fabSave.setOnClickListener { save() }
    }

    private fun updatePreview(rawUrl: String) {
        val normalized = if (rawUrl.endsWith("/")) rawUrl else "$rawUrl/"
        binding.tvDefaultJsonPreview.text = getString(
            R.string.settings_default_json_preview,
            normalized + ServerConfig.DEFAULT_PROFILE_FILE,
        )
    }

    private fun save() {
        val raw = binding.etServerUrl.text?.toString()?.trim().orEmpty()
        if (!isValidBaseUrl(raw)) {
            binding.tilServerUrl.error = getString(R.string.settings_server_url_invalid)
            return
        }
        binding.tilServerUrl.error = null
        serverConfig.baseUrl = raw
        Snackbar.make(binding.root, R.string.settings_saved, Snackbar.LENGTH_SHORT).show()
        finish()
    }

    private fun isValidBaseUrl(value: String): Boolean {
        if (value.isBlank()) return false
        if (!value.startsWith("http://") && !value.startsWith("https://")) return false
        // Pelo menos um caracter de host depois do esquema
        val afterScheme = value.substringAfter("://")
        return afterScheme.isNotBlank()
    }
}

private fun com.google.android.material.textfield.TextInputEditText.addTextChangedListener(
    afterTextChanged: (String) -> Unit,
) {
    addTextChangedListener(object : android.text.TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: android.text.Editable?) {
            afterTextChanged(s?.toString().orEmpty())
        }
    })
}
