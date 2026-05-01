package com.factory.memorytest.ui.history

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.LiveData
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.factory.memorytest.MemoryTestApp
import com.factory.memorytest.R
import com.factory.memorytest.data.db.TestRunEntity
import com.factory.memorytest.databinding.ActivityHistoryBinding
import com.factory.memorytest.databinding.ItemTestRunBinding
import com.factory.memorytest.domain.ScriptType
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class HistoryActivity : AppCompatActivity() {

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"
        fun intent(ctx: Context, deviceId: Long): Intent =
            Intent(ctx, HistoryActivity::class.java).putExtra(EXTRA_DEVICE_ID, deviceId)
    }

    private lateinit var binding: ActivityHistoryBinding
    private val vm: HistoryViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityHistoryBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.toolbar.setNavigationOnClickListener { finish() }

        val adapter = TestRunAdapter { run ->
            startActivity(RunDetailActivity.intent(this, run.id))
        }
        binding.rvRuns.layoutManager = LinearLayoutManager(this)
        binding.rvRuns.adapter = adapter

        val deviceId = intent.getLongExtra(EXTRA_DEVICE_ID, 0L)
        val source = if (deviceId > 0L) vm.runs(deviceId) else vm.allRuns

        source.observe(this) { runs ->
            adapter.submitList(runs)
            binding.tvEmpty.visibility = if (runs.isEmpty()) View.VISIBLE else View.GONE
            binding.rvRuns.visibility = if (runs.isEmpty()) View.GONE else View.VISIBLE
        }
    }
}

class HistoryViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = (app as MemoryTestApp).runRepo
    val allRuns: LiveData<List<TestRunEntity>> = repo.observeAll()
    fun runs(deviceId: Long): LiveData<List<TestRunEntity>> = repo.observeByDevice(deviceId)
}

class TestRunAdapter(
    private val onClick: (TestRunEntity) -> Unit,
) : ListAdapter<TestRunEntity, TestRunAdapter.VH>(DIFF) {

    private val dateFmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val b = ItemTestRunBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return VH(b)
    }

    override fun onBindViewHolder(holder: VH, position: Int) = holder.bind(getItem(position))

    inner class VH(private val b: ItemTestRunBinding) : RecyclerView.ViewHolder(b.root) {
        fun bind(run: TestRunEntity) {
            val ctx = b.root.context
            val type = ScriptType.fromShortLabelOrNull(run.scriptType)
            b.tvTitle.text = "${run.deviceNameSnapshot} — ${type?.displayName ?: run.scriptType}"
            b.tvSubtitle.text = dateFmt.format(Date(run.startedAt))

            val (iconRes, color) = when (run.result) {
                "PASS" -> R.drawable.ic_check to R.color.status_pass
                "FAIL" -> R.drawable.ic_close to R.color.status_fail
                "ABORTED" -> R.drawable.ic_warning to R.color.status_warn
                "RUNNING" -> R.drawable.ic_running to R.color.status_running
                else -> R.drawable.ic_pending to R.color.status_pending
            }
            b.ivResult.setImageResource(iconRes)
            b.ivResult.setColorFilter(ContextCompat.getColor(ctx, color))
            b.tvResult.text = run.result
            b.tvResult.setTextColor(ContextCompat.getColor(ctx, color))

            b.root.setOnClickListener { onClick(run) }
        }
    }

    companion object {
        private val DIFF = object : DiffUtil.ItemCallback<TestRunEntity>() {
            override fun areItemsTheSame(o: TestRunEntity, n: TestRunEntity) = o.id == n.id
            override fun areContentsTheSame(o: TestRunEntity, n: TestRunEntity) = o == n
        }
    }
}
