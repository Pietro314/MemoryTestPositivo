#!/system/bin/sh
# ==============================================================
#  RAM DIAGNOSTIC DEEP SCRIPT - VERBOSE LOG VERSION
#  Objetivo: validacao pesada de hardware (RAM + storage I/O)
#  Alvo: RAM/LPDDR via memtester + storage via dd/md5
#
#  Fluxo:
#  [1-3] Identificacao / RAM info / locate memtester
#  [4]   Storage test (dd 512MB + md5 integridade + W/R MB/s)
#  [5]   Memtester quick (1 loop, ~512MB) — gate rapido
#  [6]   Memtester deep (3 loops, ~2048MB) — SO RODA SE [5] PASSAR
#  [7]   Kernel dmesg analysis
#  [8]   Resultado final
#
#  Early exit: se memtester quick [5] falhar, pula memtester deep [6]
#  pra nao gastar 1h num device ja sabidamente ruim.
#
#  Log gerado em:
#  /data/local/tmp/memtest_work/ram_deep_YYYYMMDD_HHMMSS.log
#
#  Observação:
#  - Este script é mais pesado que o teste de fábrica.
#  - Use em bancada/diagnóstico, não necessariamente em linha de produção.
#  - Mesmo sendo pesado, possui timeout para não ficar preso indefinidamente.
# ==============================================================

# ==============================================================
#  ROOT BOOTSTRAP
#  Se o script for chamado pelo APK sem root, ele tenta reiniciar
#  a si mesmo usando su 0. Isso evita falhas de permissão em comandos
#  como drop_caches, dmesg e acessos protegidos em /sys.
# ==============================================================

BOOTSTRAP_LOG_DIR="/data/local/tmp/memtest_work"
BOOTSTRAP_LOG="$BOOTSTRAP_LOG_DIR/ram_deep_root_bootstrap.log"
mkdir -p "$BOOTSTRAP_LOG_DIR" 2>/dev/null

bootstrap_log() {
    echo "$*"
    echo "$*" >> "$BOOTSTRAP_LOG" 2>/dev/null
}

CURRENT_UID=$(id -u 2>/dev/null)
[ -z "$CURRENT_UID" ] && CURRENT_UID="unknown"

if [ "$CURRENT_UID" != "0" ]; then
    if [ "$RAM_DEEP_ALREADY_TRIED_ROOT" = "1" ]; then
        bootstrap_log "[ROOT_BOOTSTRAP] ERRO: tentativa de root já realizada, mas UID atual ainda é $CURRENT_UID."
        bootstrap_log "[ROOT_BOOTSTRAP] O script continuará sem root, mas alguns comandos podem falhar por permissão."
    else
        export RAM_DEEP_ALREADY_TRIED_ROOT=1
        SCRIPT_PATH="$0"
        bootstrap_log "[ROOT_BOOTSTRAP] UID atual=$CURRENT_UID. Tentando reexecutar como root via su 0."
        bootstrap_log "[ROOT_BOOTSTRAP] Script=$SCRIPT_PATH"

        if command -v su >/dev/null 2>&1; then
            exec su 0 sh "$SCRIPT_PATH" "$@"
            bootstrap_log "[ROOT_BOOTSTRAP] ERRO: exec su 0 retornou inesperadamente."
        else
            bootstrap_log "[ROOT_BOOTSTRAP] ERRO: comando su não encontrado no PATH."
            bootstrap_log "[ROOT_BOOTSTRAP] O script continuará sem root, mas alguns comandos podem falhar."
        fi
    fi
else
    bootstrap_log "[ROOT_BOOTSTRAP] Script já está rodando como root. UID=0."
fi


WORKDIR="/data/local/tmp/memtest_work"
RESULT="PASS"
FAIL_REASONS=""
START_TIME=$(date +%s)
RUN_TS=$(date +%Y%m%d_%H%M%S)

# ---------- Configuração do teste profundo ----------
# Valores lidos do ambiente (definidos pelo memtest_daemon a partir do
# perfil do device cadastrado no APK). Caso nao venham, usa defaults.

# Memtester deep (fase [6])
MEMTEST_PERCENT="${MEMTEST_PERCENT:-60}"
MEMTEST_MAX_MB="${MEMTEST_MAX_MB:-2048}"
MEMTEST_LOOPS="${MEMTEST_LOOPS:-3}"
MEMTEST_TIMEOUT_S="${MEMTEST_TIMEOUT_S:-3600}"
MIN_MEMTEST_MB="${MIN_MEMTEST_MB:-128}"
EXPECTED_RAM_GB="${EXPECTED_RAM_GB:-0}"

# Memtester quick (fase [5] — gate)
QUICK_MEMTEST_PERCENT="${QUICK_MEMTEST_PERCENT:-40}"
QUICK_MEMTEST_MAX_MB="${QUICK_MEMTEST_MAX_MB:-512}"
QUICK_MEMTEST_MIN_MB="${QUICK_MEMTEST_MIN_MB:-128}"
QUICK_MEMTEST_LOOPS="${QUICK_MEMTEST_LOOPS:-1}"
QUICK_MEMTEST_TIMEOUT_S="${QUICK_MEMTEST_TIMEOUT_S:-600}"

# Storage test (fase [4])
MIN_WRITE_MBPS="${MIN_WRITE_MBPS:-50}"
MIN_READ_MBPS="${MIN_READ_MBPS:-100}"
STORAGE_TEST_SIZE_MB="${STORAGE_TEST_SIZE_MB:-512}"

# Flag interna: setada em [5] se memtester quick falhar.
# Usada em [6] pra pular o memtester deep (early exit).
QUICK_MT_FAILED=0
# ---------------------------------------------------

mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

LOGFILE="$WORKDIR/ram_deep_${RUN_TS}.log"
: > "$LOGFILE"

log() {
    echo "$*"
    echo "$*" >> "$LOGFILE"
}

log_blank() {
    echo ""
    echo "" >> "$LOGFILE"
}

log_section() {
    log_blank
    log "============================================="
    log "$1"
    log "============================================="
}

log_debug() {
    log "  [DEBUG] $*"
}

log_warn() {
    log "  ⚠️  WARNING: $*"
}

fail() {
    RESULT="FAIL"
    FAIL_REASONS="$FAIL_REASONS\n  -> $1"
    log "❌  FAIL: $1"
}

log_file_tail() {
    local label="$1"
    local file="$2"
    local lines="$3"
    [ -z "$lines" ] && lines=80

    if [ -f "$file" ]; then
        log_debug "$label: exibindo últimas $lines linhas de $file"
        {
            echo "----- $label: $file -----"
            tail -n "$lines" "$file" 2>/dev/null
            echo "----- fim: $label -----"
        } | tee -a "$LOGFILE"
    else
        log_debug "$label: arquivo não encontrado: $file"
    fi
}

cleanup() {
    log_blank
    log "[CLEANUP] Finalizando limpeza do diagnóstico RAM..."
    # Mata memtester deep se ainda rodando
    if [ -n "$MEMTESTER_PID" ]; then
        if kill -0 "$MEMTESTER_PID" 2>/dev/null; then
            log_warn "memtester deep ainda ativo no cleanup. Encerrando PID=$MEMTESTER_PID"
            kill "$MEMTESTER_PID" 2>/dev/null
            sleep 2
            kill -9 "$MEMTESTER_PID" 2>/dev/null
        fi
    fi
    # Mata memtester quick se ainda rodando
    if [ -n "$QMT_PID" ]; then
        if kill -0 "$QMT_PID" 2>/dev/null; then
            log_warn "memtester quick ainda ativo no cleanup. Encerrando PID=$QMT_PID"
            kill "$QMT_PID" 2>/dev/null
            sleep 2
            kill -9 "$QMT_PID" 2>/dev/null
        fi
    fi
    # Remove temporarios do storage test e memtester quick
    rm -f testfile hash_before.txt hash_after.txt write_speed.txt read_speed.txt memtester_quick.log ram_deep_memtester.log ram_deep_dmesg.txt 2>/dev/null
    log_debug "Log preservado em: $LOGFILE"
}
trap cleanup EXIT INT TERM

log "============================================="
log "  RAM DIAGNOSTIC DEEP - $(date)"
log "============================================="
log "  Log file    : $LOGFILE"
log "  Workdir     : $WORKDIR"
log "  Storage     : ${STORAGE_TEST_SIZE_MB}MB, MIN_W=${MIN_WRITE_MBPS}MB/s, MIN_R=${MIN_READ_MBPS}MB/s"
log "  Quick       : PERCENT=${QUICK_MEMTEST_PERCENT}%, MAX=${QUICK_MEMTEST_MAX_MB}MB, LOOPS=${QUICK_MEMTEST_LOOPS}, TIMEOUT=${QUICK_MEMTEST_TIMEOUT_S}s"
log "  Deep        : PERCENT=${MEMTEST_PERCENT}%, MAX=${MEMTEST_MAX_MB}MB, LOOPS=${MEMTEST_LOOPS}, TIMEOUT=${MEMTEST_TIMEOUT_S}s"
log "  Runtime UID : $(id -u 2>/dev/null) ($(id 2>/dev/null))"
log "  Bootstrap   : $BOOTSTRAP_LOG"

# =============================================
# 1. IDENTIFICAÇÃO DO DISPOSITIVO
# =============================================
log_section "[1] Device identification"

SERIAL=$(getprop ro.serialno 2>/dev/null)
MODEL_PROP=$(getprop ro.product.model 2>/dev/null)
BUILD=$(getprop ro.build.fingerprint 2>/dev/null)
ANDROID_VER=$(getprop ro.build.version.release 2>/dev/null)
SOC_MANUFACTURER=$(getprop ro.soc.manufacturer 2>/dev/null)
HARDWARE=$(getprop ro.hardware 2>/dev/null)
BOARD=$(getprop ro.product.board 2>/dev/null)
BUILD_TYPE=$(getprop ro.build.type 2>/dev/null)
DEBUGGABLE=$(getprop ro.debuggable 2>/dev/null)

[ -z "$SERIAL" ] && SERIAL="N/A"
[ -z "$MODEL_PROP" ] && MODEL_PROP="N/A"
[ -z "$BUILD" ] && BUILD="N/A"
[ -z "$ANDROID_VER" ] && ANDROID_VER="N/A"
[ -z "$SOC_MANUFACTURER" ] && SOC_MANUFACTURER="N/A"
[ -z "$HARDWARE" ] && HARDWARE="N/A"
[ -z "$BOARD" ] && BOARD="N/A"
[ -z "$BUILD_TYPE" ] && BUILD_TYPE="N/A"
[ -z "$DEBUGGABLE" ] && DEBUGGABLE="N/A"

log "  Serial      : $SERIAL"
log "  Model       : $MODEL_PROP"
log "  Android     : $ANDROID_VER"
log "  SoC manuf.  : $SOC_MANUFACTURER"
log "  Hardware    : $HARDWARE"
log "  Board       : $BOARD"
log "  Build type  : $BUILD_TYPE"
log "  Debuggable  : $DEBUGGABLE"
log "  Fingerprint : $BUILD"

# =============================================
# 2. INFORMAÇÕES DE RAM
# =============================================
log_section "[2] RAM info"

# Awk-free pra rodar em Android 7 (toybox antigo sem awk). Le 2a coluna
# via read posicional: 1a=label, 2a=valor, 3a=unidade.
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
MEM_FREE_KB=$(grep MemFree /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
BUFFERS_KB=$(grep '^Buffers:' /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
CACHED_KB=$(grep '^Cached:' /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })
SWAP_FREE_KB=$(grep SwapFree /proc/meminfo 2>/dev/null | { read _ v _; echo "$v"; })

[ -z "$MEM_TOTAL_KB" ] && MEM_TOTAL_KB=0
[ -z "$MEM_AVAIL_KB" ] && MEM_AVAIL_KB=0
[ -z "$MEM_FREE_KB" ] && MEM_FREE_KB=0
[ -z "$BUFFERS_KB" ] && BUFFERS_KB=0
[ -z "$CACHED_KB" ] && CACHED_KB=0
[ -z "$SWAP_TOTAL_KB" ] && SWAP_TOTAL_KB=0
[ -z "$SWAP_FREE_KB" ] && SWAP_FREE_KB=0

MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_FREE_MB=$(( MEM_FREE_KB / 1024 ))
BUFFERS_MB=$(( BUFFERS_KB / 1024 ))
CACHED_MB=$(( CACHED_KB / 1024 ))
SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
SWAP_FREE_MB=$(( SWAP_FREE_KB / 1024 ))
MEM_TOTAL_GB=$(( (MEM_TOTAL_MB + 1023) / 1024 ))

LPDDR_TYPE=$(getprop ro.boot.ddr_type 2>/dev/null)
[ -z "$LPDDR_TYPE" ] && LPDDR_TYPE=$(getprop ro.boot.dram_type 2>/dev/null)
[ -z "$LPDDR_TYPE" ] && LPDDR_TYPE=$(getprop vendor.boot.ddr_type 2>/dev/null)
[ -z "$LPDDR_TYPE" ] && LPDDR_TYPE="N/A"

log "  MemTotal    : ${MEM_TOTAL_MB}MB (~${MEM_TOTAL_GB}GB)"
log "  MemAvailable: ${MEM_AVAIL_MB}MB"
log "  MemFree     : ${MEM_FREE_MB}MB"
log "  Buffers     : ${BUFFERS_MB}MB"
log "  Cached      : ${CACHED_MB}MB"
log "  SwapTotal   : ${SWAP_TOTAL_MB}MB"
log "  SwapFree    : ${SWAP_FREE_MB}MB"
log "  LPDDR type  : $LPDDR_TYPE"

log_debug "Dump completo de /proc/meminfo no log."
{
    echo "----- /proc/meminfo -----"
    cat /proc/meminfo 2>/dev/null
    echo "----- fim /proc/meminfo -----"
} >> "$LOGFILE"

# =============================================
# 3. LOCALIZA MEMTESTER
# =============================================
log_section "[3] Locate memtester"

MEMTESTER_BIN=""
for candidate in /system/bin/memtester /system/xbin/memtester /vendor/bin/memtester /data/local/tmp/memtester "$WORKDIR/memtester"; do
    log_debug "Testando candidate=$candidate"
    if [ -x "$candidate" ]; then
        MEMTESTER_BIN="$candidate"
        break
    fi
done

if [ -z "$MEMTESTER_BIN" ]; then
    MT_EXIT="N/A"
    fail "memtester não encontrado — embarque o binário em /system/bin/memtester, /vendor/bin/memtester ou /data/local/tmp/memtester"
else
    log "  memtester   : $MEMTESTER_BIN"
fi

# =============================================
# 4. STORAGE TEST (dd write/read + md5 integridade)
# =============================================
log_section "[4] Storage test (${STORAGE_TEST_SIZE_MB}MB)"

# Awk-free: pula header (1o read) e le 4a coluna do data row (Available KB).
FREE_KB=$(df /data 2>/dev/null | { read; read _ _ _ v _; echo "$v"; })
[ -z "$FREE_KB" ] && FREE_KB=0
FREE_MB=$(( FREE_KB / 1024 ))
NEEDED_MB=$(( STORAGE_TEST_SIZE_MB + 50 ))

WRITE_MBPS="N/A"
READ_MBPS="N/A"
WRITE_MS="N/A"
READ_MS="N/A"
DD_WRITE_EXIT="N/A"
DD_READ_EXIT="N/A"

log_debug "Espaço livre /data: FREE_KB=$FREE_KB, FREE_MB=$FREE_MB"
log_debug "Espaço necessário: NEEDED_MB=$NEEDED_MB"

if [ "$FREE_MB" -lt "$NEEDED_MB" ] 2>/dev/null; then
    fail "Espaço livre insuficiente em /data: ${FREE_MB}MB disponível, precisa de ${NEEDED_MB}MB"
else
    COUNT=$(( STORAGE_TEST_SIZE_MB / 4 ))
    [ "$COUNT" -lt 1 ] && COUNT=1

    log "  Escrevendo ${STORAGE_TEST_SIZE_MB}MB com dados aleatórios..."
    log_debug "Comando: dd if=/dev/urandom of=testfile bs=4M count=$COUNT conv=fsync"
    T1=$(date +%s%3N 2>/dev/null)
    if [ -z "$T1" ]; then T1=$(( $(date +%s) * 1000 )); fi
    log_debug "T1=$T1"

    dd if=/dev/urandom of=testfile bs=4M count="$COUNT" conv=fsync 2>write_speed.txt
    DD_WRITE_EXIT=$?
    log_debug "DD_WRITE_EXIT=$DD_WRITE_EXIT"
    log_file_tail "dd write output" "write_speed.txt" 20

    T2=$(date +%s%3N 2>/dev/null)
    if [ -z "$T2" ]; then T2=$(( $(date +%s) * 1000 )); fi
    log_debug "T2=$T2"

    WRITE_MS=$(( T2 - T1 ))
    [ "$WRITE_MS" -le 0 ] 2>/dev/null && WRITE_MS=1
    WRITE_MBPS=$(( STORAGE_TEST_SIZE_MB * 1000 / WRITE_MS ))
    log_debug "WRITE_MS=$WRITE_MS, WRITE_MBPS=$WRITE_MBPS"

    if [ "$DD_WRITE_EXIT" -ne 0 ]; then
        fail "Erro ao escrever arquivo de teste no storage"
    fi

    md5sum testfile > hash_before.txt 2>/dev/null
    HASH_BEFORE=$(cat hash_before.txt 2>/dev/null)
    log_debug "HASH_BEFORE='${HASH_BEFORE:-<vazio>}'"

    log_debug "Executando sync"
    sync
    log_debug "Tentando limpar page cache: echo 3 > /proc/sys/vm/drop_caches"
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    DROP_EXIT=$?
    log_debug "drop_caches exit=$DROP_EXIT"

    log "  Lendo ${STORAGE_TEST_SIZE_MB}MB de volta..."
    log_debug "Comando: dd if=testfile of=/dev/null bs=4M"
    T3=$(date +%s%3N 2>/dev/null)
    if [ -z "$T3" ]; then T3=$(( $(date +%s) * 1000 )); fi
    log_debug "T3=$T3"

    dd if=testfile of=/dev/null bs=4M 2>read_speed.txt
    DD_READ_EXIT=$?
    log_debug "DD_READ_EXIT=$DD_READ_EXIT"
    log_file_tail "dd read output" "read_speed.txt" 20

    T4=$(date +%s%3N 2>/dev/null)
    if [ -z "$T4" ]; then T4=$(( $(date +%s) * 1000 )); fi
    log_debug "T4=$T4"

    READ_MS=$(( T4 - T3 ))
    [ "$READ_MS" -le 0 ] 2>/dev/null && READ_MS=1
    READ_MBPS=$(( STORAGE_TEST_SIZE_MB * 1000 / READ_MS ))
    log_debug "READ_MS=$READ_MS, READ_MBPS=$READ_MBPS"

    if [ "$DD_READ_EXIT" -ne 0 ]; then
        fail "Erro ao ler arquivo de teste do storage"
    fi

    log "  Write speed : ~${WRITE_MBPS} MB/s (mín: ${MIN_WRITE_MBPS} MB/s)"
    log "  Read speed  : ~${READ_MBPS} MB/s (mín: ${MIN_READ_MBPS} MB/s)"

    if [ "$WRITE_MBPS" -lt "$MIN_WRITE_MBPS" ] 2>/dev/null; then
        fail "Velocidade de escrita abaixo do mínimo: ${WRITE_MBPS} MB/s (esperado >= ${MIN_WRITE_MBPS} MB/s)"
    else
        log_debug "Velocidade de escrita OK."
    fi
    if [ "$READ_MBPS" -lt "$MIN_READ_MBPS" ] 2>/dev/null; then
        fail "Velocidade de leitura abaixo do mínimo: ${READ_MBPS} MB/s (esperado >= ${MIN_READ_MBPS} MB/s)"
    else
        log_debug "Velocidade de leitura OK."
    fi

    md5sum testfile > hash_after.txt 2>/dev/null
    HASH_AFTER=$(cat hash_after.txt 2>/dev/null)
    log_debug "HASH_AFTER='${HASH_AFTER:-<vazio>}'"
    log_debug "Comparando hash_before.txt e hash_after.txt"

    if ! diff hash_before.txt hash_after.txt > /dev/null 2>&1; then
        fail "Corrupção de dados detectada no storage (hash divergiu)"
    else
        log "  Integridade : OK (hash match)"
    fi
fi

# =============================================
# 5. MEMTESTER QUICK (gate — se falhar pula [6])
# =============================================
log_section "[5] RAM quick validation + memtester"

# Vars locais com prefixo QMT_ pra nao colidir com MEMTEST_* do deep
QMT_PERCENT="$QUICK_MEMTEST_PERCENT"
QMT_MAX_MB="$QUICK_MEMTEST_MAX_MB"
QMT_LOOPS="$QUICK_MEMTEST_LOOPS"
QMT_TIMEOUT_S="$QUICK_MEMTEST_TIMEOUT_S"

QMT_MB=$(( MEM_AVAIL_MB * QMT_PERCENT / 100 ))
[ "$QMT_MB" -gt "$QMT_MAX_MB" ] && QMT_MB="$QMT_MAX_MB"
[ "$QMT_MB" -lt "$QUICK_MEMTEST_MIN_MB" ] && QMT_MB="$QUICK_MEMTEST_MIN_MB"

log "  Modo RAM    : quick (gate)"
log "  MemAvailable: ${MEM_AVAIL_MB}MB"
log "  Testando RAM: ${QMT_MB}MB (${QMT_PERCENT}% da disponível, máx ${QMT_MAX_MB}MB)"
log "  Loops       : ${QMT_LOOPS}"
log "  Timeout     : ${QMT_TIMEOUT_S}s"

QMT_EXIT="N/A"
QMT_DURATION="N/A"

if [ -z "$MEMTESTER_BIN" ]; then
    fail "memtester quick não executado — binário não encontrado"
    QUICK_MT_FAILED=1
else
    log_debug "Pre-ulimit MEMLOCK limit: $(ulimit -l 2>/dev/null)"
    ulimit -l unlimited 2>/dev/null || true
    log_debug "Post-ulimit MEMLOCK limit: $(ulimit -l 2>/dev/null)"

    log_debug "Executando em background: $MEMTESTER_BIN ${QMT_MB}M ${QMT_LOOPS}"
    "$MEMTESTER_BIN" "${QMT_MB}M" "$QMT_LOOPS" > memtester_quick.log 2>&1 &
    QMT_PID=$!
    QMT_EXIT=""
    QMT_START=$(date +%s)
    log_debug "QMT_PID=$QMT_PID, QMT_START=$QMT_START"

    while kill -0 "$QMT_PID" 2>/dev/null; do
        QMT_NOW=$(date +%s)
        QMT_ELAPSED=$(( QMT_NOW - QMT_START ))
        log "  memtester quick em execução... ${QMT_ELAPSED}s/${QMT_TIMEOUT_S}s"

        if [ "$QMT_ELAPSED" -ge "$QMT_TIMEOUT_S" ]; then
            log_warn "Timeout do memtester quick atingido. Encerrando PID=$QMT_PID"
            kill "$QMT_PID" 2>/dev/null
            sleep 2
            if kill -0 "$QMT_PID" 2>/dev/null; then
                log_warn "memtester quick ainda ativo após kill normal. Enviando kill -9."
                kill -9 "$QMT_PID" 2>/dev/null
            fi
            wait "$QMT_PID" 2>/dev/null
            QMT_EXIT=124
            fail "memtester quick excedeu timeout de ${QMT_TIMEOUT_S}s"
            QUICK_MT_FAILED=1
            break
        fi

        sleep 10
    done

    if [ -z "$QMT_EXIT" ]; then
        wait "$QMT_PID"
        QMT_EXIT=$?
    fi

    QMT_END=$(date +%s)
    QMT_DURATION=$(( QMT_END - QMT_START ))
    log_debug "QMT_EXIT=$QMT_EXIT, QMT_DURATION=${QMT_DURATION}s"
    log_file_tail "memtester quick output" "memtester_quick.log" 120

    if [ "$QMT_EXIT" != "0" ] && [ "$QMT_EXIT" != "124" ]; then
        fail "memtester quick retornou exit code $QMT_EXIT"
        QUICK_MT_FAILED=1
    fi

    if grep -qi "FAILURE" memtester_quick.log 2>/dev/null; then
        FAILED_TESTS=$(grep -i "FAILURE" memtester_quick.log | head -5)
        fail "memtester quick reportou FAILURE:\n$FAILED_TESTS"
        QUICK_MT_FAILED=1
    fi

    if [ "$QUICK_MT_FAILED" = "0" ]; then
        log "  memtester quick: OK (exit $QMT_EXIT, duração ${QMT_DURATION}s)"
    fi
fi

# Mata processo quick caso ainda esteja pendente (defensivo)
unset QMT_PID

# =============================================
# 6. MEMTESTER DEEP (só se quick passou)
# =============================================
log_section "[6] Deep RAM memtester"

if [ "$QUICK_MT_FAILED" = "1" ]; then
    log_warn "Memtester quick [5] falhou — pulando memtester deep (early exit)."
    log "  Memtester deep não executado — RAM ja sabidamente com problema."
    MT_EXIT="SKIPPED"
    MT_DURATION=0
    MEMTEST_MB=0
else
    MEMTEST_MB=$(( MEM_AVAIL_MB * MEMTEST_PERCENT / 100 ))
    [ "$MEMTEST_MB" -gt "$MEMTEST_MAX_MB" ] && MEMTEST_MB="$MEMTEST_MAX_MB"
    [ "$MEMTEST_MB" -lt "$MIN_MEMTEST_MB" ] && MEMTEST_MB="$MIN_MEMTEST_MB"

    log "  Modo RAM    : deep/diagnostic"
    log "  Testando RAM: ${MEMTEST_MB}MB (${MEMTEST_PERCENT}% da disponível, máx ${MEMTEST_MAX_MB}MB)"
    log "  Loops       : ${MEMTEST_LOOPS}"
    log "  Timeout     : ${MEMTEST_TIMEOUT_S}s"
    log_warn "Este teste pode demorar. Use para diagnóstico de aparelhos suspeitos."

    if [ -z "$MEMTESTER_BIN" ]; then
        log "  Teste não executado porque memtester não foi encontrado."
        MT_EXIT="N/A"
    else
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        log_debug "Caches solicitados para limpeza, se permitido."

        # Eleva RLIMIT_MEMLOCK pra evitar fake-fast (kernel ignora rlimit se
        # processo tem CAP_SYS_RESOURCE — uid system tem por padrao).
        log_debug "Pre-ulimit MEMLOCK limit: $(ulimit -l 2>/dev/null)"
        ulimit -l unlimited 2>/dev/null || true
        log_debug "Post-ulimit MEMLOCK limit: $(ulimit -l 2>/dev/null)"

        log_debug "Executando em background: $MEMTESTER_BIN ${MEMTEST_MB}M ${MEMTEST_LOOPS}"
        "$MEMTESTER_BIN" "${MEMTEST_MB}M" "$MEMTEST_LOOPS" > ram_deep_memtester.log 2>&1 &
        MEMTESTER_PID=$!
        MT_EXIT=""
        MT_START=$(date +%s)
        LAST_TAIL=0
        log_debug "MEMTESTER_PID=$MEMTESTER_PID, MT_START=$MT_START"

        while kill -0 "$MEMTESTER_PID" 2>/dev/null; do
            MT_NOW=$(date +%s)
            MT_ELAPSED=$(( MT_NOW - MT_START ))
            log "  memtester em execução... ${MT_ELAPSED}s/${MEMTEST_TIMEOUT_S}s"

            if [ $(( MT_ELAPSED - LAST_TAIL )) -ge 60 ]; then
                log_file_tail "memtester progress" "ram_deep_memtester.log" 30
                LAST_TAIL=$MT_ELAPSED
            fi

            if [ "$MT_ELAPSED" -ge "$MEMTEST_TIMEOUT_S" ]; then
                log_warn "Timeout do memtester atingido. Encerrando PID=$MEMTESTER_PID"
                kill "$MEMTESTER_PID" 2>/dev/null
                sleep 2
                if kill -0 "$MEMTESTER_PID" 2>/dev/null; then
                    log_warn "memtester ainda ativo após kill normal. Enviando kill -9."
                    kill -9 "$MEMTESTER_PID" 2>/dev/null
                fi
                wait "$MEMTESTER_PID" 2>/dev/null
                MT_EXIT=124
                fail "memtester excedeu timeout de ${MEMTEST_TIMEOUT_S}s"
                break
            fi

            sleep 15
        done

        if [ -z "$MT_EXIT" ]; then
            wait "$MEMTESTER_PID"
            MT_EXIT=$?
        fi

        MT_END=$(date +%s)
        MT_DURATION=$(( MT_END - MT_START ))
        log_debug "MT_EXIT=$MT_EXIT, MT_DURATION=${MT_DURATION}s"
        log_file_tail "memtester final output" "ram_deep_memtester.log" 200

        if [ "$MT_EXIT" != "0" ]; then
            fail "memtester retornou exit code $MT_EXIT"
        fi

        if grep -qi "FAILURE" ram_deep_memtester.log 2>/dev/null; then
            FAILED_TESTS=$(grep -i "FAILURE" ram_deep_memtester.log | head -10)
            fail "memtester reportou FAILURE:\n$FAILED_TESTS"
        fi

        if [ "$MT_EXIT" = "0" ] && ! grep -qi "FAILURE" ram_deep_memtester.log 2>/dev/null; then
            log "  memtester   : OK (exit $MT_EXIT, duração ${MT_DURATION}s)"
        fi
    fi
fi

# =============================================
# 7. ANÁLISE DO DMESG
# =============================================
log_section "[7] Kernel log analysis"

log_debug "Executando dmesg > ram_deep_dmesg.txt"
dmesg > ram_deep_dmesg.txt 2>/dev/null
DMESG_EXIT=$?
log_debug "DMESG_EXIT=$DMESG_EXIT"

if [ ! -s ram_deep_dmesg.txt ]; then
    log "  dmesg       : não disponível sem permissão/root ou sem conteúdo"
else
    DMESG_ERRORS=$(grep -iE "memory corruption|hardware error|ecc error|uncorrectable|panic|oom|out of memory|page allocation failure|bad page|kernel BUG" ram_deep_dmesg.txt 2>/dev/null)

    if [ -n "$DMESG_ERRORS" ]; then
        log "  Eventos relevantes encontrados no dmesg:"
        echo "$DMESG_ERRORS" | head -20 | while read line; do log "    $line"; done
        fail "Eventos de erro/memória detectados no kernel log"
        {
            echo "----- dmesg matched errors full dump -----"
            echo "$DMESG_ERRORS"
            echo "----- end dmesg matched errors -----"
        } >> "$LOGFILE"
    else
        log "  dmesg       : sem eventos críticos de RAM/hardware"
    fi
fi

# =============================================
# 8. RESULTADO FINAL
# =============================================
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log_section "[8] RESULTADO FINAL"
log "  Serial      : $SERIAL"
log "  Model       : $MODEL_PROP"
log "  Duração     : ${DURATION}s"
log "  RAM total   : ${MEM_TOTAL_MB}MB"
log "  RAM avail.  : ${MEM_AVAIL_MB}MB"
log "  Write MB/s  : ${WRITE_MBPS:-N/A}"
log "  Read MB/s   : ${READ_MBPS:-N/A}"
log "  Quick MB    : ${QMT_MB:-N/A}"
log "  Quick exit  : ${QMT_EXIT:-N/A} (duração ${QMT_DURATION:-N/A}s)"
log "  Deep MB     : ${MEMTEST_MB}"
log "  Deep loops  : ${MEMTEST_LOOPS}"
log "  Deep timeout: ${MEMTEST_TIMEOUT_S}s"
log "  memtester   : ${MEMTESTER_BIN:-N/A}"
log "  Deep exit   : ${MT_EXIT:-N/A}"
log "  Log file    : $LOGFILE"

if [ "$RESULT" = "FAIL" ]; then
    log "  Falhas:"
    printf "$FAIL_REASONS\n" | while read line; do log "$line"; done
fi
log "  Status      : $RESULT"
log "============================================="

{
    echo "RESULT=$RESULT"
    echo "SERIAL=$SERIAL"
    echo "MODEL=$MODEL_PROP"
    echo "TIMESTAMP=$(date +%Y%m%d_%H%M%S)"
    echo "DURATION_S=$DURATION"
    echo "LOGFILE=$LOGFILE"
    echo "RAM_MB=$MEM_TOTAL_MB"
    echo "RAM_AVAILABLE_MB=$MEM_AVAIL_MB"
    echo "WRITE_MBPS=${WRITE_MBPS:-N/A}"
    echo "READ_MBPS=${READ_MBPS:-N/A}"
    echo "WRITE_MS=${WRITE_MS:-N/A}"
    echo "READ_MS=${READ_MS:-N/A}"
    echo "DD_WRITE_EXIT=${DD_WRITE_EXIT:-N/A}"
    echo "DD_READ_EXIT=${DD_READ_EXIT:-N/A}"
    echo "QUICK_MEMTEST_MB=${QMT_MB:-N/A}"
    echo "QUICK_MEMTEST_LOOPS=${QMT_LOOPS:-N/A}"
    echo "QUICK_MEMTEST_EXIT=${QMT_EXIT:-N/A}"
    echo "QUICK_MEMTEST_DURATION_S=${QMT_DURATION:-N/A}"
    echo "QUICK_MT_FAILED=$QUICK_MT_FAILED"
    echo "DEEP_MEMTEST_MB=${MEMTEST_MB}"
    echo "DEEP_MEMTEST_PERCENT=$MEMTEST_PERCENT"
    echo "DEEP_MEMTEST_MAX_MB=$MEMTEST_MAX_MB"
    echo "DEEP_MEMTEST_LOOPS=$MEMTEST_LOOPS"
    echo "DEEP_MEMTEST_TIMEOUT_S=$MEMTEST_TIMEOUT_S"
    echo "MEMTESTER_BIN=${MEMTESTER_BIN:-N/A}"
    echo "DEEP_MEMTESTER_EXIT=${MT_EXIT:-N/A}"
    echo "LPDDR_TYPE=$LPDDR_TYPE"
} > ram_deep_result.txt

log_debug "ram_deep_result.txt gerado em $WORKDIR/ram_deep_result.txt"
log_file_tail "ram_deep_result.txt" "ram_deep_result.txt" 80

if [ "$RESULT" = "PASS" ]; then
    log "✅  RAM DIAGNOSTIC OK"
    exit 0
else
    log "❌  RAM DIAGNOSTIC FAILED"
    exit 1
fi
