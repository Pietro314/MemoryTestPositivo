package com.factory.memorytest.ui.testrun

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.recyclerview.widget.LinearLayoutManager
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivityTestRunBinding
import com.factory.memorytest.domain.ScriptType
import com.factory.memorytest.service.ScriptOutputParser
import com.google.android.material.tabs.TabLayout
import java.io.File
import java.util.Locale

class TestRunActivity : AppCompatActivity() {

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"
        private const val EXTRA_SCRIPT_TYPE = "script_type"

        fun intent(ctx: Context, deviceId: Long, type: ScriptType): Intent =
            Intent(ctx, TestRunActivity::class.java)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
                .putExtra(EXTRA_SCRIPT_TYPE, type.name)
    }

    private lateinit var binding: ActivityTestRunBinding
    private val vm: TestRunViewModel by viewModels()
    private lateinit var stepAdapter: StepAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityTestRunBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.toolbar.setNavigationOnClickListener { onBackPressedDispatcher.onBackPressed() }

        stepAdapter = StepAdapter()
        binding.rvSteps.layoutManager = LinearLayoutManager(this)
        binding.rvSteps.adapter = stepAdapter

        setupTabs()

        binding.fabAbort.setOnClickListener { vm.abort() }
        binding.btnBack.setOnClickListener { finish() }
        binding.btnShare.setOnClickListener { shareReport() }

        bindObservers()

        if (savedInstanceState == null) {
            val deviceId = intent.getLongExtra(EXTRA_DEVICE_ID, 0L)
            val type = ScriptType.valueOf(
                intent.getStringExtra(EXTRA_SCRIPT_TYPE) ?: ScriptType.FACTORY.name
            )
            vm.start(deviceId, type)
        }
    }

    private fun setupTabs() {
        binding.tabs.addTab(binding.tabs.newTab().setText(R.string.tab_status))
        binding.tabs.addTab(binding.tabs.newTab().setText(R.string.tab_log))
        binding.tabs.addOnTabSelectedListener(object : TabLayout.OnTabSelectedListener {
            override fun onTabSelected(tab: TabLayout.Tab?) {
                val isStatus = tab?.position == 0
                binding.tabStatus.visibility = if (isStatus) View.VISIBLE else View.GONE
                binding.tabLog.visibility = if (isStatus) View.GONE else View.VISIBLE
            }
            override fun onTabUnselected(tab: TabLayout.Tab?) = Unit
            override fun onTabReselected(tab: TabLayout.Tab?) = Unit
        })
    }

    private fun bindObservers() {
        vm.device.observe(this) { profile ->
            if (profile == null) return@observe
            renderHeaderInfo(profile.name, profile.manufacturer)
        }

        vm.scriptType.observe(this) { type ->
            if (type != null) {
                binding.toolbar.title = type.displayName
            }
        }

        vm.parserState.observe(this) { state ->
            stepAdapter.submitList(state.steps)
        }

        vm.log.observe(this) { text ->
            binding.tvLog.text = text
            binding.svLog.post { binding.svLog.fullScroll(View.FOCUS_DOWN) }
        }

        vm.elapsedMs.observe(this) { ms ->
            binding.tvElapsed.text = formatElapsed(ms)
        }

        vm.phase.observe(this) { phase ->
            when (phase) {
                TestRunViewModel.Phase.PREPARING -> {
                    setBanner(BannerStyle.NEUTRAL, getString(R.string.title_running), "Conectando ao daemon…")
                }
                TestRunViewModel.Phase.RUNNING -> {
                    setBanner(BannerStyle.RUNNING, getString(R.string.status_running), "Executando script…")
                    binding.fabAbort.visibility = View.VISIBLE
                    binding.postActions.visibility = View.GONE
                }
                TestRunViewModel.Phase.FINISHED -> {
                    binding.fabAbort.visibility = View.GONE
                    binding.postActions.visibility = View.VISIBLE
                }
                TestRunViewModel.Phase.ERROR -> {
                    setBanner(BannerStyle.FAIL, "ERRO", "Falha ao iniciar")
                    binding.fabAbort.visibility = View.GONE
                    binding.postActions.visibility = View.VISIBLE
                }
                else -> Unit
            }
        }

        vm.finalResult.observe(this) { result ->
            if (result == null) return@observe
            when (result) {
                "PASS" -> setBanner(BannerStyle.PASS, "PASS", "Device aprovado")
                "FAIL" -> setBanner(BannerStyle.FAIL, "FAIL", "Falha detectada")
                "ABORTED" -> setBanner(BannerStyle.NEUTRAL, "ABORTADO", "Operador interrompeu")
                else -> setBanner(BannerStyle.NEUTRAL, result, "")
            }
        }
    }

    private fun renderHeaderInfo(deviceName: String, manufacturer: String) {
        val parent: LinearLayout = binding.headerInfo
        parent.removeAllViews()
        val inflater = LayoutInflater.from(this)
        listOf(
            "Device" to deviceName,
            "Fabricante" to manufacturer.ifBlank { "—" },
        ).forEachIndexed { idx, (k, v) ->
            val view = inflater.inflate(R.layout.row_kv, parent, false)
            view.findViewById<TextView>(R.id.tvKey).text = k
            view.findViewById<TextView>(R.id.tvValue).text = v
            view.findViewById<View>(R.id.divider).visibility = if (idx == 1) View.GONE else View.VISIBLE
            parent.addView(view)
        }
    }

    private fun formatElapsed(ms: Long): String {
        val total = ms / 1000
        val mm = total / 60
        val ss = total % 60
        return String.format(Locale.US, "%02d:%02d", mm, ss)
    }

    private enum class BannerStyle { NEUTRAL, RUNNING, PASS, FAIL }

    private fun setBanner(style: BannerStyle, title: String, subtitle: String) {
        val (bgColor, iconRes, iconColor) = when (style) {
            BannerStyle.NEUTRAL -> Triple(R.color.md_secondary_container, R.drawable.ic_pending, R.color.status_pending)
            BannerStyle.RUNNING -> Triple(R.color.md_primary_container, R.drawable.ic_running, R.color.status_running)
            BannerStyle.PASS -> Triple(R.color.md_primary_container, R.drawable.ic_check, R.color.status_pass)
            BannerStyle.FAIL -> Triple(R.color.md_primary_container, R.drawable.ic_close, R.color.status_fail)
        }
        binding.resultBanner.setCardBackgroundColor(ContextCompat.getColor(this, bgColor))
        binding.ivBannerIcon.setImageResource(iconRes)
        binding.ivBannerIcon.setColorFilter(ContextCompat.getColor(this, iconColor))
        binding.tvBannerStatus.text = title
        binding.tvBannerSubtitle.text = subtitle
    }

    private fun shareReport() {
        val path = vm.reportPath.value
        if (path.isNullOrBlank()) {
            AlertDialog.Builder(this)
                .setMessage("Relatório ainda não disponível.")
                .setPositiveButton(android.R.string.ok, null)
                .show()
            return
        }
        val file = File(path)
        if (!file.exists()) return
        val uri: Uri = try {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        } catch (e: IllegalArgumentException) {
            Uri.fromFile(file)
        }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, getString(R.string.action_share_report)))
    }
}
