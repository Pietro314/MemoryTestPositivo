# MemoryTest QA — Script-Only v4

Pacote para validar memória (RAM + storage) de devices Android via `adb`.
Não precisa instalar APK no device.

## Filosofia: 2 caminhos

Esse pacote suporta **duas estratégias de teste**:

1. **ScriptOnly** (esse pacote, `bash run_full.sh`) — roda como `shell` user via adb,
   funciona em qualquer device userdebug. Cobertura depende de quanto
   `RLIMIT_MEMLOCK` o kernel libera pro shell.

2. **AOSP Opção 3 simplificada** (integração no build do device) — APK
   platform-signed embutido em `/system/priv-app/`, memtester compilado em
   `/system/bin/memtester`, SELinux permissive global. Cobertura 100%, mas exige
   trabalho do time AOSP por device.

**O `pre_check.sh` te diz qual caminho seguir pra esse device específico.**

## Estrutura

```
MemoryTest_QA_ScriptOnly_v4/
├── README.md                  ← este arquivo
├── pre_check.sh               ← avalia capacidades do device (rodar 1x por SKU)
├── run_full.sh                ← teste de fábrica rápido
├── run_deep.sh                ← diagnóstico profundo de RAM (uso raro)
├── memtester                  ← binário arm64
├── memtester-arm32            ← binário arm32 (do build L400)
├── scripts/
│   ├── full_memtest.sh        ← roda dentro do device via adb shell
│   └── ram_deep.sh            ← idem
├── profiles/                  ← thresholds por modelo (carregado automático)
│   ├── README.md              ← como criar profile pra device novo
│   ├── default.conf           ← fallback genérico
│   ├── _template.conf         ← copie pra criar profile novo
│   ├── T2070.conf             ← Positivo T2070D
│   ├── L400.conf              ← Positivo L400
│   └── L300.conf              ← Positivo L300
├── reports/                   ← relatórios do pre_check (1 arquivo por execução)
└── results/                   ← resultados dos testes (criado em runtime)
```

## Pré-requisitos

- `adb` instalado e no PATH
- Device userdebug (ou eng) conectado e autorizado (`adb devices` lista)
- Device com a ABI correspondente ao binário (arm64 ou arm32)

## Fluxo recomendado

### 1) Recebeu device novo de um SKU? Roda o pre_check primeiro:

```bash
bash pre_check.sh
```

Saída:
- Resumo no terminal
- Arquivo `reports/preinfo_<MODELO>_<TIMESTAMP>.txt` com tudo registrado

O **veredicto** no fim do relatório te diz o caminho:

| Status | O que fazer |
|---|---|
| **READY** | `bash run_full.sh` — ScriptOnly cobre 100% |
| **PARTIAL** | Aceitar cobertura parcial OU pedir AOSP Opção 3 |
| **NOT READY** | Pedir AOSP Opção 3 antes de testar |

### 2) Quer rodar o teste? `run_full.sh` com profile escolhido:

```bash
# 2a) Sem argumento: menu interativo lista profiles e você escolhe
bash run_full.sh

# 2b) Passa o profile direto (ideal pra automação ou quando já sabe qual usar)
bash run_full.sh T2070.conf
bash run_full.sh L400.conf
bash run_full.sh T2070_strict.conf
```

**Você escolhe explicitamente qual `.conf` usar.** Pode ter múltiplos profiles
pro mesmo device (ex: `T2070.conf` factory padrão e `T2070_strict.conf` para
homologação rígida). O `pre_check.sh` no fim do relatório lista profiles que
dão match com o device pra te ajudar a decidir.

Faz:
- Carrega o profile escolhido (define thresholds e parâmetros de teste)
- Push do `memtester` correto (arm64 ou arm32) pra `/data/local/tmp/`
- Push do script `full_memtest.sh` pra `/data/local/tmp/memtest_work/`
- Executa via `adb shell`
- Coleta resultados em `results/<MODELO>_<TIMESTAMP>/`

### 3) Diagnóstico profundo de RAM (caso suspeito):

```bash
bash run_deep.sh                     # menu interativo
bash run_deep.sh T2070.conf          # profile direto
```

Mais demorado (até 1h). Use só pra investigar aparelhos suspeitos de defeito.

## Configurar thresholds por SKU

### Profiles em `profiles/`

Cada arquivo `.conf` na pasta `profiles/` define thresholds e parâmetros de
teste pra um cenário específico. Você pode ter:
- Um profile por device (`T2070.conf`, `L400.conf`)
- **Múltiplos profiles para o mesmo device** (`T2070.conf` factory padrão,
  `T2070_strict.conf` homologação rígida, `T2070_lab.conf` valores
  experimentais)

QA escolhe explicitamente qual profile usar a cada execução — sem mágica de
auto-detecção que pode dar errado.

### Adicionar profile para device novo

```bash
# 1. Descobre o model do device:
adb shell getprop ro.product.model       # ex: "L400"

# 2. Copia o template e renomeia:
cp profiles/_template.conf profiles/L400.conf

# 3. Edita os thresholds conforme spec
# (ou cria variantes: L400_strict.conf, L400_lab.conf, etc)

# 4. Pra rodar:
bash run_full.sh L400.conf
```

### Override pontual via env var

Mesmo passando profile, dá pra forçar um valor específico:

```bash
MIN_WRITE_MBPS=80 bash run_full.sh T2070.conf
```

Ordem de precedência (do mais forte pro mais fraco):
1. **Env var na linha de comando**
2. **Profile escolhido** (`profiles/<NOME>.conf`)
3. **Defaults hardcoded no script**

### Como o profile é escolhido

```
bash run_full.sh                  → menu interativo lista profiles
bash run_full.sh T2070.conf       → usa profile direto
bash run_full.sh T2070            → idem (autocompleta .conf)
bash run_full.sh /path/x.conf     → path absoluto
```

Sem argumento e sem TTY (ex: rodando em CI), cai em `default.conf`
silenciosamente.

Variáveis aceitas pelo `run_full.sh`:

| Variável | Default | Controla |
|---|---|---|
| `MIN_WRITE_MBPS` | 50 | Velocidade mínima de escrita |
| `MIN_READ_MBPS` | 100 | Velocidade mínima de leitura |
| `EXPECTED_RAM_GB` | 4 | RAM mínima esperada |
| `STORAGE_TEST_SIZE_MB` | 512 | Tamanho do teste de storage |
| `QUICK_MEMTEST_PERCENT` | 40 | % da RAM disponível pra testar |
| `QUICK_MEMTEST_MAX_MB` | 512 | Teto absoluto da RAM testada |
| `QUICK_MEMTEST_LOOPS` | 1 | Loops do memtester |
| `QUICK_MEMTEST_TIMEOUT_S` | 600 | Timeout do memtester |

Variáveis pelo `run_deep.sh`:

| Variável | Default |
|---|---|
| `MEMTEST_PERCENT` | 60 |
| `MEMTEST_MAX_MB` | 2048 |
| `MEMTEST_LOOPS` | 3 |
| `MEMTEST_TIMEOUT_S` | 3600 |
| `EXPECTED_RAM_GB` | 0 (não verifica) |

## O que o pre_check.sh checa

| Categoria | Item | Por quê importa |
|---|---|---|
| Identificação | Modelo, SoC, board, Android, ABI | Saber o que está testando |
| SELinux | Estado (Enforcing/Permissive) | Determina se /sys é acessível |
| **mlock** | `ulimit -l` do shell | **Determina cobertura real do memtester** |
| Storage health | `life_time`, `pre_eol_info` (eMMC/UFS) | Saúde da memória detectável? |
| Identificação memória | CID (eMMC) ou product_name (UFS) | Vendor/modelo do chip detectável? |
| Capacidade | Free space em /data | Tem espaço pro dd test? |
| memtester | Binário em /system/bin? + binário do pacote | AOSP integration completa? |
| Permissões aux | drop_caches, dmesg, adb root | Cosméticos / diagnóstico |

## Por que mlock importa tanto

O memtester usa `mlock()` pra travar páginas de memória física e impedir que o
kernel swappe durante o teste (o que invalidaria os resultados).

`mlock` tem limite por processo (`RLIMIT_MEMLOCK`). Se o shell de adb tem limite
baixo (~8-64MB), o memtester vai pedir tudo que mandar (ex: 1500MB), receber um
erro, e ir reduzindo até conseguir travar. Resultado: **teste fica fake-fast**,
cobrindo só ~8MB em vez dos 1500MB pedidos.

Em devices com `RLIMIT_MEMLOCK` alto/unlimited, o teste cobre o tamanho pedido.
Em devices com limite baixo, **só o caminho AOSP Opção 3 resolve direito**
(porque lá o app vira `platform_app` em build com `init.rc` configurado).

O `pre_check.sh` mede isso e te diz a cobertura real (em %).

## AOSP Opção 3 simplificada (resumo da integração)

Pra fazer no AOSP do device, se o pre_check apontou que precisa:

**1. Adicionar memtester como pacote do build:**

`external/memtester/` (source completo do memtester) com `Android.bp`.

**2. Empacotar o APK como prebuilt:**

```
packages/apps/MemoryTest/Android.mk:
LOCAL_MODULE := MemoryTest
LOCAL_SRC_FILES := MemoryTest.apk
LOCAL_CERTIFICATE := platform
LOCAL_PRIVILEGED_MODULE := true

packages/apps/MemoryTest/MemoryTest.apk  ← APK release inalterado
```

**3. Adicionar no main.mk do device:**

```makefile
PRODUCT_PACKAGES += memtester MemoryTest
```

**4. SELinux permissive global (BoardConfig.mk):**

```makefile
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
```

Build → flash → APK funciona como `platform_app`, lê /sys/* sem restrição,
memtester aloca todo tamanho pedido.

## Output / arquivos gerados

- `reports/preinfo_<MODELO>_<TIMESTAMP>.txt` — relatório do pre_check
- `run_full_<TIMESTAMP>.log` — log da execução do run_full
- `run_deep_<TIMESTAMP>.log` — log da execução do run_deep
- `results/<MODELO>_<TIMESTAMP>/` — pasta com tudo do device puxado via adb pull

O `result.txt` dentro de cada `results/.../` é o sumário em formato `KEY=VALUE`,
útil pra automação:

```
RESULT=PASS
SERIAL=ABC123
MODEL=L400
STORAGE_TYPE=MMC
RAM_MB=1024
WRITE_MBPS=45
READ_MBPS=120
...
```

## Troubleshooting rápido

**`memtester eh arm64 mas device eh arm32`** → o pacote inclui `memtester-arm32`,
o wrapper detecta e usa automaticamente. Se ainda assim deu, verifica se está
faltando o arquivo `memtester-arm32` na pasta.

**`Requires newer sdk version #33`** (instalando APK em outro pacote) → não
afeta esse pacote (ScriptOnly não instala APK). É problema do APK, não do
script.

**Teste rápido demais (segundos em vez de minutos)** → pre_check vai te dizer:
provavelmente é mlock truncado. Veja seção "Por que mlock importa" acima.

**`adb shell` falha após `adb root`** → não execute adb root. O ScriptOnly
roda como shell user e isso é suficiente pra todos os passos críticos.

**Device não responde após algum comando** →
```bash
adb kill-server
adb start-server
adb devices
```
