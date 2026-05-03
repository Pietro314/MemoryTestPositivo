#!/system/bin/sh
# ==============================================================
#  ROOT RE-EXEC GUARD
#  Se o script for iniciado pelo APK sem root, ele tenta reiniciar
#  a si mesmo como root usando: su 0 sh <script>.
#  Isso só funciona em builds que possuem su permitido, ex: userdebug/eng.
# ==============================================================

REQUIRE_ROOT="1"
ROOT_REEXEC_DONE="${ROOT_REEXEC_DONE:-0}"
CURRENT_UID=$(id -u 2>/dev/null)
[ -z "$CURRENT_UID" ] && CURRENT_UID=$(id 2>/dev/null | sed 's/uid=//;s/(.*//;s/ .*//')

if [ "$REQUIRE_ROOT" = "1" ] && [ "$CURRENT_UID" != "0" ]; then
    echo "[BOOTSTRAP] Script iniciado sem root. UID atual: ${CURRENT_UID:-desconhecido}"
    echo "[BOOTSTRAP] Tentando reiniciar como root usando su 0..."

    if [ "$ROOT_REEXEC_DONE" = "1" ]; then
        echo "[BOOTSTRAP][ERRO] Já foi feita uma tentativa de su, mas o script ainda não está como root. Abortando."
        exit 126
    fi

    SELF_PATH="$0"
    if [ ! -f "$SELF_PATH" ]; then
        # fallback comum quando o script é chamado de formas diferentes
        SELF_PATH="/data/user/0/com.factory.memorytest/files/full_memtest.sh"
    fi

    SU_BIN=""
    for candidate in /system/xbin/su /system/bin/su /sbin/su su; do
        if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
            SU_BIN="$candidate"
            break
        fi
    done

    if [ -z "$SU_BIN" ]; then
        echo "[BOOTSTRAP][ERRO] su não encontrado. O script precisa de root para executar todos os testes."
        echo "[BOOTSTRAP][ERRO] Em userdebug, teste pelo CMD/terminal: adb root ou adb shell su 0 id"
        exit 126
    fi

    echo "[BOOTSTRAP] su encontrado em: $SU_BIN"
    echo "[BOOTSTRAP] Reexecutando: $SU_BIN 0 sh $SELF_PATH $*"

    export ROOT_REEXEC_DONE="1"
    exec "$SU_BIN" 0 sh "$SELF_PATH" "$@"

    echo "[BOOTSTRAP][ERRO] Falha ao executar su."
    exit 126
fi

if [ "$CURRENT_UID" = "0" ]; then
    echo "[BOOTSTRAP] Executando como root: $(id 2>/dev/null)"
else
    echo "[BOOTSTRAP] Executando sem root: $(id 2>/dev/null)"
fi

# ==============================================================
#  FACTORY MEMORY VALIDATION SCRIPT - QUICK RAM + VERBOSE LOG VERSION
#  Objetivo: detectar memorias com defeito antes de ir a campo
#  Alvos: UFS / MMC/eMMC (storage) + RAM (LPDDR)
#
#  Esta versão gera log detalhado em:
#  $WORKDIR/memtest_full_YYYYMMDD_HHMMSS.log
#
#  Correções principais:
#  - Leitura de Life Time em eMMC/MMC com fallback para arquivo único "life_time"
#    Exemplo Allwinner: /sys/block/mmcblk*/device/life_time -> "0x04 0x03"
#  - Mantém compatibilidade com vendors que expõem life_time_type_a/b
#  - Fallbacks adicionais para pre_eol_info, CID, modelo e vendor
#  - Logs detalhados de caminhos encontrados, valores lidos, decisões e resultados
#  - Teste de RAM rápido com timeout; stress paralelo infinito removido
# ==============================================================

WORKDIR="/data/vendor/memtest"
RESULT="PASS"
FAIL_REASONS=""
START_TIME=$(date +%s)
RUN_TS=$(date +%Y%m%d_%H%M%S)

# ---------- Thresholds configuráveis por SKU ----------
# Valores lidos do ambiente (definidos pelo memtest_daemon a partir do
# perfil do device cadastrado no APK). Caso nao venham, usa defaults.
MIN_WRITE_MBPS="${MIN_WRITE_MBPS:-50}"
MIN_READ_MBPS="${MIN_READ_MBPS:-100}"
EXPECTED_RAM_GB="${EXPECTED_RAM_GB:-4}"
STORAGE_TEST_SIZE_MB="${STORAGE_TEST_SIZE_MB:-512}"
# Quick RAM test parameters
QUICK_MEMTEST_PERCENT="${QUICK_MEMTEST_PERCENT:-40}"
QUICK_MEMTEST_MAX_MB="${QUICK_MEMTEST_MAX_MB:-512}"
QUICK_MEMTEST_MIN_MB="${QUICK_MEMTEST_MIN_MB:-128}"
QUICK_MEMTEST_LOOPS="${QUICK_MEMTEST_LOOPS:-1}"
QUICK_MEMTEST_TIMEOUT_S="${QUICK_MEMTEST_TIMEOUT_S:-600}"
# ------------------------------------------------------

mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

LOGFILE="$WORKDIR/memtest_full_${RUN_TS}.log"
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

log_kv() {
    # Uso: log_kv "Nome" "Valor"
    log "  $1 : $2"
}

log_debug() {
    log "  [DEBUG] $*"
}

log_debug_file() {
    # Igual ao log_debug, mas só escreve no arquivo de log — nunca em stdout.
    # Use dentro de funções que retornam valor via stdout (read_first_file,
    # find_first_file, log_file_value) e em blocos de detecção verbosos
    # cujo output polui o relatório visto pelo usuário (ex.: tentativas de UFS).
    echo "  [DEBUG] $*" >> "$LOGFILE"
}

log_warn() {
    log "  ⚠️  WARNING: $*"
}

log_file_value() {
    # Uso: log_file_value "Label" "/path/file"
    # Função retorna valor via stdout — usa log_debug_file para não poluir.
    local label="$1"
    local file="$2"
    local val=""

    if [ -f "$file" ]; then
        val=$(cat "$file" 2>/dev/null)
        log_debug_file "$label: arquivo encontrado: $file"
        log_debug_file "$label: valor lido: ${val:-<vazio>}"
        echo "$val"
        return 0
    fi

    log_debug_file "$label: arquivo não existe: $file"
    return 1
}

log_file_tail() {
    # Uso: log_file_tail "Label" "arquivo" "linhas"
    local label="$1"
    local file="$2"
    local lines="$3"

    [ -z "$lines" ] && lines=20

    if [ -f "$file" ]; then
        log_debug "$label: exibindo últimas $lines linhas de $file"
        {
            echo "----- $label: $file -----"
            tail -n "$lines" "$file" 2>/dev/null
            echo "----- fim: $label -----"
        } >> "$LOGFILE"
    else
        log_debug "$label: arquivo não encontrado para dump: $file"
    fi
}

cleanup() {
    log_blank
    log "[CLEANUP] Removendo arquivos temporários..."
    log_debug "WORKDIR=$WORKDIR"
    rm -f testfile hash_before.txt hash_after.txt write_speed.txt read_speed.txt dmesg.txt memtester.log result.txt.tmp
    if [ -n "$STRESS_PGID" ]; then
        log_debug "Tentando encerrar STRESS_PGID=$STRESS_PGID"
        kill -- -"$STRESS_PGID" 2>/dev/null
        kill "$STRESS_PGID" 2>/dev/null
    fi
    log_debug "Log preservado em: $LOGFILE"
}
trap cleanup EXIT INT TERM

fail() {
    RESULT="FAIL"
    FAIL_REASONS="$FAIL_REASONS\n  -> $1"
    log "❌  FAIL: $1"
}

# Converte valores como "0x04" ou "4" para decimal.
# Retorna vazio se não conseguir converter.
to_dec() {
    local v="$1"

    case "$v" in
        ""|"N/A")
            echo ""
            ;;
        0x*|0X*)
            printf "%d" "$v" 2>/dev/null
            ;;
        *)
            printf "%d" "$v" 2>/dev/null
            ;;
    esac
}

lifetime_warn() {
    local label="$1"
    local val="$2"
    local dec
    dec=$(to_dec "$val")

    log_debug "$label: valor bruto='$val', decimal='${dec:-N/A}'"

    if [ -n "$dec" ] && [ "$dec" -gt 4 ] 2>/dev/null; then
        local pct_low=$(( (dec - 1) * 10 ))
        local pct_high=$(( dec * 10 ))
        log_warn "$label = $val (desgaste estimado ${pct_low}-${pct_high}%, acima de 40%)"
    else
        log "  $label      : $val"
    fi
}

read_first_file() {
    # Lê o primeiro arquivo existente de uma lista de caminhos.
    # Uso: read_first_file /path/a /path/b ...
    # IMPORTANTE: retorna valor via stdout. Usa log_debug_file para não
    # contaminar o valor capturado em $(read_first_file ...).
    local f
    local val

    for f in "$@"; do
        log_debug_file "read_first_file: testando $f"
        if [ -f "$f" ]; then
            val=$(cat "$f" 2>/dev/null)
            log_debug_file "read_first_file: escolhido $f"
            log_debug_file "read_first_file: valor='${val:-<vazio>}'"
            echo "$val"
            return 0
        fi
    done

    log_debug_file "read_first_file: nenhum arquivo encontrado"
    return 1
}

find_first_file() {
    # Procura arquivo por nome em /sys, escondendo Permission denied.
    # Uso: find_first_file life_time
    # Retorna valor via stdout — usa log_debug_file para não poluir.
    local name="$1"
    local found
    log_debug_file "find_first_file: procurando em /sys por name='$name'"
    found=$(find /sys -name "$name" 2>/dev/null | head -n1)
    log_debug_file "find_first_file: resultado='${found:-<não encontrado>}'"
    echo "$found"
}

log "============================================="
log "  FACTORY MEMORY TEST - $(date)"
log "============================================="
log "  Log file    : $LOGFILE"
log "  Workdir     : $WORKDIR"
log "  Thresholds  : MIN_WRITE=${MIN_WRITE_MBPS}MB/s, MIN_READ=${MIN_READ_MBPS}MB/s, EXPECTED_RAM=${EXPECTED_RAM_GB}GB, STORAGE_TEST=${STORAGE_TEST_SIZE_MB}MB"

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
DEVICE=$(getprop ro.product.device 2>/dev/null)
BRAND=$(getprop ro.product.brand 2>/dev/null)
BUILD_TYPE=$(getprop ro.build.type 2>/dev/null)
DEBUGGABLE=$(getprop ro.debuggable 2>/dev/null)

[ -z "$SERIAL" ] && SERIAL="N/A"
[ -z "$MODEL_PROP" ] && MODEL_PROP="N/A"
[ -z "$BUILD" ] && BUILD="N/A"
[ -z "$ANDROID_VER" ] && ANDROID_VER="N/A"
[ -z "$SOC_MANUFACTURER" ] && SOC_MANUFACTURER="N/A"
[ -z "$HARDWARE" ] && HARDWARE="N/A"
[ -z "$BOARD" ] && BOARD="N/A"
[ -z "$DEVICE" ] && DEVICE="N/A"
[ -z "$BRAND" ] && BRAND="N/A"
[ -z "$BUILD_TYPE" ] && BUILD_TYPE="N/A"
[ -z "$DEBUGGABLE" ] && DEBUGGABLE="N/A"

log_kv "Serial      " "$SERIAL"
log_kv "Brand       " "$BRAND"
log_kv "Model       " "$MODEL_PROP"
log_kv "Device      " "$DEVICE"
log_kv "Android     " "$ANDROID_VER"
log_kv "Build type  " "$BUILD_TYPE"
log_kv "Debuggable  " "$DEBUGGABLE"
log_kv "Hardware    " "$HARDWARE"
log_kv "Board       " "$BOARD"
log_kv "SoC vendor  " "$SOC_MANUFACTURER"
log_kv "Fingerprint " "$BUILD"

# =============================================
# 2. INFORMAÇÕES DE STORAGE
# =============================================
log_section "[2] Storage info"

LIFE_A="N/A"
LIFE_B="N/A"
PRE_EOL="N/A"
STOR_MODEL="N/A"
VENDOR="N/A"
TYPE="UNKNOWN"
CID=""
MMC_DEV_PATH=""
LIFE_SOURCE="N/A"
PRE_EOL_SOURCE="N/A"
CID_PATH=""
UFS_HEALTH_DIR=""
UFS_CANDIDATE=""

# Detecção silenciosa: tenta UFS, depois MMC/eMMC. O usuário só vê o tipo
# que foi efetivamente detectado — mensagens de tentativa/falha vão pro
# arquivo de log para diagnóstico, mas não aparecem no relatório.
log_debug_file "Iniciando detecção de storage. Ordem: UFS primeiro, depois MMC/eMMC."

# ---------- UFS ----------
log_debug_file "Procurando UFS health_descriptor em caminhos comuns."
for d in \
    /sys/devices/platform/soc/*ufs*/health_descriptor \
    /sys/bus/platform/devices/*ufs*/health_descriptor
    do
        log_debug_file "Testando UFS health dir: $d"
        if [ -d "$d" ]; then
            UFS_HEALTH_DIR="$d"
            log_debug_file "UFS health_descriptor encontrado: $UFS_HEALTH_DIR"
            break
        fi
    done

if [ -z "$UFS_HEALTH_DIR" ]; then
    log_debug_file "UFS health_descriptor não encontrado nos caminhos comuns. Usando find fallback."
    UFS_HEALTH_DIR=$(find /sys -maxdepth 8 -path "*/health_descriptor" -type d 2>/dev/null | head -n1)
    log_debug_file "Resultado find UFS_HEALTH_DIR='${UFS_HEALTH_DIR:-<não encontrado>}'"
fi

if [ -n "$UFS_HEALTH_DIR" ] && [ -d "$UFS_HEALTH_DIR" ]; then
    TYPE="UFS"
    UFS_CANDIDATE=$(dirname "$UFS_HEALTH_DIR")
    log_debug_file "Storage detectado como UFS. Base=$UFS_CANDIDATE"

    LIFE_A=$(cat "$UFS_HEALTH_DIR/life_time_estimation_a" 2>/dev/null)
    LIFE_B=$(cat "$UFS_HEALTH_DIR/life_time_estimation_b" 2>/dev/null)
    PRE_EOL=$(cat "$UFS_HEALTH_DIR/pre_eol_info" 2>/dev/null)
    LIFE_SOURCE="$UFS_HEALTH_DIR/life_time_estimation_a + life_time_estimation_b"
    PRE_EOL_SOURCE="$UFS_HEALTH_DIR/pre_eol_info"

    log_debug_file "UFS LIFE_A raw='${LIFE_A:-<vazio>}'"
    log_debug_file "UFS LIFE_B raw='${LIFE_B:-<vazio>}'"
    log_debug_file "UFS PRE_EOL raw='${PRE_EOL:-<vazio>}'"

    [ -z "$LIFE_A" ] && LIFE_A="N/A"
    [ -z "$LIFE_B" ] && LIFE_B="N/A"
    [ -z "$PRE_EOL" ] && PRE_EOL="N/A"

    STOR_MODEL=$(cat "$UFS_CANDIDATE/string_descriptors/product_name" 2>/dev/null)
    VENDOR=$(cat "$UFS_CANDIDATE/string_descriptors/manufacturer_name" 2>/dev/null)
    log_debug_file "UFS product_name='${STOR_MODEL:-<vazio>}'"
    log_debug_file "UFS manufacturer_name='${VENDOR:-<vazio>}'"
    [ -z "$STOR_MODEL" ] && STOR_MODEL="N/A"
    [ -z "$VENDOR" ] && VENDOR="N/A"
else
    log_debug_file "UFS não detectado. Continuando para MMC/eMMC."
fi

# ---------- MMC/eMMC ----------
if [ "$TYPE" = "UNKNOWN" ]; then
    log_debug_file "Procurando CID de MMC/eMMC em /sys/class/mmc_host/mmc*/mmc*:*/cid"
    CID_PATH=$(ls /sys/class/mmc_host/mmc*/mmc*:*/cid 2>/dev/null | head -n1)
    log_debug_file "CID_PATH após caminho clássico='${CID_PATH:-<não encontrado>}'"

    if [ -z "$CID_PATH" ]; then
        log_debug_file "CID não encontrado no caminho clássico. Tentando /sys/block/mmcblk*/device/cid"
        CID_PATH=$(ls /sys/block/mmcblk*/device/cid 2>/dev/null | head -n1)
        log_debug_file "CID_PATH após /sys/block='${CID_PATH:-<não encontrado>}'"
    fi

    if [ -z "$CID_PATH" ]; then
        log_debug_file "CID ainda não encontrado. Usando find_first_file cid"
        CID_PATH=$(find_first_file cid)
    fi

    if [ -n "$CID_PATH" ] && [ -f "$CID_PATH" ]; then
        TYPE="MMC"
        MMC_DEV_PATH=$(dirname "$CID_PATH")
        CID=$(cat "$CID_PATH" 2>/dev/null)

        log_debug_file "Storage detectado como MMC/eMMC"
        log_debug_file "CID_PATH=$CID_PATH"
        log_debug_file "MMC_DEV_PATH=$MMC_DEV_PATH"
        log_debug_file "CID='${CID:-<vazio>}'"

        STOR_MODEL=$(read_first_file "$MMC_DEV_PATH/name" /sys/block/mmcblk*/device/name)
        VENDOR_ID=$(read_first_file "$MMC_DEV_PATH/manfid" /sys/block/mmcblk*/device/manfid)
        log_debug_file "STOR_MODEL inicial via sysfs='${STOR_MODEL:-<vazio>}'"
        log_debug_file "VENDOR_ID inicial via sysfs='${VENDOR_ID:-<vazio>}'"

        if [ -n "$CID" ]; then
            MID=$(echo "$CID" | cut -c1-2)
            PNM_HEX=$(echo "$CID" | cut -c5-14)
            CID_MODEL=$(printf "$(echo "$PNM_HEX" | sed 's/\(..\)/\\x\1/g')" 2>/dev/null)
            log_debug_file "CID parse: MID=$MID, PNM_HEX=$PNM_HEX, CID_MODEL='${CID_MODEL:-<vazio>}'"
            [ -z "$STOR_MODEL" ] && STOR_MODEL="$CID_MODEL"
            [ -z "$VENDOR_ID" ] && VENDOR_ID="MID:$MID"
        fi

        [ -z "$STOR_MODEL" ] && STOR_MODEL="N/A"
        [ -z "$VENDOR_ID" ] && VENDOR_ID="N/A"
        VENDOR="$VENDOR_ID"

        log_debug_file "Tentando Life Time por arquivos separados de vendor."
        LIFE_A=$(read_first_file \
            "$MMC_DEV_PATH/life_time_type_a" \
            "$MMC_DEV_PATH/life_time_estimation_a" \
            /sys/block/mmcblk*/device/life_time_type_a \
            /sys/block/mmcblk*/device/life_time_estimation_a)

        LIFE_B=$(read_first_file \
            "$MMC_DEV_PATH/life_time_type_b" \
            "$MMC_DEV_PATH/life_time_estimation_b" \
            /sys/block/mmcblk*/device/life_time_type_b \
            /sys/block/mmcblk*/device/life_time_estimation_b)

        if [ -n "$LIFE_A" ]; then
            LIFE_SOURCE="vendor separated files: life_time_type_a/life_time_estimation_a"
        fi
        if [ -n "$LIFE_B" ] && [ "$LIFE_SOURCE" = "N/A" ]; then
            LIFE_SOURCE="vendor separated files: life_time_type_b/life_time_estimation_b"
        fi

        [ -z "$LIFE_A" ] && LIFE_A="N/A"
        [ -z "$LIFE_B" ] && LIFE_B="N/A"

        log_debug_file "Após arquivos separados: LIFE_A=$LIFE_A, LIFE_B=$LIFE_B, LIFE_SOURCE=$LIFE_SOURCE"

        # Caso 2: padrão comum em kernels Linux/Allwinner:
        # arquivo único life_time, exemplo: "0x04 0x03".
        if [ "$LIFE_A" = "N/A" ] || [ "$LIFE_B" = "N/A" ]; then
            LIFE_RAW=""
            LIFE_TIME_FILE=""

            log_debug_file "Life Time separado incompleto. Tentando arquivo único life_time."

            if [ -f "$MMC_DEV_PATH/life_time" ]; then
                LIFE_TIME_FILE="$MMC_DEV_PATH/life_time"
                LIFE_RAW=$(cat "$LIFE_TIME_FILE" 2>/dev/null)
                log_debug_file "life_time encontrado via MMC_DEV_PATH: $LIFE_TIME_FILE"
                log_debug_file "LIFE_RAW='$LIFE_RAW'"
            fi

            if [ -z "$LIFE_RAW" ]; then
                log_debug_file "Tentando life_time via /sys/block/mmcblk*/device/life_time"
                for f in /sys/block/mmcblk*/device/life_time; do
                    log_debug_file "Testando $f"
                    if [ -f "$f" ]; then
                        LIFE_TIME_FILE="$f"
                        LIFE_RAW=$(cat "$f" 2>/dev/null)
                        log_debug_file "Arquivo life_time escolhido: $f"
                        log_debug_file "LIFE_RAW='$LIFE_RAW'"
                        [ -n "$LIFE_RAW" ] && break
                    fi
                done
            fi

            if [ -z "$LIFE_RAW" ]; then
                log_debug_file "Tentando life_time via find_first_file"
                LIFE_TIME_FILE=$(find_first_file life_time)
                if [ -n "$LIFE_TIME_FILE" ] && [ -f "$LIFE_TIME_FILE" ]; then
                    LIFE_RAW=$(cat "$LIFE_TIME_FILE" 2>/dev/null)
                    log_debug_file "Arquivo life_time escolhido via find: $LIFE_TIME_FILE"
                    log_debug_file "LIFE_RAW='$LIFE_RAW'"
                fi
            fi

            if [ -n "$LIFE_RAW" ]; then
                LIFE_A_TMP=$(echo "$LIFE_RAW" | awk '{print $1}')
                LIFE_B_TMP=$(echo "$LIFE_RAW" | awk '{print $2}')

                log_debug_file "Parse LIFE_RAW: LIFE_A_TMP='$LIFE_A_TMP', LIFE_B_TMP='$LIFE_B_TMP'"

                [ -n "$LIFE_A_TMP" ] && LIFE_A="$LIFE_A_TMP"
                [ -n "$LIFE_B_TMP" ] && LIFE_B="$LIFE_B_TMP"
                LIFE_SOURCE="$LIFE_TIME_FILE"
            else
                log_debug_file "Nenhum life_time encontrado ou lido. LifeTime permanecerá N/A."
            fi
        fi

        log_debug_file "Tentando Pre-EOL."
        PRE_EOL=$(read_first_file \
            "$MMC_DEV_PATH/pre_eol_info" \
            /sys/block/mmcblk*/device/pre_eol_info)

        if [ -n "$PRE_EOL" ]; then
            PRE_EOL_SOURCE="$MMC_DEV_PATH/pre_eol_info ou /sys/block/mmcblk*/device/pre_eol_info"
        fi

        if [ -z "$PRE_EOL" ]; then
            log_debug_file "Pre-EOL não encontrado em caminhos diretos. Usando find_first_file."
            PRE_EOL_FILE=$(find_first_file pre_eol_info)
            if [ -n "$PRE_EOL_FILE" ] && [ -f "$PRE_EOL_FILE" ]; then
                PRE_EOL=$(cat "$PRE_EOL_FILE" 2>/dev/null)
                PRE_EOL_SOURCE="$PRE_EOL_FILE"
                log_debug_file "PRE_EOL via find: file=$PRE_EOL_FILE, value='$PRE_EOL'"
            fi
        fi

        [ -z "$LIFE_A" ] && LIFE_A="N/A"
        [ -z "$LIFE_B" ] && LIFE_B="N/A"
        [ -z "$PRE_EOL" ] && PRE_EOL="N/A"
    else
        log_debug_file "Nenhum CID válido encontrado. Storage permanece TYPE=UNKNOWN."
    fi
fi

# Capacidade: tenta blockdev primeiro, fallback via df.
log_debug "Iniciando detecção de capacidade."
STOR_BLOCK=""
if [ -e /dev/block/by-name/userdata ]; then
    log_debug "Encontrado /dev/block/by-name/userdata. Resolvendo link."
    STOR_BLOCK=$(readlink -f /dev/block/by-name/userdata 2>/dev/null | sed 's/p[0-9]*$//' | head -n1)
    log_debug "STOR_BLOCK via userdata='$STOR_BLOCK'"
fi

if [ -z "$STOR_BLOCK" ]; then
    log_debug "STOR_BLOCK vazio. Tentando /dev/block/mmcblk0 ou /dev/block/sd*"
    STOR_BLOCK=$(ls /dev/block/mmcblk0 /dev/block/sd* 2>/dev/null | head -n1)
    log_debug "STOR_BLOCK fallback='$STOR_BLOCK'"
fi

STOR_GB="N/A"
if [ -n "$STOR_BLOCK" ] && [ -e "$STOR_BLOCK" ]; then
    STOR_BYTES=$(blockdev --getsize64 "$STOR_BLOCK" 2>/dev/null)
    log_debug_file "blockdev --getsize64 $STOR_BLOCK => '${STOR_BYTES:-<vazio>}'"
    # Usa awk (aritmética 64-bit) em vez de $(( )) — o shell embarcado
    # do Android (mksh) usa inteiros 32-bit e estouraria com chips >= 4GB,
    # caindo no fallback errado e reportando o tamanho da partição /data
    # em vez do tamanho físico do chip.
    if [ -n "$STOR_BYTES" ]; then
        STOR_GB=$(awk -v b="$STOR_BYTES" 'BEGIN { if (b+0 > 0) printf "%d", b/1024/1024/1024 }')
        [ -z "$STOR_GB" ] && STOR_GB="N/A"
    fi
else
    log_debug_file "STOR_BLOCK não encontrado ou não existe. Pulando blockdev."
fi

if [ "$STOR_GB" = "N/A" ] || [ "$STOR_GB" = "0" ]; then
    log_debug_file "Capacidade via blockdev indisponível. Usando df /data."
    DF_KB=$(df /data 2>/dev/null | awk 'NR==2{print $2}')
    log_debug_file "df /data total KB='${DF_KB:-<vazio>}'"
    if [ -n "$DF_KB" ] && [ "$DF_KB" -gt 0 ] 2>/dev/null; then
        STOR_GB=$(awk -v k="$DF_KB" 'BEGIN { printf "%d", k/1024/1024 }')
        [ -z "$STOR_GB" ] || [ "$STOR_GB" = "0" ] && STOR_GB=1
    fi
fi

log "  Type        : $TYPE"
log "  Vendor      : $VENDOR"
log "  Model       : $STOR_MODEL"
log "  Capacity    : ${STOR_GB}GB"
# Só mostra a origem dos campos de saúde quando temos dado real — evita
# linhas com "N/A" que confundem o leitor sem agregar informação.
if [ "$LIFE_A" != "N/A" ] || [ "$LIFE_B" != "N/A" ]; then
    log "  Life source : $LIFE_SOURCE"
fi
if [ "$PRE_EOL" != "N/A" ]; then
    log "  EOL source  : $PRE_EOL_SOURCE"
fi

lifetime_warn "LifeTimeA" "$LIFE_A"
lifetime_warn "LifeTimeB" "$LIFE_B"

PRE_EOL_DEC=$(to_dec "$PRE_EOL")
log_debug_file "Pre-EOL: valor bruto='$PRE_EOL', decimal='${PRE_EOL_DEC:-N/A}'"
case "$PRE_EOL" in
    "N/A"|"0x01"|"1")
        log "  Pre-EOL     : $PRE_EOL (normal)" ;;
    "0x02"|"2")
        log_warn "Pre-EOL = $PRE_EOL (spare blocks ~80% consumidos)" ;;
    "0x03"|"3")
        fail "Pre-EOL = $PRE_EOL (spare blocks esgotados — memória crítica)" ;;
    *)
        log_warn "Pre-EOL = $PRE_EOL (valor desconhecido)" ;;
esac

# =============================================
# 3. INFORMAÇÕES DE RAM
# =============================================
log_section "[3] RAM info"

MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
[ -z "$MEM_TOTAL_KB" ] && MEM_TOTAL_KB=0
[ -z "$MEM_AVAIL_KB" ] && MEM_AVAIL_KB=0

log_debug "MemTotal raw KB=$MEM_TOTAL_KB"
log_debug "MemAvailable raw KB=$MEM_AVAIL_KB"

MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_TOTAL_GB=$(( (MEM_TOTAL_MB + 1023) / 1024 ))

LPDDR_TYPE=$(getprop ro.boot.ddr_type 2>/dev/null)
log_debug "getprop ro.boot.ddr_type='${LPDDR_TYPE:-<vazio>}'"
if [ -z "$LPDDR_TYPE" ]; then
    LPDDR_TYPE=$(getprop ro.boot.dram_type 2>/dev/null)
    log_debug "getprop ro.boot.dram_type='${LPDDR_TYPE:-<vazio>}'"
fi
if [ -z "$LPDDR_TYPE" ]; then
    LPDDR_TYPE=$(getprop vendor.boot.ddr_type 2>/dev/null)
    log_debug "getprop vendor.boot.ddr_type='${LPDDR_TYPE:-<vazio>}'"
fi
if [ -z "$LPDDR_TYPE" ]; then
    LPDDR_TYPE="N/A"
fi

log "  Total RAM   : ${MEM_TOTAL_MB} MB (~${MEM_TOTAL_GB} GB)"
log "  Available   : ${MEM_AVAIL_MB} MB"
log "  LPDDR type  : $LPDDR_TYPE"
log_debug "Comparando RAM detectada ${MEM_TOTAL_GB}GB com esperado mínimo ${EXPECTED_RAM_GB}GB"

if [ "$MEM_TOTAL_GB" -lt "$EXPECTED_RAM_GB" ] 2>/dev/null; then
    fail "RAM insuficiente: ${MEM_TOTAL_GB}GB detectado, esperado mínimo ${EXPECTED_RAM_GB}GB"
else
    log_debug "RAM OK para o threshold configurado."
fi

# =============================================
# 4. TESTE DE STORAGE
# =============================================
log_section "[4] Storage test (${STORAGE_TEST_SIZE_MB}MB)"

FREE_KB=$(df /data 2>/dev/null | awk 'NR==2{print $4}')
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
# 5. TESTE DE RAM RÁPIDO
# =============================================
log_section "[5] RAM quick validation + memtester"

# Teste rápido de fábrica: controlado, sem stress paralelo infinito.
# Objetivo: detectar falhas evidentes sem travar a linha de produção.
MEMTEST_PERCENT="$QUICK_MEMTEST_PERCENT"
MEMTEST_MAX_MB="$QUICK_MEMTEST_MAX_MB"
MEMTEST_LOOPS="$QUICK_MEMTEST_LOOPS"
MEMTEST_TIMEOUT_S="$QUICK_MEMTEST_TIMEOUT_S"

MEMTEST_MB=$(( MEM_AVAIL_MB * MEMTEST_PERCENT / 100 ))
[ "$MEMTEST_MB" -gt "$MEMTEST_MAX_MB" ] && MEMTEST_MB="$MEMTEST_MAX_MB"
[ "$MEMTEST_MB" -lt "$QUICK_MEMTEST_MIN_MB" ] && MEMTEST_MB="$QUICK_MEMTEST_MIN_MB"

log "  Modo RAM    : quick/factory"
log "  MemAvailable: ${MEM_AVAIL_MB}MB"
log "  Testando RAM: ${MEMTEST_MB}MB (${MEMTEST_PERCENT}% da disponível, máx ${MEMTEST_MAX_MB}MB)"
log "  Loops       : ${MEMTEST_LOOPS}"
log "  Timeout     : ${MEMTEST_TIMEOUT_S}s"
log_debug "Motivo da mudança: removido stress paralelo infinito com /dev/urandom para evitar execução por horas."

MEMTESTER_BIN=""
log_debug "Procurando memtester nos caminhos conhecidos."
for candidate in /system/bin/memtester /system/xbin/memtester /vendor/bin/memtester /data/local/tmp/memtester "$WORKDIR/memtester"; do
    log_debug "Testando memtester candidate=$candidate"
    if [ -x "$candidate" ]; then
        MEMTESTER_BIN="$candidate"
        log_debug "memtester encontrado: $MEMTESTER_BIN"
        break
    fi
done

if [ -z "$MEMTESTER_BIN" ]; then
    MT_EXIT="N/A"
    fail "memtester não encontrado — embarque o binário na imagem em /system/bin/memtester ou /vendor/bin/memtester"
    log "  Pulando teste de RAM por falta do memtester."
else
    log_debug "Executando em background: $MEMTESTER_BIN ${MEMTEST_MB}M ${MEMTEST_LOOPS}"
    "$MEMTESTER_BIN" "${MEMTEST_MB}M" "$MEMTEST_LOOPS" > memtester.log 2>&1 &
    MEMTESTER_PID=$!
    MT_EXIT=""
    MT_START=$(date +%s)
    log_debug "MEMTESTER_PID=$MEMTESTER_PID, MT_START=$MT_START"

    while kill -0 "$MEMTESTER_PID" 2>/dev/null; do
        MT_NOW=$(date +%s)
        MT_ELAPSED=$(( MT_NOW - MT_START ))
        log "  memtester em execução... ${MT_ELAPSED}s/${MEMTEST_TIMEOUT_S}s"

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

        sleep 10
    done

    if [ -z "$MT_EXIT" ]; then
        wait "$MEMTESTER_PID"
        MT_EXIT=$?
    fi

    MT_END=$(date +%s)
    MT_DURATION=$(( MT_END - MT_START ))
    log_debug "MT_EXIT=$MT_EXIT, MT_DURATION=${MT_DURATION}s"
    log_file_tail "memtester output" "memtester.log" 120

    if [ "$MT_EXIT" != "0" ]; then
        fail "memtester retornou exit code $MT_EXIT"
    fi

    if grep -qi "FAILURE" memtester.log 2>/dev/null; then
        FAILED_TESTS=$(grep -i "FAILURE" memtester.log | head -5)
        fail "memtester reportou FAILURE:\n$FAILED_TESTS"
    fi

    if [ "$MT_EXIT" = "0" ] && ! grep -qi "FAILURE" memtester.log 2>/dev/null; then
        log "  memtester   : OK (exit $MT_EXIT, duração ${MT_DURATION}s)"
    fi
fi

# =============================================
# 6. ANÁLISE DO DMESG
# =============================================
log_section "[6] Kernel log analysis"

log_debug "Executando dmesg > dmesg.txt"
dmesg > dmesg.txt 2>/dev/null
DMESG_EXIT=$?
log_debug "DMESG_EXIT=$DMESG_EXIT"

if [ ! -s dmesg.txt ]; then
    log "  dmesg       : não disponível sem permissão/root ou sem conteúdo"
else
    log_debug "dmesg.txt gerado. Buscando padrões de erro de hardware."
    DMESG_ERRORS=$(grep -iE \
        "I/O error|ufs error|mmc error|memory corruption|hardware error|ecc error|bad block|uncorrectable|panic" \
        dmesg.txt 2>/dev/null)

    if [ -n "$DMESG_ERRORS" ]; then
        log "  Erros encontrados no dmesg:"
        echo "$DMESG_ERRORS" | head -10 | while read line; do log "    $line"; done
        fail "Erros de hardware detectados no kernel log"
        {
            echo "----- dmesg matched errors full dump -----"
            echo "$DMESG_ERRORS"
            echo "----- end dmesg matched errors -----"
        } >> "$LOGFILE"
    else
        log "  dmesg       : sem erros de hardware"
    fi
fi

# =============================================
# 7. RESULTADO FINAL
# =============================================
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log_section "[7] RESULTADO FINAL"
log "  Serial      : ${SERIAL:-N/A}"
log "  Duração     : ${DURATION}s"
log "  RAM total   : ${MEM_TOTAL_MB}MB"
log "  RAM testada : ${MEMTEST_MB}MB"
log "  Storage     : $TYPE / ${STOR_GB}GB"
log "  Vendor      : $VENDOR"
log "  Model       : $STOR_MODEL"
log "  LifeTimeA   : $LIFE_A"
log "  LifeTimeB   : $LIFE_B"
log "  Pre-EOL     : $PRE_EOL"
log "  Write MB/s  : ${WRITE_MBPS:-N/A}"
log "  Read MB/s   : ${READ_MBPS:-N/A}"
log "  Log file    : $LOGFILE"
if [ "$RESULT" = "FAIL" ]; then
    log "  Falhas:"
    printf "$FAIL_REASONS\n" | while read line; do log "$line"; done
fi
log "  Status      : $RESULT"
log "============================================="

log_debug "Gerando result.txt"
{
    echo "RESULT=$RESULT"
    echo "SERIAL=$SERIAL"
    echo "MODEL=$MODEL_PROP"
    echo "TIMESTAMP=$(date +%Y%m%d_%H%M%S)"
    echo "DURATION_S=$DURATION"
    echo "LOGFILE=$LOGFILE"
    echo "STORAGE_TYPE=$TYPE"
    echo "STORAGE_VENDOR=$VENDOR"
    echo "STORAGE_MODEL=$STOR_MODEL"
    echo "STORAGE_GB=$STOR_GB"
    echo "STORAGE_BLOCK=$STOR_BLOCK"
    echo "CID_PATH=$CID_PATH"
    echo "MMC_DEV_PATH=$MMC_DEV_PATH"
    echo "LIFETIME_A=$LIFE_A"
    echo "LIFETIME_B=$LIFE_B"
    echo "LIFETIME_SOURCE=$LIFE_SOURCE"
    echo "PRE_EOL=$PRE_EOL"
    echo "PRE_EOL_SOURCE=$PRE_EOL_SOURCE"
    echo "RAM_MB=$MEM_TOTAL_MB"
    echo "RAM_AVAILABLE_MB=$MEM_AVAIL_MB"
    echo "RAM_TESTED_MB=$MEMTEST_MB"
    echo "LPDDR_TYPE=$LPDDR_TYPE"
    echo "WRITE_MBPS=${WRITE_MBPS:-N/A}"
    echo "READ_MBPS=${READ_MBPS:-N/A}"
    echo "WRITE_MS=${WRITE_MS:-N/A}"
    echo "READ_MS=${READ_MS:-N/A}"
    echo "DD_WRITE_EXIT=${DD_WRITE_EXIT:-N/A}"
    echo "DD_READ_EXIT=${DD_READ_EXIT:-N/A}"
    echo "MEMTESTER_BIN=${MEMTESTER_BIN:-N/A}"
    echo "MEMTESTER_EXIT=${MT_EXIT:-N/A}"
} > result.txt

log_debug "result.txt gerado em $WORKDIR/result.txt"
log_file_tail "result.txt" "result.txt" 80

if [ "$RESULT" = "PASS" ]; then
    log "✅  DEVICE OK"
    exit 0
else
    log "❌  DEVICE FAILED"
    exit 1
fi
