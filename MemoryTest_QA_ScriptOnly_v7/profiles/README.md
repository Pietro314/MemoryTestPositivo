# profiles/

Configurações de thresholds e parâmetros de teste. Cada `.conf` é um cenário.
**O usuário escolhe explicitamente qual usar** — sem auto-detecção.

## Ideia geral

Você pode ter:
- Um profile por modelo (`T2070.conf`, `L400.conf`, `L300.conf`)
- **Vários profiles pro mesmo modelo** com cenários diferentes:
  - `T2070.conf` — valores padrão de fábrica
  - `T2070_strict.conf` — thresholds mais rígidos (homologação)
  - `T2070_lab.conf` — valores experimentais pra investigação
- Profiles por contexto (`burnin.conf`, `quick.conf`, `extended.conf`)

Não tem regra fixa — nomeia conforme fizer sentido pro processo de QA.

## Como QA escolhe

### Forma 1: passar como argumento (recomendado pra automação)
```bash
bash run_full.sh T2070.conf
bash run_full.sh T2070_strict.conf
bash run_full.sh L400
```

### Forma 2: menu interativo
```bash
bash run_full.sh
```
Mostra:
```
============================================================
  Selecione o profile (thresholds) para esse run
  Device detectado: T2070 (arm64-v8a)
============================================================
  [1] default.conf
  [2] L300.conf
  [3] L400.conf
  [4] T2070.conf            <-- match com o device
  [5] T2070_strict.conf     <-- match com o device

  Escolha [1-5, ou nome do arquivo]: _
```

Profiles cujo nome contém o `ro.product.model` ficam marcados como **match com
o device** pra ajudar a escolha (mas você não é forçado a escolher esses).

## pre_check.sh ajuda na decisão

Roda `bash pre_check.sh` antes — no fim do relatório ele lista os profiles
disponíveis destacando os que dão match com o device, e mostra os comandos de
exemplo prontos pra copiar.

## Estrutura padrão de um `.conf`

Todo profile usa sintaxe `${VAR:=valor}` (atribui só se não estiver setado),
pra que env vars passadas no comando tenham prioridade:

```bash
: "${MIN_WRITE_MBPS:=50}"
: "${MIN_READ_MBPS:=100}"
: "${EXPECTED_RAM_GB:=2}"
: "${STORAGE_TEST_SIZE_MB:=512}"
: "${QUICK_MEMTEST_PERCENT:=50}"
: "${QUICK_MEMTEST_MAX_MB:=1024}"
: "${QUICK_MEMTEST_LOOPS:=1}"
: "${QUICK_MEMTEST_TIMEOUT_S:=900}"

: "${MEMTEST_PERCENT:=70}"
: "${MEMTEST_MAX_MB:=2048}"
: "${MEMTEST_LOOPS:=3}"
: "${MEMTEST_TIMEOUT_S:=3600}"

# Importante: exportar pra que viaje pro env do adb shell
export MIN_WRITE_MBPS MIN_READ_MBPS STORAGE_TEST_SIZE_MB EXPECTED_RAM_GB
export QUICK_MEMTEST_PERCENT QUICK_MEMTEST_MAX_MB QUICK_MEMTEST_MIN_MB
export QUICK_MEMTEST_LOOPS QUICK_MEMTEST_TIMEOUT_S
export MEMTEST_PERCENT MEMTEST_MAX_MB MEMTEST_LOOPS MEMTEST_TIMEOUT_S
```

Use `_template.conf` como base ao criar novos.

## Arquivos atuais

| Arquivo | Cenário |
|---|---|
| `default.conf` | Fallback genérico (CI sem TTY usa esse) |
| `_template.conf` | Modelo a copiar para criar profile novo |
| `T2070.conf` | Positivo T2070D — factory padrão |
| `L400.conf` | Positivo L400 — factory padrão |
| `L300.conf` | Positivo L300/L3 — factory padrão |

Sinta-se livre pra criar variantes (`<modelo>_<cenario>.conf`).

## Variáveis disponíveis

### Storage
- `MIN_WRITE_MBPS` — velocidade mínima de escrita (MB/s)
- `MIN_READ_MBPS` — velocidade mínima de leitura
- `STORAGE_TEST_SIZE_MB` — tamanho do arquivo de teste

### RAM
- `EXPECTED_RAM_GB` — RAM mínima esperada

### memtester quick (run_full.sh)
- `QUICK_MEMTEST_PERCENT`, `QUICK_MEMTEST_MAX_MB`, `QUICK_MEMTEST_MIN_MB`
- `QUICK_MEMTEST_LOOPS`, `QUICK_MEMTEST_TIMEOUT_S`

### memtester deep (run_deep.sh)
- `MEMTEST_PERCENT`, `MEMTEST_MAX_MB`, `MEMTEST_LOOPS`, `MEMTEST_TIMEOUT_S`
