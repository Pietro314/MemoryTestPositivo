# MemoryTest — projeto de validação de memória pra QA Positivo

## Contexto rápido

App + scripts pra validar RAM e storage de tablets/celulares Positivo antes
de irem a campo (validação de fábrica). Detecta defeitos via memtester + leitura
de health regs (lifetime, pre_eol_info) + dd test + dmesg analysis.

## Estrutura do repo

```
.
├── MemoryTest/                          # projeto Android Studio (APK Kotlin)
│   └── app/src/main/
│       ├── assets/full_memtest.sh       # script principal de teste (roda no device)
│       ├── assets/ram_diagnostic_*.sh   # diagnóstico deep de RAM
│       └── java/com/factory/memorytest/ # código Kotlin
├── MemoryTest_QA/                       # pacote APK distribuído pra QA
├── MemoryTest_QA_ScriptOnly_v4/         # pacote ScriptOnly (sem APK) — mais recente
│   ├── pre_check.sh                     # avalia capacidades do device
│   ├── run_full.sh / run_deep.sh        # wrappers no host
│   ├── scripts/                         # versão standalone dos scripts (rodam no device)
│   ├── profiles/                        # thresholds por modelo (T2070.conf, L400.conf, etc)
│   └── reports/                         # relatórios do pre_check (gerados em runtime)
└── *.zip                                # pacotes prontos pra distribuir
```

## Arquiteturas (caminhos vivos)

1. **APK platform-signed embarcado no AOSP** (Opção 3 simplificada — recomendado)
   - APK em `/product/priv-app/` re-assinado com chave platform via `LOCAL_CERTIFICATE := platform`
   - memtester compilado em `/system/bin/memtester`
   - SELinux `permissive` global via cmdline do bootloader
   - Resultado: APK roda como `platform_app`, lê `/sys/block/*`, executa memtester, mlock unlimited

2. **ScriptOnly via adb** (sem APK)
   - Roda os mesmos scripts via `adb shell` como uid `shell`
   - Permissões dependem do device — em devices Enforcing pode ter cobertura reduzida
   - `pre_check.sh` te diz se vale rodar ou se precisa AOSP

## Aprendizados importantes (não repetir erros)

- **NÃO usar `adb root` em devices MTK + Windows** — quebra o adb-server, device some
- **`BOARD_KERNEL_CMDLINE` é ignorado em MTK MT6761** — cmdline real é montada pelo LK em `vendor/mediatek/proprietary/bootable/bootloader/lk/`
- **Em MTK MT6761, SELinux Permissive é setado via `PRJ_SELINUX_STATUS := 2`** no project file do LK
- **APK como `untrusted_app` tem `RLIMIT_MEMLOCK` baixo** (~8 MB) → teste de RAM vira fake-fast com PASS enganoso
- **Profiles devem ser escolhidos explicitamente pelo QA**, não auto-detect — múltiplos profiles podem existir pro mesmo device

## Comandos comuns

```bash
# Build do APK (no projeto)
cd MemoryTest/MemoryTest
./gradlew assembleRelease

# Empacotar zip pra QA (após rebuild do APK)
cp app/build/outputs/apk/release/app-release.apk ../../MemoryTest_QA/RamMemoryTest.apk
cd ../..
zip -r MemoryTest_QA_vN.zip MemoryTest_QA -x "MemoryTest_QA/qa_setup_*.log" "MemoryTest_QA/.DS_Store"

# Rodar ScriptOnly num device:
cd MemoryTest_QA_ScriptOnly_v4
bash pre_check.sh                       # avalia o device
bash run_full.sh T2070.conf             # teste padrão com profile
```

## Convenções

- **Versionamento dos pacotes:** incremento numérico simples (`_v1`, `_v2`, ...). Zips antigos preservados intactos (confirmado via shasum em cada release).
- **Profiles:** `<MODELO>.conf` pra factory default; `<MODELO>_<cenario>.conf` pra variantes (ex: `T2070_strict.conf`).
- **Memória persistente:** em `~/.claude/projects/-Users-<user>-projetcs-MemoryTest/memory/`. Não versionada no repo (é por máquina). Transferida entre máquinas via bundle de handoff (zip) ou manualmente.

## Status atual / pendências

Ver bundle de handoff (`memorytest_handoff_*.zip`) com `CONTEXTO_HANDOFF.md`
detalhado se precisar do estado completo da integração AOSP em curso no L400.

Resumo curto da pendência atual:
- L400 (MTK MT6761): falta `PRJ_SELINUX_STATUS := 2` no project file do LK
  (`vendor/mediatek/proprietary/bootable/bootloader/lk/project/k61v1_32_bsp_1g.mk`)
  + rebuild + flash do `lk.img` pra SELinux ficar Permissive

## NÃO fazer

- Adicionar features ao APK sem alinhar com produto (perfis no Room, dashboard, etc.)
- Modificar scripts shell que rodam no device sem sincronizar entre `MemoryTest/app/src/main/assets/` e `MemoryTest_QA_ScriptOnly_v4/scripts/`
- Commitar `out/`, `*.log`, `reports/preinfo_*`, ou APKs grandes no git (gitignore já cuida)
- Tentar `adb root` em MTK MT6761 + Windows (quebra adb)
