#!/system/bin/sh
# ==============================================================
#  RAM DIAGNOSTIC DEEP SCRIPT - VERBOSE LOG VERSION
#  Objetivo: diagnóstico pesado de RAM para aparelhos suspeitos
#  Alvo: RAM/LPDDR usando memtester com timeout controlado
#
#  Log gerado em:
#  /data/data/com.factory.memorytest/files/memtest_work/ram_deep_YYYYMMDD_HHMMSS.log
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

BOOTSTRAP_LOG_DIR="/data/data/com.factory.memorytest/files/memtest_work"
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


WORKDIR="/data/data/com.factory.memorytest/files/memtest_work"
RESULT="PASS"
FAIL_REASONS=""
START_TIME=$(date +%s)
RUN_TS=$(date +%Y%m%d_%H%M%S)

# ---------- Configuração do teste profundo ----------
# Valores lidos do ambiente (definidos pelo memtest_daemon a partir do
# perfil do device cadastrado no APK). Caso nao venham, usa defaults.
MEMTEST_PERCENT="${MEMTEST_PERCENT:-60}"
MEMTEST_MAX_MB="${MEMTEST_MAX_MB:-2048}"
MEMTEST_LOOPS="${MEMTEST_LOOPS:-3}"
MEMTEST_TIMEOUT_S="${MEMTEST_TIMEOUT_S:-3600}"
MIN_MEMTEST_MB="${MIN_MEMTEST_MB:-128}"
EXPECTED_RAM_GB="${EXPECTED_RAM_GB:-0}"
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
        } >> "$LOGFILE"
    else
        log_debug "$label: arquivo não encontrado: $file"
    fi
}

cleanup() {
    log_blank
    log "[CLEANUP] Finalizando limpeza do diagnóstico RAM..."
    if [ -n "$MEMTESTER_PID" ]; then
        if kill -0 "$MEMTESTER_PID" 2>/dev/null; then
            log_warn "memtester ainda ativo no cleanup. Encerrando PID=$MEMTESTER_PID"
            kill "$MEMTESTER_PID" 2>/dev/null
            sleep 2
            kill -9 "$MEMTESTER_PID" 2>/dev/null
        fi
    fi
    log_debug "Log preservado em: $LOGFILE"
}
trap cleanup EXIT INT TERM

log "============================================="
log "  RAM DIAGNOSTIC DEEP - $(date)"
log "============================================="
log "  Log file    : $LOGFILE"
log "  Workdir     : $WORKDIR"
log "  Config      : MEMTEST_PERCENT=${MEMTEST_PERCENT}%, MEMTEST_MAX=${MEMTEST_MAX_MB}MB, LOOPS=${MEMTEST_LOOPS}, TIMEOUT=${MEMTEST_TIMEOUT_S}s"
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

MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
MEM_FREE_KB=$(grep MemFree /proc/meminfo 2>/dev/null | awk '{print $2}')
BUFFERS_KB=$(grep '^Buffers:' /proc/meminfo 2>/dev/null | awk '{print $2}')
CACHED_KB=$(grep '^Cached:' /proc/meminfo 2>/dev/null | awk '{print $2}')
SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
SWAP_FREE_KB=$(grep SwapFree /proc/meminfo 2>/dev/null | awk '{print $2}')

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
# 4. TESTE PROFUNDO DE RAM
# =============================================
log_section "[4] Deep RAM memtester"

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
else
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log_debug "Caches solicitados para limpeza, se permitido."

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

# =============================================
# 5. ANÁLISE DO DMESG
# =============================================
log_section "[5] Kernel log analysis"

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
# 6. RESULTADO FINAL
# =============================================
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log_section "[6] RESULTADO FINAL"
log "  Serial      : $SERIAL"
log "  Model       : $MODEL_PROP"
log "  Duração     : ${DURATION}s"
log "  RAM total   : ${MEM_TOTAL_MB}MB"
log "  RAM avail.  : ${MEM_AVAIL_MB}MB"
log "  RAM testada : ${MEMTEST_MB}MB"
log "  Loops       : ${MEMTEST_LOOPS}"
log "  Timeout     : ${MEMTEST_TIMEOUT_S}s"
log "  memtester   : ${MEMTESTER_BIN:-N/A}"
log "  Exit code   : ${MT_EXIT:-N/A}"
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
    echo "RAM_TESTED_MB=$MEMTEST_MB"
    echo "MEMTEST_PERCENT=$MEMTEST_PERCENT"
    echo "MEMTEST_MAX_MB=$MEMTEST_MAX_MB"
    echo "MEMTEST_LOOPS=$MEMTEST_LOOPS"
    echo "MEMTEST_TIMEOUT_S=$MEMTEST_TIMEOUT_S"
    echo "MEMTESTER_BIN=${MEMTESTER_BIN:-N/A}"
    echo "MEMTESTER_EXIT=${MT_EXIT:-N/A}"
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
