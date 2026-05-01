package com.factory.memorytest.ui.testrun

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ItemTestStepBinding
import com.factory.memorytest.service.ScriptOutputParser

class StepAdapter : ListAdapter<ScriptOutputParser.Step, StepAdapter.VH>(DIFF) {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val b = ItemTestStepBinding.inflate(
            LayoutInflater.from(parent.context), parent, false
        )
        return VH(b)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.bind(getItem(position))
    }

    class VH(private val b: ItemTestStepBinding) : RecyclerView.ViewHolder(b.root) {
        fun bind(step: ScriptOutputParser.Step) {
            b.tvStepLabel.text = step.label
            b.tvStepSummary.text = step.summary.ifBlank { defaultSummary(step.status) }
            b.tvStepStatus.text = labelFor(step.status)
            val ctx = b.root.context
            val (iconRes, color) = when (step.status) {
                ScriptOutputParser.StepStatus.PENDING -> R.drawable.ic_pending to R.color.status_pending
                ScriptOutputParser.StepStatus.RUNNING -> R.drawable.ic_running to R.color.status_running
                ScriptOutputParser.StepStatus.PASS -> R.drawable.ic_check to R.color.status_pass
                ScriptOutputParser.StepStatus.FAIL -> R.drawable.ic_close to R.color.status_fail
                ScriptOutputParser.StepStatus.WARN -> R.drawable.ic_warning to R.color.status_warn
                ScriptOutputParser.StepStatus.SKIP -> R.drawable.ic_pending to R.color.status_skip
            }
            b.ivStatus.setImageResource(iconRes)
            val tint = ContextCompat.getColor(ctx, color)
            b.ivStatus.setColorFilter(tint)
            b.tvStepStatus.setTextColor(tint)
        }

        private fun defaultSummary(s: ScriptOutputParser.StepStatus) = when (s) {
            ScriptOutputParser.StepStatus.PENDING -> "Aguardando…"
            ScriptOutputParser.StepStatus.RUNNING -> "Em execução"
            ScriptOutputParser.StepStatus.PASS -> "OK"
            ScriptOutputParser.StepStatus.FAIL -> "Falha"
            ScriptOutputParser.StepStatus.WARN -> "Atenção"
            ScriptOutputParser.StepStatus.SKIP -> "Ignorado"
        }

        private fun labelFor(s: ScriptOutputParser.StepStatus) = when (s) {
            ScriptOutputParser.StepStatus.PENDING -> "•"
            ScriptOutputParser.StepStatus.RUNNING -> "RUN"
            ScriptOutputParser.StepStatus.PASS -> "PASS"
            ScriptOutputParser.StepStatus.FAIL -> "FAIL"
            ScriptOutputParser.StepStatus.WARN -> "WARN"
            ScriptOutputParser.StepStatus.SKIP -> "SKIP"
        }
    }

    companion object {
        private val DIFF = object : DiffUtil.ItemCallback<ScriptOutputParser.Step>() {
            override fun areItemsTheSame(o: ScriptOutputParser.Step, n: ScriptOutputParser.Step) = o.key == n.key
            override fun areContentsTheSame(o: ScriptOutputParser.Step, n: ScriptOutputParser.Step) = o == n
        }
    }
}
