package com.factory.memorytest.ui.deviceedit

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.widget.ArrayAdapter
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.factory.memorytest.R
import com.factory.memorytest.databinding.ActivityDeviceEditBinding
import com.factory.memorytest.domain.DeviceProfile
import com.factory.memorytest.domain.RamPresets
import com.factory.memorytest.domain.StorageClass
import com.google.android.material.snackbar.Snackbar
import kotlinx.coroutines.launch

class DeviceEditActivity : AppCompatActivity() {

    companion object {
        private const val EXTRA_DEVICE_ID = "device_id"

        fun newIntent(ctx: Context) = Intent(ctx, DeviceEditActivity::class.java)
        fun editIntent(ctx: Context, id: Long) =
            Intent(ctx, DeviceEditActivity::class.java).putExtra(EXTRA_DEVICE_ID, id)
    }

    private lateinit var binding: ActivityDeviceEditBinding
    private val vm: DeviceEditViewModel by viewModels()

    private var bindingLoad = false   // evita looping de TextWatchers durante load

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityDeviceEditBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val deviceId = intent.getLongExtra(EXTRA_DEVICE_ID, 0L)
        binding.toolbar.setTitle(
            if (deviceId == 0L) R.string.title_new_device else R.string.title_edit_device
        )
        binding.toolbar.setNavigationOnClickListener { finish() }

        setupRamDropdown()
        setupStorageClassDropdown()
        setupTextWatchers()

        binding.btnApplySuggestion.setOnClickListener { showBaseDevicePicker() }
        binding.btnIgnoreSuggestion.setOnClickListener {
            binding.cardSuggestion.visibility = View.GONE
        }

        binding.fabSave.setOnClickListener { onSave() }

        vm.current.observe(this) { profile ->
            if (profile == null) return@observe
            renderForm(profile)
        }

        vm.similarDevices.observe(this) { list ->
            renderSuggestion(list)
        }

        vm.load(deviceId)
    }

    private fun setupRamDropdown() {
        val items = RamPresets.ramOptions.map { "$it GB" }
        // Usamos um item layout proprio para garantir cor visivel no tema escuro
        val adapter = ArrayAdapter(this, R.layout.item_dropdown, items)
        binding.dropRam.setAdapter(adapter)
        binding.dropRam.setOnItemClickListener { _, _, position, _ ->
            val ramGb = RamPresets.ramOptions[position]
            vm.applyRamPreset(ramGb)
        }
    }

    private fun setupStorageClassDropdown() {
        val classes = StorageClass.values()
        val items = classes.map { it.displayName }
        val adapter = ArrayAdapter(this, R.layout.item_dropdown, items)
        binding.dropStorageClass.setAdapter(adapter)
        binding.dropStorageClass.setOnItemClickListener { _, _, position, _ ->
            vm.applyStorageClass(classes[position])
        }
    }

    private fun setupTextWatchers() {
        addWatcher(binding.edName) { text -> vm.update { it.copy(name = text) } }
        addWatcher(binding.edManufacturer) { text -> vm.update { it.copy(manufacturer = text) } }
        addWatcher(binding.edModelCode) { text -> vm.update { it.copy(modelCode = text) } }
        addWatcher(binding.edNotes) { text -> vm.update { it.copy(notes = text) } }
        addNumberWatcher(binding.edStorage) { v -> vm.update { it.copy(expectedStorageGb = v) } }

        addNumberWatcher(binding.edMinWrite) { v -> vm.update { p -> p.copy(minWriteMbps = v, storageClass = StorageClass.CUSTOM) } }
        addNumberWatcher(binding.edMinRead)  { v -> vm.update { p -> p.copy(minReadMbps = v, storageClass = StorageClass.CUSTOM) } }
        addNumberWatcher(binding.edTestSize) { v -> vm.update { p -> p.copy(storageTestSizeMb = v, storageClass = StorageClass.CUSTOM) } }

        addNumberWatcher(binding.edQuickPercent) { v -> vm.update { it.copy(quickMemtestPercent = v) } }
        addNumberWatcher(binding.edQuickMax)     { v -> vm.update { it.copy(quickMemtestMaxMb = v) } }
        addNumberWatcher(binding.edQuickMin)     { v -> vm.update { it.copy(quickMemtestMinMb = v) } }
        addNumberWatcher(binding.edQuickLoops)   { v -> vm.update { it.copy(quickMemtestLoops = v) } }
        addNumberWatcher(binding.edQuickTimeout) { v -> vm.update { it.copy(quickMemtestTimeoutS = v) } }

        addNumberWatcher(binding.edDeepPercent) { v -> vm.update { it.copy(deepMemtestPercent = v) } }
        addNumberWatcher(binding.edDeepMax)     { v -> vm.update { it.copy(deepMemtestMaxMb = v) } }
        addNumberWatcher(binding.edDeepLoops)   { v -> vm.update { it.copy(deepMemtestLoops = v) } }
        addNumberWatcher(binding.edDeepTimeout) { v -> vm.update { it.copy(deepMemtestTimeoutS = v) } }
        addNumberWatcher(binding.edDeepMin)     { v -> vm.update { it.copy(deepMemtestMinMb = v) } }
    }

    private fun addWatcher(view: com.google.android.material.textfield.TextInputEditText, onChange: (String) -> Unit) {
        view.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (bindingLoad) return
                onChange(s?.toString().orEmpty())
            }
        })
    }

    private fun addNumberWatcher(view: com.google.android.material.textfield.TextInputEditText, onChange: (Int) -> Unit) {
        view.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) = Unit
            override fun afterTextChanged(s: Editable?) {
                if (bindingLoad) return
                val v = s?.toString()?.toIntOrNull() ?: 0
                onChange(v)
            }
        })
    }

    private fun renderForm(profile: DeviceProfile) {
        bindingLoad = true
        try {
            binding.edName.setTextKeepingCursor(profile.name)
            binding.edManufacturer.setTextKeepingCursor(profile.manufacturer)
            binding.edModelCode.setTextKeepingCursor(profile.modelCode)
            binding.edNotes.setTextKeepingCursor(profile.notes)

            // Dropdowns vazios quando nao selecionados
            val ramText = if (profile.expectedRamGb > 0) "${profile.expectedRamGb} GB" else ""
            binding.dropRam.setText(ramText, false)

            val isStorageUnselected = vm.isStorageClassUnselected(profile)
            val storageText = if (isStorageUnselected) "" else profile.storageClass.displayName
            binding.dropStorageClass.setText(storageText, false)

            binding.edStorage.setTextKeepingCursor(profile.expectedStorageGb.numOrEmpty())

            binding.edMinWrite.setTextKeepingCursor(profile.minWriteMbps.numOrEmpty())
            binding.edMinRead.setTextKeepingCursor(profile.minReadMbps.numOrEmpty())
            binding.edTestSize.setTextKeepingCursor(profile.storageTestSizeMb.numOrEmpty())

            binding.edQuickPercent.setTextKeepingCursor(profile.quickMemtestPercent.numOrEmpty())
            binding.edQuickMax.setTextKeepingCursor(profile.quickMemtestMaxMb.numOrEmpty())
            binding.edQuickMin.setTextKeepingCursor(profile.quickMemtestMinMb.numOrEmpty())
            binding.edQuickLoops.setTextKeepingCursor(profile.quickMemtestLoops.numOrEmpty())
            binding.edQuickTimeout.setTextKeepingCursor(profile.quickMemtestTimeoutS.numOrEmpty())

            binding.edDeepPercent.setTextKeepingCursor(profile.deepMemtestPercent.numOrEmpty())
            binding.edDeepMax.setTextKeepingCursor(profile.deepMemtestMaxMb.numOrEmpty())
            binding.edDeepLoops.setTextKeepingCursor(profile.deepMemtestLoops.numOrEmpty())
            binding.edDeepTimeout.setTextKeepingCursor(profile.deepMemtestTimeoutS.numOrEmpty())
            binding.edDeepMin.setTextKeepingCursor(profile.deepMemtestMinMb.numOrEmpty())
        } finally {
            bindingLoad = false
        }
        renderHint(profile)
        // refresh sugestao baseado na RAM atual (so se RAM ja foi selecionada)
        if (profile.expectedRamGb > 0) {
            vm.refreshSimilar(profile.expectedRamGb)
        } else {
            vm.similarDevices.value = emptyList()
        }
    }

    private fun renderHint(profile: DeviceProfile) {
        val ramMissing = vm.isRamUnselected(profile)
        val storageMissing = vm.isStorageClassUnselected(profile)
        val msg = when {
            ramMissing -> getString(R.string.hint_select_ram_storage)
            storageMissing -> getString(R.string.hint_select_storage)
            else -> null
        }
        if (msg != null) {
            binding.tvHint.text = msg
            binding.cardHint.visibility = View.VISIBLE
        } else {
            binding.cardHint.visibility = View.GONE
        }
    }

    private fun renderSuggestion(list: List<DeviceProfile>) {
        if (list.isEmpty()) {
            binding.cardSuggestion.visibility = View.GONE
            return
        }
        val text = if (list.size == 1) {
            getString(R.string.hint_smart_default_one, list.first().displayName)
        } else {
            getString(R.string.hint_smart_default_many, list.size)
        }
        binding.tvSuggestion.text = text
        binding.cardSuggestion.visibility = View.VISIBLE
    }

    private fun showBaseDevicePicker() {
        val list = vm.similarDevices.value.orEmpty()
        if (list.isEmpty()) return
        if (list.size == 1) {
            vm.applyFullProfile(list.first())
            binding.cardSuggestion.visibility = View.GONE
            Snackbar.make(binding.root, "Valores aplicados de ${list.first().displayName}", Snackbar.LENGTH_SHORT).show()
            return
        }
        val labels = list.map { it.displayName }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_choose_base)
            .setItems(labels) { _, which ->
                vm.applyFullProfile(list[which])
                binding.cardSuggestion.visibility = View.GONE
                Snackbar.make(binding.root, "Valores aplicados de ${list[which].displayName}", Snackbar.LENGTH_SHORT).show()
            }
            .setNegativeButton(R.string.action_cancel, null)
            .show()
    }

    private fun onSave() {
        val profile = vm.current.value ?: return
        val errors = validate(profile)
        if (errors.isNotEmpty()) {
            Snackbar.make(binding.root, errors.first(), Snackbar.LENGTH_LONG).show()
            return
        }
        lifecycleScope.launch {
            vm.save(profile)
            finish()
        }
    }

    private fun validate(profile: DeviceProfile): List<String> {
        val errs = mutableListOf<String>()
        if (profile.name.isBlank()) errs += "Informe o nome do device"
        if (profile.manufacturer.isBlank()) errs += "Informe o fabricante"
        if (profile.expectedRamGb <= 0) errs += "RAM deve ser maior que zero"
        if (profile.expectedStorageGb <= 0) errs += "Storage deve ser maior que zero"
        if (profile.minWriteMbps <= 0) errs += "Velocidade mínima de escrita deve ser maior que zero"
        if (profile.minReadMbps <= 0) errs += "Velocidade mínima de leitura deve ser maior que zero"
        if (profile.storageTestSizeMb <= 0) errs += "Tamanho de teste de I/O deve ser maior que zero"
        if (profile.quickMemtestPercent !in 1..100) errs += "% do teste rápido deve ser 1-100"
        if (profile.deepMemtestPercent !in 1..100) errs += "% do teste profundo deve ser 1-100"
        if (profile.quickMemtestLoops <= 0 || profile.deepMemtestLoops <= 0) errs += "Loops devem ser maior que zero"
        if (profile.quickMemtestTimeoutS <= 0 || profile.deepMemtestTimeoutS <= 0) errs += "Timeout deve ser maior que zero"
        return errs
    }
}

/**
 * setText preservando posicao do cursor — evita "pulo" pra inicio quando o ViewModel
 * re-emite estado durante digitacao.
 */
private fun com.google.android.material.textfield.TextInputEditText.setTextKeepingCursor(value: String?) {
    val incoming = value.orEmpty()
    if (text?.toString() == incoming) return
    val cursor = selectionStart.coerceAtMost(incoming.length)
    setText(incoming)
    setSelection(cursor.coerceIn(0, incoming.length))
}

/** Mostra string vazia para 0, caso contrario o numero. */
private fun Int.numOrEmpty(): String = if (this <= 0) "" else this.toString()
