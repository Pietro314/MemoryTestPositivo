# MemoryTest — Integração AutoTest (contrato para app externo)

Este documento descreve como o **app da fábrica** dispara o `AutoTest`
do MemoryTest e como ele recebe o resultado.

## Visão geral do fluxo

```
┌────────────────────┐                            ┌──────────────────────┐
│  Factory App       │                            │  MemoryTest APK      │
│  (externo)         │  Intent AUTO_TEST          │                      │
│                    │  ───────────────────────►  │  AutoTestActivity    │
│                    │                            │   • lê JSON local    │
│                    │                            │   • match (device,   │
│                    │                            │     ramGb)           │
│                    │                            │   • roda factory     │
│                    │                            │   • roda deep        │
│                    │                            │   • grava result     │
│                    │                            │   • dispara          │
│                    │  Broadcast RESULT_READY    │     broadcast        │
│                    │  ◄───────────────────────  │                      │
│                    │                            │                      │
│                    │  Broadcast STOP_TEST       │                      │
│                    │  ───────────────────────►  │  (cancela ProcessB.) │
└────────────────────┘                            └──────────────────────┘
```

## 1. Disparar o teste (`AUTO_TEST`)

O app da fábrica dispara via `startActivity()`:

```kotlin
val intent = Intent("com.factory.memorytest.action.AUTO_TEST").apply {
    setPackage("com.factory.memorytest")
}
startActivity(intent)
```

**Extras**: nenhum. O MemoryTest descobre tudo sozinho lendo o JSON local + Build.DEVICE + RAM.

**Pré-requisito**: o app da fábrica deve ter gravado o arquivo de config
no caminho exato:

```
/storage/emulated/0/Positivo/MemoryTest/memorytestconfig.json
```

## 2. Schema do `memorytestconfig.json`

```json
{
  "schema_version": 1,
  "profiles": [
    {
      "device": "TL10",
      "ramGb": 8,
      "name": "TL10 (8GB)",
      "manufacturer": "Positivo",
      "modelCode": "H28S8D301DMR",
      "expectedStorageGb": 128,
      "storageClass": "UFS_2_1",
      "minWriteMbps": 120,
      "minReadMbps": 500,
      "storageTestSizeMb": 1024,
      "quickMemtest": {
        "percent": 50,
        "maxMb": 4096,
        "minMb": 256,
        "loops": 1,
        "timeoutS": 900
      },
      "deepMemtest": {
        "percent": 60,
        "maxMb": 4096,
        "minMb": 256,
        "loops": 3,
        "timeoutS": 3600
      }
    },
    {
      "device": "T2070D",
      "ramGb": 4,
      "name": "T2070D (4GB)",
      "manufacturer": "Positivo",
      "expectedStorageGb": 32,
      "storageClass": "EMMC_5_1",
      "minWriteMbps": 50,
      "minReadMbps": 150,
      "storageTestSizeMb": 512,
      "quickMemtest": { "percent": 40, "maxMb": 512, "minMb": 128, "loops": 1, "timeoutS": 600 },
      "deepMemtest":  { "percent": 60, "maxMb": 2048, "minMb": 128, "loops": 3, "timeoutS": 3000 }
    }
  ]
}
```

### Como o match funciona

O MemoryTest lê o `Build.DEVICE` (ex: `"T2070D"`) e calcula a RAM em GB a
partir de `/proc/meminfo` (ex: `4` ou `8`). Procura no array `profiles`
a primeira entrada com **ambos campos iguais**:

```kotlin
profiles.firstOrNull {
    it["device"] == Build.DEVICE && it["ramGb"] == ramGb
}
```

Permite ter o mesmo device com SKUs de RAM diferentes (ex: `T2070D-4GB` e
`T2070D-8GB`) como duas entradas distintas.

### Campos obrigatórios

- `device` (string) — bate com `Build.DEVICE` do Android
- `ramGb` (int) — RAM esperada em GB, deve bater com o cálculo `ceil(MemTotal / 1024)`

### Campos com fallback do `DefaultDeviceProfile` (embutido)

- `name`, `manufacturer`, `modelCode`, `notes`
- `expectedStorageGb`, `storageClass`
- `minWriteMbps`, `minReadMbps`, `storageTestSizeMb`
- `quickMemtest.*` e `deepMemtest.*`

### `storageClass`

Valores aceitos: `EMMC_4_5`, `EMMC_5_0`, `EMMC_5_1`, `UFS_2_0`,
`UFS_2_1`, `UFS_3_0`, `UFS_3_1`, `UFS_4_0`, ou nome custom (string livre).

## 3. Receber o resultado (`RESULT_READY`)

O MemoryTest emite **sempre** um broadcast no fim, **independente do
resultado** (PASS, FAIL, STOPPED ou ERROR).

### Receiver no app da fábrica

```kotlin
class MemoryTestResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val overall = intent.getStringExtra("overall")
        val factoryStatus = intent.getStringExtra("factory_status")
        val deepStatus = intent.getStringExtra("deep_status")
        val resultFile = intent.getStringExtra("result_file")

        // Processa resultado: log, telemetria, próximo step da linha, etc.
    }
}
```

### Registro do receiver

```kotlin
val filter = IntentFilter("com.factory.memorytest.action.RESULT_READY")
context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
```

> Atenção: em Android 13+, `RECEIVER_EXPORTED` precisa ser explícito.

### Extras do broadcast

| Extra | Tipo | Valores |
|---|---|---|
| `overall` | String | `PASS` \| `FAIL` \| `STOPPED` \| `ERROR` |
| `factory_status` | String | `PASS` \| `FAIL` \| `STOPPED` \| `NOT_RUN` |
| `factory_duration_s` | Long | Duração do factory em segundos |
| `deep_status` | String | `PASS` \| `FAIL` \| `STOPPED` \| `NOT_RUN` |
| `deep_duration_s` | Long | Duração do deep em segundos |
| `result_file` | String | Path absoluto do arquivo de resultado |
| `device` | String | Build.DEVICE detectado |
| `ramGb` | Int | RAM em GB detectada |
| `serial` | String | Build.SERIAL do device |
| `error_message` | String | Só presente se `overall == ERROR` |

### Significado dos valores `overall`

- **`PASS`** — Ambos factory e deep passaram
- **`FAIL`** — Algum dos dois falhou (com factory ou deep marcado como FAIL)
- **`STOPPED`** — Cancelado via `STOP_TEST` antes de terminar
- **`ERROR`** — Falha de orquestração: JSON ausente, JSON inválido, perfil não encontrado, ou outro AutoTest já rodando (BUSY)

## 4. Arquivo de resultado (`result.json`)

Além do broadcast, o MemoryTest grava resultado consolidado em:

```
/storage/emulated/0/Positivo/MemoryTest/result.json
```

Exemplo:

```json
{
  "schema_version": 1,
  "device": "TL10",
  "ramGb": 8,
  "serial": "4AG438R6E",
  "timestamp": "2026-05-25T14:30:00Z",
  "overall": "PASS",
  "profile": {
    "name": "TL10 (8GB)",
    "manufacturer": "Positivo",
    "modelCode": "H28S8D301DMR"
  },
  "factory": {
    "status": "PASS",
    "duration_s": 187,
    "reasons": [],
    "steps_summary": [
      "Identificação: Modelo TL10",
      "Saúde do Storage: UFS · SKhynix · Pre-EOL: 0x01 (normal)",
      "RAM detectada: 7747 MB total",
      "Velocidade de Storage: W: 150 MB/s · R: 520 MB/s",
      "Memtester (rápido): OK em 161s",
      "Análise do dmesg: Sem erros"
    ]
  },
  "deep": {
    "status": "PASS",
    "duration_s": 1800,
    "reasons": [],
    "steps_summary": [
      "Identificação: Modelo TL10",
      "RAM detectada: 7747 MB total",
      "Memtester profundo: OK em 1800s"
    ]
  }
}
```

A escrita é **atômica** (`.tmp` + rename) — não corrompe se o app for morto no meio.

## 5. Cancelar o teste (`STOP_TEST`)

```kotlin
val intent = Intent("com.factory.memorytest.action.STOP_TEST")
context.sendBroadcast(intent)
```

**Comportamento**:
- Cancela o teste em curso (factory ou deep) com `kill -9` do `memtester` se necessário
- Resultados parciais são **preservados** — o que rodou até aqui aparece no result com seu status real, o que não rodou marca `NOT_RUN`
- O `overall` do resultado vira `STOPPED`
- Broadcast `RESULT_READY` é emitido normalmente, com `overall=STOPPED`

## 6. Concorrência

Se o app da fábrica disparar `AUTO_TEST` enquanto outro já está rodando:
- O segundo dispatch é **rejeitado** imediatamente
- A Activity (segunda instância) é finalizada
- Um broadcast `RESULT_READY` é emitido com `overall=ERROR` e `error_message="BUSY: outro AutoTest ja esta em execucao"`

## 7. Duração esperada

| Fase | Duração típica |
|---|---|
| Factory | ~3 min |
| Deep RAM | 15 min – 1 h (depende do device) |
| **Total** | **~20 min – 1 h** |

Recomenda-se manter o device **conectado ao carregador** durante o teste.
A Activity adquire `PARTIAL_WAKE_LOCK` automaticamente pra impedir CPU
deep sleep durante o memtester (timeout 70 min).

## 8. Testar end-to-end via adb (sem app da fábrica)

```bash
# 1. Cria o config
adb shell mkdir -p /storage/emulated/0/Positivo/MemoryTest/
adb push memorytestconfig.json /storage/emulated/0/Positivo/MemoryTest/

# 2. Dispara
adb shell am start -a com.factory.memorytest.action.AUTO_TEST \
  -n com.factory.memorytest/.ui.autotest.AutoTestActivity

# 3. (Opcional) Cancela
adb shell am broadcast -a com.factory.memorytest.action.STOP_TEST

# 4. Lê resultado
adb shell cat /storage/emulated/0/Positivo/MemoryTest/result.json
```

## 9. Limitações conhecidas

- **Sem proteção de permissão**: qualquer app instalado pode disparar `AUTO_TEST`. Decisão consciente do projeto. Se quiser proteger no futuro, adicionar `android:permission` no intent-filter e `<permission android:protectionLevel="signature">` no manifest.
- **Profile não encontrado é FAIL**: não há fallback. Se o JSON não tiver entrada exata `(device, ramGb)`, o teste não roda e retorna `overall=ERROR`.
- **Build user vs userdebug**: o teste real de RAM (memtester com mlock unlimited) requer APK como `platform_app` — ou seja, embarcado no AOSP. Em build de teste (`adb install`), memtester roda com ~8 MB e teste é fake-fast.

## 10. Versões

- **Versão atual do contrato**: `schema_version: 1`
- Mudanças futuras devem incrementar o número e manter compatibilidade.
