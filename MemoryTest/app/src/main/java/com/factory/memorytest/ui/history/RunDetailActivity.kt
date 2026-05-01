package com.factory.memorytest.ui.history

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.recyclerview.widget.LinearLayoutManager
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.R
import com.factory.memorytest.data.db.TestRunEntity
import com.factory.memorytest.data.db.TestStepEntity
import com.factory.memorytest.databinding.ActivityRunDetailBinding
import com.factory.memorytest.domain.ScriptType
import com.factory.memorytest.service.ScriptOutputParser
import com.factory.memorytest.ui.testrun.StepAdapter
import com.google.android.material.tabs.TabLayout
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class RunDetailActivity : AppCompatActivity() {

    companion object {
        private const val EXTRA_RUN_ID = "run_id"
        fun intent(ctx: Context, runId: Long): Intent =
            Intent(ctx, RunDetailActivity::class.java).putExtra(EXTRA_RUN_ID, runId)
    }

    private lateinit var binding: ActivityRunDetailBinding
    private val vm: RunDetailViewModel by viewModels()
    private lateinit var stepAdapter: StepAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityRunDetailBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.toolbar.setNavigationOnClickListener { finish() }

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

        stepAdapter = StepAdapter()
        binding.rvSteps.layoutManager = LinearLayoutManager(this)
        binding.rvSteps.adapter = stepAdapter

        val runId = intent.getLongExtra(EXTRA_RUN_ID, 0L)
        vm.run(runId).observe(this) { run ->
            if (run == null) { finish(); return@observe }
            renderRun(run)
        }
        vm.steps(runId).observe(this) { steps ->
            stepAdapter.submitList(steps.map { it.toUiStep() })
        }

        binding.btnShare.setOnClickListener { shareCurrentReport() }
    }

    private var currentRun: TestRunEntity? = null

    private fun renderRun(run: TestRunEntity) {
        currentRun = run
        val type = ScriptType.fromShortLabelOrNull(run.scriptType)
        binding.toolbar.title = "${run.deviceNameSnapshot} • ${type?.shortLabel ?: run.scriptType}"

        val parent: LinearLayout = binding.headerInfo
        parent.removeAllViews()
        val inflater = LayoutInflater.from(this)
        val df = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
        val rows = listOf(
            "Device" to run.deviceNameSnapshot,
            "Fabricante" to run.deviceManufacturerSnapshot.ifBlank { "—" },
            "Iniciado" to df.format(Date(run.startedAt)),
            "Duração" to (run.durationMs?.let { "${it / 1000} s" } ?: "—"),
            "Resultado" to run.result,
            "Exit code" to (run.exitCode?.toString() ?: "—"),
        )
        rows.forEachIndexed { idx, (k, v) ->
            val view = inflater.inflate(R.layout.row_kv, parent, false)
            view.findViewById<TextView>(R.id.tvKey).text = k
            view.findViewById<TextView>(R.id.tvValue).text = v
            view.findViewById<View>(R.id.divider).visibility =
                if (idx == rows.lastIndex) View.GONE else View.VISIBLE
            parent.addView(view)
        }

        // Carrega log do arquivo
        val path = run.logFilePath
        if (!path.isNullOrBlank()) {
            val f = File(path)
            binding.tvLog.text = if (f.exists()) f.readText() else "[Arquivo de log não encontrado]"
        } else {
            binding.tvLog.text = "[Sem log salvo]"
        }
    }

    private fun TestStepEntity.toUiStep(): ScriptOutputParser.Step {
        val st = runCatching { ScriptOutputParser.StepStatus.valueOf(status) }
            .getOrDefault(ScriptOutputParser.StepStatus.PENDING)
        return ScriptOutputParser.Step(
            key = stepKey,
            label = stepLabel,
            status = st,
            summary = summary,
            details = details,
            orderIndex = orderIndex,
        )
    }

    private fun shareCurrentReport() {
        val path = currentRun?.logFilePath ?: return
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

class RunDetailViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = (app as MemoryTestApp).runRepo
    fun run(id: Long): LiveData<TestRunEntity?> = repo.observeRun(id)
    fun steps(id: Long): LiveData<List<TestStepEntity>> = repo.observeSteps(id)
}
