package com.factory.memorytest.ui.dashboard

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivityDashboardBinding
import com.factory.memorytest.domain.DefaultDeviceProfile
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.service.DeviceProfileJsonClient
import com.factory.memorytest.service.ServerConfig
import com.factory.memorytest.ui.devicedetail.DeviceDetailActivity
import com.factory.memorytest.ui.devicelist.DeviceListActivity
import com.factory.memorytest.ui.history.HistoryActivity
import com.factory.memorytest.ui.settings.SettingsActivity
import com.google.android.material.snackbar.Snackbar
import kotlinx.coroutines.launch

class DashboardActivity : AppCompatActivity() {

    private lateinit var binding: ActivityDashboardBinding

    private val deviceRepo by lazy { (application as MemoryTestApp).deviceRepo }
    private val profileClient by lazy { DeviceProfileJsonClient(ServerConfig(this)) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityDashboardBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.cardDefaultTest.setOnClickListener { runDefaultTest() }
        binding.cardImportTest.setOnClickListener { runImportTest() }
        binding.cardRegisterDevice.setOnClickListener {
            startActivity(Intent(this, DeviceListActivity::class.java))
        }

        binding.toolbar.setOnMenuItemClickListener { mi ->
            when (mi.itemId) {
                R.id.action_history -> {
                    startActivity(Intent(this, HistoryActivity::class.java))
                    true
                }
                R.id.action_settings -> {
                    startActivity(Intent(this, SettingsActivity::class.java))
                    true
                }
                else -> false
            }
        }
    }

    private fun runDefaultTest() {
        binding.cardDefaultTest.isEnabled = false
        val loading = Snackbar.make(
            binding.root, R.string.dashboard_default_loading, Snackbar.LENGTH_INDEFINITE
        ).also { it.show() }

        lifecycleScope.launch {
            try {
                val profile = resolveDefaultProfile()
                if (profile == null) {
                    Snackbar.make(
                        binding.root, R.string.dashboard_default_no_device, Snackbar.LENGTH_LONG
                    ).show()
                    return@launch
                }
                startActivity(DeviceDetailActivity.intent(this@DashboardActivity, profile.id))
            } finally {
                loading.dismiss()
                binding.cardDefaultTest.isEnabled = true
            }
        }
    }

    /**
     * Tenta baixar default_memtest.json do servidor local. Em sucesso, persiste
     * sobre a linha "Default(T2070D)" (ou cria) e devolve o perfil. Em falha,
     * devolve a linha embarcada do banco. Retorna null somente se nem mesmo
     * o seed embutido existir (ex: usuario apagou e DB ainda nao reinseriu).
     */
    private suspend fun resolveDefaultProfile(): DeviceProfile? {
        val embedded = deviceRepo.findByMarker(
            DefaultDeviceProfile.NAME, DefaultDeviceProfile.MODEL_CODE
        ) ?: DefaultDeviceProfile.build().let {
            val id = deviceRepo.upsert(it)
            it.copy(id = id)
        }

        val result = profileClient.fetchDefault(embedded)
        return result.fold(
            onSuccess = { fetched ->
                val merged = fetched.copy(id = embedded.id)
                val id = deviceRepo.upsert(merged)
                Snackbar.make(
                    binding.root, R.string.dashboard_default_from_server, Snackbar.LENGTH_SHORT
                ).show()
                merged.copy(id = id)
            },
            onFailure = {
                Snackbar.make(
                    binding.root, R.string.dashboard_default_from_embedded, Snackbar.LENGTH_SHORT
                ).show()
                embedded
            }
        )
    }

    /**
     * Identifica o device atual via Build.DEVICE e tenta baixar o JSON
     * específico (`<Build.DEVICE>.json`). Em sucesso, persiste o perfil no
     * Room (upsert por marker name+modelCode) e abre DeviceDetailActivity.
     * Em falha, mostra aviso e cai no fluxo do "Teste Default".
     */
    private fun runImportTest() {
        val deviceId = Build.DEVICE.orEmpty().ifBlank { "desconhecido" }

        binding.cardImportTest.isEnabled = false
        val loading = Snackbar.make(
            binding.root,
            getString(R.string.dashboard_import_loading, deviceId),
            Snackbar.LENGTH_INDEFINITE,
        ).also { it.show() }

        lifecycleScope.launch {
            try {
                val profile = resolveImportedProfile(deviceId)
                if (profile == null) {
                    Snackbar.make(
                        binding.root, R.string.dashboard_default_no_device, Snackbar.LENGTH_LONG
                    ).show()
                    return@launch
                }
                startActivity(DeviceDetailActivity.intent(this@DashboardActivity, profile.id))
            } finally {
                loading.dismiss()
                binding.cardImportTest.isEnabled = true
            }
        }
    }

    private suspend fun resolveImportedProfile(deviceId: String): DeviceProfile? {
        val result = profileClient.fetchForDevice(deviceId, DefaultDeviceProfile.build())

        return result.fold(
            onSuccess = { fetched ->
                // Upsert pelo marker do JSON (name+modelCode), preservando id se já existir.
                val existing = deviceRepo.findByMarker(fetched.name, fetched.modelCode)
                val toSave = fetched.copy(id = existing?.id ?: 0L)
                val id = deviceRepo.upsert(toSave)
                Snackbar.make(
                    binding.root,
                    getString(R.string.dashboard_import_success, deviceId),
                    Snackbar.LENGTH_SHORT,
                ).show()
                toSave.copy(id = id)
            },
            onFailure = {
                Snackbar.make(
                    binding.root,
                    getString(
                        R.string.dashboard_import_fallback,
                        deviceId,
                        DefaultDeviceProfile.NAME,
                    ),
                    Snackbar.LENGTH_LONG,
                ).show()
                resolveDefaultProfile()
            }
        )
    }
}
