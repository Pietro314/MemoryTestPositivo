package com.factory.memorytest.ui.autotest

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import com.factory.memorytest.R
import com.factory.memorytest.service.AutoTestLogWriter
import com.factory.memorytest.service.AutoTestResultWriter
import com.factory.memorytest.service.ScriptOutputParser
import com.google.android.material.button.MaterialButton
import com.google.android.material.card.MaterialCardView
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Activity exposta por intent-filter:
 *   Intent("com.factory.memorytest.action.AUTO_TEST")
 *       .setPackage("com.factory.memorytest")
 *
 * Roda factory + deep em sequencia (ver AutoTestViewModel) e renderiza
 * progresso em UI Material 3.
 */
class AutoTestActivity : AppCompatActivity() {

    private val viewModel: AutoTestViewModel by lazy {
        ViewModelProvider(this)[AutoTestViewModel::class.java]
    }

    private lateinit var banner: MaterialCardView
    private lateinit var ivBannerIcon: ImageView
    private lateinit var tvBannerTitle: TextView
    private lateinit var tvBannerSubtitle: TextView
    private lateinit var tvElapsed: TextView
    private lateinit var tvHeaderInfo: TextView

    private lateinit var ivFactoryIcon: ImageView
    private lateinit var tvFactoryStatus: TextView
    private lateinit var tvFactorySummary: TextView

    private lateinit var ivDeepIcon: ImageView
    private lateinit var tvDeepStatus: TextView
    private lateinit var tvDeepSummary: TextView

    private lateinit var btnStop: MaterialButton
    private lateinit var btnOk: MaterialButton

    private val resultWriter by lazy { AutoTestResultWriter(applicationContext) }
    private val logWriter by lazy { AutoTestLogWriter() }
    private var resultEmitted = false
    private var acquiredLock = false
    private var wakeLock: PowerManager.WakeLock? = null

    private val stopReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_STOP_TEST) {
                Log.i(TAG, "STOP_TEST broadcast recebido")
                viewModel.stop()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_auto_test)

        bindViews()

        // Concurrency guard: rejeita segundo trigger se ja tem teste rolando
        if (!isRunning.compareAndSet(false, true)) {
            Log.w(TAG, "Outro AutoTest ja rodando — rejeitando")
            resultWriter.writeAndBroadcast(
                device = Build.DEVICE ?: "",
                ramGb = readRamGbBestEffort(),
                profile = null,
                overall = "ERROR",
                errorMessage = "BUSY: outro AutoTest ja esta em execucao",
            )
            tvBannerTitle.text = "BUSY"
            tvBannerSubtitle.text = "Outro AutoTest ja esta rodando"
            ivBannerIcon.setImageResource(R.drawable.ic_warning)
            tintBanner(R.color.status_fail)
            btnStop.visibility = View.GONE
            btnOk.visibility = View.VISIBLE
            btnOk.setOnClickListener { finish() }
            resultEmitted = true
            return
        }
        acquiredLock = true

        // WakeLock PARTIAL: CPU acordada durante o teste (memtester nao pode pausar)
        // FLAG_KEEP_SCREEN_ON ja garante tela ligada, mas alguns devices entram
        // em deep sleep de CPU mesmo com tela on. Com PARTIAL_WAKE_LOCK, CPU fica.
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG::wake").apply {
            setReferenceCounted(false)
            // Timeout maximo 70 min (deep tem timeout interno de 60 min — dao 10 min de folga)
            acquire(70 * 60 * 1000L)
        }

        btnStop.setOnClickListener { viewModel.stop() }
        btnOk.setOnClickListener { finish() }

        lifecycleScope.launch {
            viewModel.stage.collect { stage -> render(stage) }
        }

        if (savedInstanceState == null) {
            viewModel.start()
        }
    }

    override fun onStart() {
        super.onStart()
        // Android 13+ (API 33+) exige flag explicita. STOP_TEST e mandado por
        // outros apps (factory) — RECEIVER_EXPORTED. ContextCompat cuida da
        // compatibilidade com Android < 13.
        ContextCompat.registerReceiver(
            this,
            stopReceiver,
            IntentFilter(ACTION_STOP_TEST),
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    override fun onStop() {
        super.onStop()
        try {
            unregisterReceiver(stopReceiver)
        } catch (_: IllegalArgumentException) { /* nao registrado */ }
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) try { it.release() } catch (_: Exception) {} }
        wakeLock = null
        if (acquiredLock) isRunning.set(false)
        super.onDestroy()
    }

    private fun readRamGbBestEffort(): Int {
        return try {
            val text = File("/proc/meminfo").readText()
            val line = text.lines().firstOrNull { it.startsWith("MemTotal:") } ?: return 0
            val kb = line.split(Regex("\\s+")).getOrNull(1)?.toLongOrNull() ?: 0L
            ((kb / 1024).toInt() + 1023) / 1024
        } catch (_: Exception) { 0 }
    }

    private fun bindViews() {
        banner = findViewById(R.id.banner)
        ivBannerIcon = findViewById(R.id.ivBannerIcon)
        tvBannerTitle = findViewById(R.id.tvBannerTitle)
        tvBannerSubtitle = findViewById(R.id.tvBannerSubtitle)
        tvElapsed = findViewById(R.id.tvElapsed)
        tvHeaderInfo = findViewById(R.id.tvHeaderInfo)

        ivFactoryIcon = findViewById(R.id.ivFactoryIcon)
        tvFactoryStatus = findViewById(R.id.tvFactoryStatus)
        tvFactorySummary = findViewById(R.id.tvFactorySummary)

        ivDeepIcon = findViewById(R.id.ivDeepIcon)
        tvDeepStatus = findViewById(R.id.tvDeepStatus)
        tvDeepSummary = findViewById(R.id.tvDeepSummary)

        btnStop = findViewById(R.id.btnStop)
        btnOk = findViewById(R.id.btnOk)
    }

    private fun render(stage: AutoTestViewModel.Stage) {
        when (stage) {
            is AutoTestViewModel.Stage.Idle -> {
                tvBannerTitle.text = "—"
                tvBannerSubtitle.text = ""
            }

            is AutoTestViewModel.Stage.LoadingProfile -> {
                tvBannerTitle.text = "Carregando perfil…"
                tvBannerSubtitle.text = "Lendo memorytestconfig.json"
                ivBannerIcon.setImageResource(R.drawable.ic_running)
            }

            is AutoTestViewModel.Stage.ProfileError -> {
                tvBannerTitle.text = getString(R.string.autotest_status_fail)
                tvBannerSubtitle.text = stage.message
                ivBannerIcon.setImageResource(R.drawable.ic_warning)
                tintBanner(R.color.status_fail)
                btnStop.visibility = View.GONE
                btnOk.visibility = View.VISIBLE

                emitResultOnce {
                    resultWriter.writeAndBroadcast(
                        device = Build.DEVICE ?: "",
                        ramGb = readRamGbBestEffort(),
                        profile = null,
                        overall = "ERROR",
                        errorMessage = stage.message,
                    )
                }
            }

            is AutoTestViewModel.Stage.Running -> {
                tvBannerTitle.text = getString(R.string.autotest_running)
                tvBannerSubtitle.text = stage.profile.displayName
                ivBannerIcon.setImageResource(R.drawable.ic_running)
                tvElapsed.text = formatElapsed(stage.elapsedMs)

                tvHeaderInfo.text = buildHeaderInfo(stage.device, stage.ramGb, stage.profile.name)

                // Factory card
                if (stage.factoryDone != null) {
                    renderFactoryCard(stage.factoryDone.status, stage.factoryDone.parserState, stage.factoryDone.durationMs)
                } else if (stage.phase == AutoTestViewModel.Phase.FACTORY) {
                    renderCard(
                        icon = ivFactoryIcon,
                        statusView = tvFactoryStatus,
                        summaryView = tvFactorySummary,
                        status = getString(R.string.autotest_status_running),
                        statusColor = R.color.status_running,
                        iconRes = R.drawable.ic_running,
                        summary = summaryFromSteps(stage.parserState),
                    )
                }

                // Deep card
                if (stage.phase == AutoTestViewModel.Phase.DEEP) {
                    renderCard(
                        icon = ivDeepIcon,
                        statusView = tvDeepStatus,
                        summaryView = tvDeepSummary,
                        status = getString(R.string.autotest_status_running),
                        statusColor = R.color.status_running,
                        iconRes = R.drawable.ic_running,
                        summary = summaryFromSteps(stage.parserState),
                    )
                }
            }

            is AutoTestViewModel.Stage.Finished -> {
                val overallPass = stage.overall == "PASS"
                tvBannerTitle.text =
                    if (overallPass) getString(R.string.autotest_status_pass)
                    else getString(R.string.autotest_status_fail)
                tvBannerSubtitle.text = stage.profile.displayName
                ivBannerIcon.setImageResource(if (overallPass) R.drawable.ic_check else R.drawable.ic_warning)
                tintBanner(if (overallPass) R.color.status_pass else R.color.status_fail)
                tvElapsed.text = formatElapsed(stage.factory.durationMs + (stage.deep?.durationMs ?: 0L))

                tvHeaderInfo.text = buildHeaderInfo(stage.device, stage.ramGb, stage.profile.name)

                renderFactoryCard(stage.factory.status, stage.factory.parserState, stage.factory.durationMs)
                if (stage.deep != null) {
                    renderDeepCard(stage.deep.status, stage.deep.parserState, stage.deep.durationMs)
                } else {
                    tvDeepStatus.text = getString(R.string.autotest_status_not_run)
                    tvDeepStatus.setTextColor(ContextCompat.getColor(this, R.color.status_skip))
                    ivDeepIcon.setImageResource(R.drawable.ic_close)
                    tvDeepSummary.visibility = View.GONE
                }

                btnStop.visibility = View.GONE
                btnOk.visibility = View.VISIBLE

                emitResultOnce {
                    val ts = logWriter.newRunTimestamp()
                    val serial = safeSerial()
                    logWriter.writePhaseLog(ts, stage.device, serial, stage.factory)
                    stage.deep?.let { logWriter.writePhaseLog(ts, stage.device, serial, it) }

                    resultWriter.writeAndBroadcast(
                        device = stage.device,
                        ramGb = stage.ramGb,
                        profile = stage.profile,
                        overall = stage.overall,
                        factory = stage.factory,
                        deep = stage.deep,
                    )
                }
            }

            is AutoTestViewModel.Stage.Stopped -> {
                tvBannerTitle.text = getString(R.string.autotest_status_stopped)
                tvBannerSubtitle.text = stage.profile?.displayName ?: ""
                ivBannerIcon.setImageResource(R.drawable.ic_close)
                tintBanner(R.color.status_warn)

                tvHeaderInfo.text = buildHeaderInfo(stage.device, stage.ramGb, stage.profile?.name ?: "—")

                if (stage.factory != null) {
                    renderFactoryCard(stage.factory.status, stage.factory.parserState, stage.factory.durationMs)
                } else {
                    tvFactoryStatus.text = getString(R.string.autotest_status_not_run)
                }
                if (stage.deep != null) {
                    renderDeepCard(stage.deep.status, stage.deep.parserState, stage.deep.durationMs)
                } else {
                    tvDeepStatus.text = getString(R.string.autotest_status_not_run)
                }

                btnStop.visibility = View.GONE
                btnOk.visibility = View.VISIBLE

                emitResultOnce {
                    val ts = logWriter.newRunTimestamp()
                    val serial = safeSerial()
                    stage.factory?.let { logWriter.writePhaseLog(ts, stage.device, serial, it) }
                    stage.deep?.let { logWriter.writePhaseLog(ts, stage.device, serial, it) }

                    resultWriter.writeAndBroadcast(
                        device = stage.device,
                        ramGb = stage.ramGb,
                        profile = stage.profile,
                        overall = "STOPPED",
                        factory = stage.factory,
                        deep = stage.deep,
                    )
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun safeSerial(): String = try {
        Build.SERIAL ?: ""
    } catch (e: Throwable) {
        ""
    }

    /** Emite o resultado uma unica vez — idempotente em mudancas de stage. */
    private fun emitResultOnce(block: () -> Unit) {
        if (resultEmitted) return
        resultEmitted = true
        block()
    }

    private fun renderFactoryCard(status: String, parserState: ScriptOutputParser.State, durationMs: Long) {
        renderCard(
            icon = ivFactoryIcon,
            statusView = tvFactoryStatus,
            summaryView = tvFactorySummary,
            status = "$status · ${durationMs / 1000}s",
            statusColor = colorForStatus(status),
            iconRes = iconForStatus(status),
            summary = summaryFromSteps(parserState),
        )
    }

    private fun renderDeepCard(status: String, parserState: ScriptOutputParser.State, durationMs: Long) {
        renderCard(
            icon = ivDeepIcon,
            statusView = tvDeepStatus,
            summaryView = tvDeepSummary,
            status = "$status · ${durationMs / 1000}s",
            statusColor = colorForStatus(status),
            iconRes = iconForStatus(status),
            summary = summaryFromSteps(parserState),
        )
    }

    private fun renderCard(
        icon: ImageView,
        statusView: TextView,
        summaryView: TextView,
        status: String,
        statusColor: Int,
        iconRes: Int,
        summary: String,
    ) {
        icon.setImageResource(iconRes)
        statusView.text = status
        statusView.setTextColor(ContextCompat.getColor(this, statusColor))
        if (summary.isBlank()) {
            summaryView.visibility = View.GONE
        } else {
            summaryView.visibility = View.VISIBLE
            summaryView.text = summary
        }
    }

    private fun summaryFromSteps(state: ScriptOutputParser.State): String {
        return state.steps
            .filter { it.summary.isNotBlank() }
            .joinToString(" · ") { "${it.label}: ${it.summary}" }
    }

    private fun buildHeaderInfo(device: String, ramGb: Int, profileName: String): String {
        return buildString {
            appendLine("Device  : $device")
            appendLine("RAM     : $ramGb GB")
            append("Profile : $profileName")
        }
    }

    private fun colorForStatus(status: String): Int = when (status) {
        "PASS" -> R.color.status_pass
        "FAIL" -> R.color.status_fail
        "STOPPED" -> R.color.status_warn
        "RUNNING" -> R.color.status_running
        else -> R.color.status_pending
    }

    private fun iconForStatus(status: String): Int = when (status) {
        "PASS" -> R.drawable.ic_check
        "FAIL" -> R.drawable.ic_warning
        "STOPPED" -> R.drawable.ic_close
        "RUNNING" -> R.drawable.ic_running
        else -> R.drawable.ic_pending
    }

    private fun tintBanner(colorRes: Int) {
        banner.setCardBackgroundColor(ContextCompat.getColor(this, colorRes))
    }

    companion object {
        private const val TAG = "AutoTest"
        const val ACTION_STOP_TEST = "com.factory.memorytest.action.STOP_TEST"
        private val isRunning = AtomicBoolean(false)
    }

    private fun formatElapsed(ms: Long): String {
        val totalSec = ms / 1000
        val m = totalSec / 60
        val s = totalSec % 60
        return "%02d:%02d".format(m, s)
    }
}
