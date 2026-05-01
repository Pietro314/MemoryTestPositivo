# Integração AOSP — memtest_daemon

## Estrutura final

```
device/<vendor>/<product>/
├── memtest_daemon/
│   ├── Android.bp               (build do daemon + scripts em /vendor/etc/factory)
│   ├── memtest_daemon.c
│   ├── memtest_daemon.rc        (init.rc do serviço)
│   └── scripts/
│       ├── full_memtest.sh
│       └── ram_diagnostic_deep_verbose_root_exec.sh
└── sepolicy/
    └── vendor/
        ├── memtest_daemon.te
        ├── untrusted_app_memtest.te
        ├── file_contexts        (linhas para adicionar no existente)
```

## Protocolo do daemon

O APK abre um socket Unix em `/dev/socket/memtest_daemon` e envia:

```
RUN <script>\n
KEY1=VALUE1\n
KEY2=VALUE2\n
...
END\n
```

Onde `<script>` ∈ `{ full_memtest, ram_diagnostic }`.

O daemon:
1. Valida `KEY` contra a allowlist em `ALLOWED_KEYS` (apenas variáveis dos scripts são aceitas).
2. Sanitiza `VALUE` (rejeita `'`, `"`, `` ` ``, `$`, `\`, e bytes não imprimíveis).
3. Faz `setenv()` para cada par e `exec()` o script como root.
4. Envia o stdout/stderr de volta linha a linha.
5. Termina com `EXIT:<code>\n` e fecha a conexão.

## Variáveis suportadas (passadas pelo APK)

```
EXPECTED_RAM_GB
EXPECTED_STORAGE_GB
MIN_WRITE_MBPS
MIN_READ_MBPS
STORAGE_TEST_SIZE_MB

QUICK_MEMTEST_PERCENT       (factory test)
QUICK_MEMTEST_MAX_MB
QUICK_MEMTEST_MIN_MB
QUICK_MEMTEST_LOOPS
QUICK_MEMTEST_TIMEOUT_S

MEMTEST_PERCENT             (deep test)
MEMTEST_MAX_MB
MEMTEST_LOOPS
MEMTEST_TIMEOUT_S
MIN_MEMTEST_MB

DEVICE_NAME                 (informativo)
DEVICE_MANUFACTURER         (informativo)
```

Os scripts leem essas variáveis com `${VAR:-default}`. Continuam executáveis manualmente sem o APK.

## Passo a passo de integração

### 1. Copiar diretório

```bash
cp -r aosp_solution/native_daemon device/<vendor>/<product>/memtest_daemon
mkdir -p device/<vendor>/<product>/sepolicy/vendor
cp aosp_solution/sepolicy/* device/<vendor>/<product>/sepolicy/vendor/
```

### 2. Adicionar ao device.mk

```makefile
PRODUCT_PACKAGES += \
    memtest_daemon \
    full_memtest_sh \
    ram_diagnostic_deep_verbose_root_exec_sh
```

### 3. Mesclar file_contexts ao existente

Anexar as 3 linhas de `aosp_solution/sepolicy/file_contexts` ao
`device/<vendor>/<product>/sepolicy/vendor/file_contexts`.

### 4. Build

```bash
source build/envsetup.sh
lunch <seu_target>
make memtest_daemon
```

Ou build completo:

```bash
make -j$(nproc)
```

### 5. Verificar após boot

```bash
# Daemon rodando
adb shell ps -A | grep memtest_daemon

# Socket existe
adb shell ls -la /dev/socket/memtest_daemon

# Scripts no lugar
adb shell ls -la /vendor/etc/factory/

# Teste manual
adb shell "printf 'RUN full_memtest\nEXPECTED_RAM_GB=4\nEND\n' | nc -U /dev/socket/memtest_daemon"
```

## APK

O APK (em `MemoryTest/`) já foi atualizado para usar este daemon.
Construa e instale como qualquer APK Android:

```bash
cd MemoryTest
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```
