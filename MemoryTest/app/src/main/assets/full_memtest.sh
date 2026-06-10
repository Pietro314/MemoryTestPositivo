#!/system/bin/sh
# ==============================================================
#  ROOT RE-EXEC GUARD (best-effort)
#  Se o script for iniciado pelo APK sem root, tenta elevar via
#  `su 0`. Se nao houver su (caso comum em userdebug stock que
#  apenas roda `adb root` + setenforce 0), continua sem root —
#  passos que precisam de root reportam como skip mas o script
#  nao aborta.
# ==============================================================

ROOT_REEXEC_DONE="${ROOT_REEXEC_DONE:-0}"
CURRENT_UID=$(id -u 2>/dev/null)
[ -z "$CURRENT_UID" ] && CURRENT_UID=$(id 2>/dev/null | sed 's/uid=//;s/(.*//;s/ .*//')

if [ "$CURRENT_UID" != "0" ] && [ "$ROOT_REEXEC_DONE" = "0" ]; then
    echo "[BOOTSTRAP] UID=$CURRENT_UID (nao-root). Tentando elevar via su 0..."

    SELF_PATH="$0"
    if [ ! -f "$SELF_PATH" ]; then
        # fallback se $0 for relativo
        SELF_PATH="/data/user/0/com.factory.memorytest/files/scripts/full_memtest.sh"
    fi

    SU_BIN=""
    for candidate in /system/xbin/su /system/bin/su /sbin/su su; do
        if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
            SU_BIN="$candidate"
            break
        fi
    done

    if [ -n "$SU_BIN" ]; then
        echo "[BOOTSTRAP] su encontrado em $SU_BIN. Reexecutando."
        export ROOT_REEXEC_DONE=1
        exec "$SU_BIN" 0 sh "$SELF_PATH" "$@"
        echo "[BOOTSTRAP][AVISO] exec su retornou inesperadamente. Continuando sem root."
    else
        echo "[BOOTSTRAP] su nao disponivel. Continuando sem root — alguns testes podem reportar skip."
    fi
fi

if [ "$CURRENT_UID" = "0" ]; then
    echo "[BOOTSTRAP] Executando como root: $(id 2>/dev/null)"
else
    echo "[BOOTSTRAP] Executando sem root: $(id 2>/dev/null)"
fi

# ==============================================================
#  FACTORY MEMORY VALIDATION SCRIPT - INFO-ONLY VERSION
#  Objetivo: coletar dados de identificacao do device + health de
#  storage (life_time, pre_eol) + info basica de RAM + dmesg.
#  Alvos: UFS / MMC/eMMC (storage) + RAM (LPDDR)
#
#  Stress real (memtester) e validacao de I/O (dd) sao feitos pelo
#  teste deep, em fase separada. Este script NAO faz stress nem
#  escrita em disco — apenas leitura de sysfs/proc/getprop.
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
# ==============================================================

WORKDIR="/data/data/com.factory.memorytest/files/memtest_work"
RESULT="PASS"
FAIL_REASONS=""
START_TIME=$(date +%s)
RUN_TS=$(date +%Y%m%d_%H%M%S)

# ---------- Thresholds configuráveis por SKU ----------
# Valores lidos do ambiente (definidos pelo memtest_daemon a partir do
# perfil do device cadastrado no APK). Caso nao venham, usa defaults.
EXPECTED_RAM_GB="${EXPECTED_RAM_GB:-4}"
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
    # Terminal vai pro stderr pra nao poluir $(funcao) capturas.
    # Arquivo de log continua recebendo tudo.
    echo "  [DEBUG] $*" >&2
    echo "  [DEBUG] $*" >> "$LOGFILE"
}

log_warn() {
    log "  ⚠️  WARNING: $*"
}

log_file_value() {
    # Uso: log_file_value "Label" "/path/file"
    local label="$1"
    local file="$2"
    local val=""

    if [ -f "$file" ]; then
        val=$(cat "$file" 2>/dev/null)
        log_debug "$label: arquivo encontrado: $file"
        log_debug "$label: valor lido: ${val:-<vazio>}"
        echo "$val"
        return 0
    fi

    log_debug "$label: arquivo não existe: $file"
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
        } | tee -a "$LOGFILE"
    else
        log_debug "$label: arquivo não encontrado para dump: $file"
    fi
}

cleanup() {
    log_blank
    log "[CLEANUP] Removendo arquivos temporários..."
    log_debug "WORKDIR=$WORKDIR"
    rm -f dmesg.txt result.txt.tmp
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
    local f
    local val

    for f in "$@"; do
        log_debug "read_first_file: testando $f"
        if [ -f "$f" ]; then
            val=$(cat "$f" 2>/dev/null)
            log_debug "read_first_file: escolhido $f"
            log_debug "read_first_file: valor='${val:-<vazio>}'"
            echo "$val"
            return 0
        fi
    done

    log_debug "read_first_file: nenhum arquivo encontrado"
    return 1
}

find_first_file() {
    # Procura arquivo por nome em /sys, escondendo Permission denied.
    # Uso: find_first_file life_time
    local name="$1"
    local found
    log_debug "find_first_file: procurando em /sys por name='$name'"
    found=$(find /sys -name "$name" 2>/dev/null | head -n1)
    log_debug "find_first_file: resultado='${found:-<não encontrado>}'"
    echo "$found"
}

log "============================================="
log "  FACTORY MEMORY TEST - $(date)"
log "============================================="
log "  Log file    : $LOGFILE"
log "  Workdir     : $WORKDIR"
log "  Thresholds  : EXPECTED_RAM=${EXPECTED_RAM_GB}GB"
log "  Modo        : info-only (sem stress de RAM ou I/O — deep faz o stress)"

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

log_debug "Iniciando detecção de storage. Ordem: UFS primeiro, depois MMC/eMMC."

# ---------- UFS ----------
log_debug "Procurando UFS health_descriptor em caminhos comuns."
for d in \
    /sys/devices/platform/soc/*ufs*/health_descriptor \
    /sys/bus/platform/devices/*ufs*/health_descriptor
    do
        log_debug "Testando UFS health dir: $d"
        if [ -d "$d" ]; then
            UFS_HEALTH_DIR="$d"
            log_debug "UFS health_descriptor encontrado: $UFS_HEALTH_DIR"
            break
        fi
    done

if [ -z "$UFS_HEALTH_DIR" ]; then
    log_debug "UFS health_descriptor não encontrado nos caminhos comuns. Usando find fallback."
    UFS_HEALTH_DIR=$(find /sys -maxdepth 8 -path "*/health_descriptor" -type d 2>/dev/null | head -n1)
    log_debug "Resultado find UFS_HEALTH_DIR='${UFS_HEALTH_DIR:-<não encontrado>}'"
fi

if [ -n "$UFS_HEALTH_DIR" ] && [ -d "$UFS_HEALTH_DIR" ]; then
    TYPE="UFS"
    UFS_CANDIDATE=$(dirname "$UFS_HEALTH_DIR")
    log_debug "Storage detectado como UFS. Base=$UFS_CANDIDATE"

    LIFE_A=$(cat "$UFS_HEALTH_DIR/life_time_estimation_a" 2>/dev/null)
    LIFE_B=$(cat "$UFS_HEALTH_DIR/life_time_estimation_b" 2>/dev/null)
    PRE_EOL=$(cat "$UFS_HEALTH_DIR/pre_eol_info" 2>/dev/null)
    LIFE_SOURCE="$UFS_HEALTH_DIR/life_time_estimation_a + life_time_estimation_b"
    PRE_EOL_SOURCE="$UFS_HEALTH_DIR/pre_eol_info"

    # Fallback: TL10 (SPRD UFS) usa nome 'eol_info' (sem prefixo pre_)
    if [ -z "$PRE_EOL" ] && [ -f "$UFS_HEALTH_DIR/eol_info" ]; then
        PRE_EOL=$(cat "$UFS_HEALTH_DIR/eol_info" 2>/dev/null)
        PRE_EOL_SOURCE="$UFS_HEALTH_DIR/eol_info"
        log_debug "UFS PRE_EOL via fallback eol_info"
    fi

    log_debug "UFS LIFE_A raw='${LIFE_A:-<vazio>}'"
    log_debug "UFS LIFE_B raw='${LIFE_B:-<vazio>}'"
    log_debug "UFS PRE_EOL raw='${PRE_EOL:-<vazio>}'"

    [ -z "$LIFE_A" ] && LIFE_A="N/A"
    [ -z "$LIFE_B" ] && LIFE_B="N/A"
    [ -z "$PRE_EOL" ] && PRE_EOL="N/A"

    STOR_MODEL=$(cat "$UFS_CANDIDATE/string_descriptors/product_name" 2>/dev/null)
    VENDOR=$(cat "$UFS_CANDIDATE/string_descriptors/manufacturer_name" 2>/dev/null)
    log_debug "UFS product_name='${STOR_MODEL:-<vazio>}'"
    log_debug "UFS manufacturer_name='${VENDOR:-<vazio>}'"
    [ -z "$STOR_MODEL" ] && STOR_MODEL="N/A"
    [ -z "$VENDOR" ] && VENDOR="N/A"
else
    log_debug "UFS não detectado. Continuando para MMC/eMMC."
fi

# ---------- MMC/eMMC ----------
if [ "$TYPE" = "UNKNOWN" ]; then
    log_debug "Procurando CID de MMC/eMMC em /sys/class/mmc_host/mmc*/mmc*:*/cid"
    CID_PATH=$(ls /sys/class/mmc_host/mmc*/mmc*:*/cid 2>/dev/null | head -n1)
    log_debug "CID_PATH após caminho clássico='${CID_PATH:-<não encontrado>}'"

    if [ -z "$CID_PATH" ]; then
        log_debug "CID não encontrado no caminho clássico. Tentando /sys/block/mmcblk*/device/cid"
        CID_PATH=$(ls /sys/block/mmcblk*/device/cid 2>/dev/null | head -n1)
        log_debug "CID_PATH após /sys/block='${CID_PATH:-<não encontrado>}'"
    fi

    if [ -z "$CID_PATH" ]; then
        log_debug "CID ainda não encontrado. Usando find_first_file cid"
        CID_PATH=$(find_first_file cid)
    fi

    if [ -n "$CID_PATH" ] && [ -f "$CID_PATH" ]; then
        TYPE="MMC"
        MMC_DEV_PATH=$(dirname "$CID_PATH")
        CID=$(cat "$CID_PATH" 2>/dev/null)

        log_debug "Storage detectado como MMC/eMMC"
        log_debug "CID_PATH=$CID_PATH"
        log_debug "MMC_DEV_PATH=$MMC_DEV_PATH"
        log_debug "CID='${CID:-<vazio>}'"

        STOR_MODEL=$(read_first_file "$MMC_DEV_PATH/name" /sys/block/mmcblk*/device/name)
        VENDOR_ID=$(read_first_file "$MMC_DEV_PATH/manfid" /sys/block/mmcblk*/device/manfid)
        log_debug "STOR_MODEL inicial via sysfs='${STOR_MODEL:-<vazio>}'"
        log_debug "VENDOR_ID inicial via sysfs='${VENDOR_ID:-<vazio>}'"

        if [ -n "$CID" ]; then
            MID=$(echo "$CID" | cut -c1-2)
            PNM_HEX=$(echo "$CID" | cut -c5-14)
            CID_MODEL=$(printf "$(echo "$PNM_HEX" | sed 's/\(..\)/\\x\1/g')" 2>/dev/null)
            log_debug "CID parse: MID=$MID, PNM_HEX=$PNM_HEX, CID_MODEL='${CID_MODEL:-<vazio>}'"
            [ -z "$STOR_MODEL" ] && STOR_MODEL="$CID_MODEL"
            [ -z "$VENDOR_ID" ] && VENDOR_ID="MID:$MID"
        fi

        [ -z "$STOR_MODEL" ] && STOR_MODEL="N/A"
        [ -z "$VENDOR_ID" ] && VENDOR_ID="N/A"
        VENDOR="$VENDOR_ID"

        log_debug "Tentando Life Time por arquivos separados de vendor."
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

        log_debug "Após arquivos separados: LIFE_A=$LIFE_A, LIFE_B=$LIFE_B, LIFE_SOURCE=$LIFE_SOURCE"

        # Caso 2: padrão comum em kernels Linux/Allwinner:
        # arquivo único life_time, exemplo: "0x04 0x03".
        if [ "$LIFE_A" = "N/A" ] || [ "$LIFE_B" = "N/A" ]; then
            LIFE_RAW=""
            LIFE_TIME_FILE=""

            log_debug "Life Time separado incompleto. Tentando arquivo único life_time."

            if [ -f "$MMC_DEV_PATH/life_time" ]; then
                LIFE_TIME_FILE="$MMC_DEV_PATH/life_time"
                LIFE_RAW=$(cat "$LIFE_TIME_FILE" 2>/dev/null)
                log_debug "life_time encontrado via MMC_DEV_PATH: $LIFE_TIME_FILE"
                log_debug "LIFE_RAW='$LIFE_RAW'"
            fi

            if [ -z "$LIFE_RAW" ]; then
                log_debug "Tentando life_time via /sys/block/mmcblk*/device/life_time"
                for f in /sys/block/mmcblk*/device/life_time; do
                    log_debug "Testando $f"
                    if [ -f "$f" ]; then
                        LIFE_TIME_FILE="$f"
                        LIFE_RAW=$(cat "$f" 2>/dev/null)
                        log_debug "Arquivo life_time escolhido: $f"
                        log_debug "LIFE_RAW='$LIFE_RAW'"
                        [ -n "$LIFE_RAW" ] && break
                    fi
                done
            fi

            if [ -z "$LIFE_RAW" ]; then
                log_debug "Tentando life_time via find_first_file"
                LIFE_TIME_FILE=$(find_first_file life_time)
                if [ -n "$LIFE_TIME_FILE" ] && [ -f "$LIFE_TIME_FILE" ]; then
                    LIFE_RAW=$(cat "$LIFE_TIME_FILE" 2>/dev/null)
                    log_debug "Arquivo life_time escolhido via find: $LIFE_TIME_FILE"
                    log_debug "LIFE_RAW='$LIFE_RAW'"
                fi
            fi

            # MTK: alguns kernels expõem em /proc/bootdevice/
            if [ -z "$LIFE_RAW" ]; then
                LIFE_A_MTK=$(read_first_file \
                    /proc/bootdevice/life_time_est_typ_a \
                    /proc/bootdevice/lifetimeA)
                LIFE_B_MTK=$(read_first_file \
                    /proc/bootdevice/life_time_est_typ_b \
                    /proc/bootdevice/lifetimeB)
                if [ -n "$LIFE_A_MTK" ] || [ -n "$LIFE_B_MTK" ]; then
                    [ -n "$LIFE_A_MTK" ] && LIFE_A="$LIFE_A_MTK"
                    [ -n "$LIFE_B_MTK" ] && LIFE_B="$LIFE_B_MTK"
                    LIFE_SOURCE="/proc/bootdevice/ (MTK)"
                    log_debug "MTK life_time encontrado: A='$LIFE_A_MTK' B='$LIFE_B_MTK'"
                fi
            fi

            if [ -n "$LIFE_RAW" ]; then
                LIFE_A_TMP=$(echo "$LIFE_RAW" | awk '{print $1}')
                LIFE_B_TMP=$(echo "$LIFE_RAW" | awk '{print $2}')

                log_debug "Parse LIFE_RAW: LIFE_A_TMP='$LIFE_A_TMP', LIFE_B_TMP='$LIFE_B_TMP'"

                [ -n "$LIFE_A_TMP" ] && LIFE_A="$LIFE_A_TMP"
                [ -n "$LIFE_B_TMP" ] && LIFE_B="$LIFE_B_TMP"
                LIFE_SOURCE="$LIFE_TIME_FILE"
            else
                log_debug "Nenhum life_time encontrado ou lido. LifeTime permanecerá N/A."
            fi
        fi

        log_debug "Tentando Pre-EOL."
        PRE_EOL=$(read_first_file \
            "$MMC_DEV_PATH/pre_eol_info" \
            /sys/block/mmcblk*/device/pre_eol_info)

        if [ -n "$PRE_EOL" ]; then
            PRE_EOL_SOURCE="$MMC_DEV_PATH/pre_eol_info ou /sys/block/mmcblk*/device/pre_eol_info"
        fi

        if [ -z "$PRE_EOL" ]; then
            log_debug "Pre-EOL não encontrado em caminhos diretos. Usando find_first_file."
            PRE_EOL_FILE=$(find_first_file pre_eol_info)
            if [ -n "$PRE_EOL_FILE" ] && [ -f "$PRE_EOL_FILE" ]; then
                PRE_EOL=$(cat "$PRE_EOL_FILE" 2>/dev/null)
                PRE_EOL_SOURCE="$PRE_EOL_FILE"
                log_debug "PRE_EOL via find: file=$PRE_EOL_FILE, value='$PRE_EOL'"
            fi
        fi

        # MTK fallback pra Pre-EOL
        if [ -z "$PRE_EOL" ]; then
            PRE_EOL_MTK=$(read_first_file \
                /proc/bootdevice/pre_eol_info \
                /proc/bootdevice/preEOL)
            if [ -n "$PRE_EOL_MTK" ]; then
                PRE_EOL="$PRE_EOL_MTK"
                PRE_EOL_SOURCE="/proc/bootdevice/ (MTK)"
                log_debug "MTK pre_eol_info encontrado: '$PRE_EOL'"
            fi
        fi

        [ -z "$LIFE_A" ] && LIFE_A="N/A"
        [ -z "$LIFE_B" ] && LIFE_B="N/A"
        [ -z "$PRE_EOL" ] && PRE_EOL="N/A"
    else
        log_debug "Nenhum CID válido encontrado. Storage permanece TYPE=UNKNOWN."
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
    log_debug "blockdev --getsize64 $STOR_BLOCK => '${STOR_BYTES:-<vazio>}'"
    if [ -n "$STOR_BYTES" ] && [ "$STOR_BYTES" -gt 0 ] 2>/dev/null; then
        # awk pra evitar overflow no mksh 32-bit em chips >= 4GB.
        STOR_GB=$(awk -v b="$STOR_BYTES" 'BEGIN { printf "%d", b/1024/1024/1024 }')
        [ -z "$STOR_GB" ] && STOR_GB="N/A"
    fi
else
    log_debug "STOR_BLOCK não encontrado ou não existe. Pulando blockdev."
fi

if [ "$STOR_GB" = "N/A" ] || [ "$STOR_GB" = "0" ]; then
    log_debug "Capacidade via blockdev indisponível. Usando df /data."
    DF_KB=$(df /data 2>/dev/null | awk 'NR==2{print $2}')
    log_debug "df /data total KB='${DF_KB:-<vazio>}'"
    if [ -n "$DF_KB" ] && [ "$DF_KB" -gt 0 ] 2>/dev/null; then
        # awk pra evitar overflow no mksh 32-bit (DF_KB pode passar de 2^31 em chips > 2TB).
        STOR_GB=$(awk -v k="$DF_KB" 'BEGIN { printf "%d", k/1024/1024 }')
        { [ -z "$STOR_GB" ] || [ "$STOR_GB" = "0" ]; } && STOR_GB=1
    fi
fi

log "  Type        : $TYPE"
log "  Vendor      : $VENDOR"
log "  Model       : $STOR_MODEL"
log "  Capacity    : ${STOR_GB}GB"
log "  Life source : $LIFE_SOURCE"
log "  EOL source  : $PRE_EOL_SOURCE"

lifetime_warn "LifeTimeA" "$LIFE_A"
lifetime_warn "LifeTimeB" "$LIFE_B"

PRE_EOL_DEC=$(to_dec "$PRE_EOL")
log_debug "Pre-EOL: valor bruto='$PRE_EOL', decimal='${PRE_EOL_DEC:-N/A}'"
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
    # MTK: alguns kernels expõem em /proc/bootdevice/
    LPDDR_TYPE=$(read_first_file \
        /proc/bootdevice/dram_type \
        /proc/bootdevice/dramType \
        /proc/lpddr_type)
    log_debug "LPDDR via /proc/bootdevice/='${LPDDR_TYPE:-<vazio>}'"
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
# 4. ANÁLISE DO DMESG
# =============================================
log_section "[4] Kernel log analysis"

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
# 5. RESULTADO FINAL
# =============================================
END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

log_section "[5] RESULTADO FINAL"
log "  Serial      : ${SERIAL:-N/A}"
log "  Duração     : ${DURATION}s"
log "  RAM total   : ${MEM_TOTAL_MB}MB"
log "  Storage     : $TYPE / ${STOR_GB}GB"
log "  Vendor      : $VENDOR"
log "  Model       : $STOR_MODEL"
log "  LifeTimeA   : $LIFE_A"
log "  LifeTimeB   : $LIFE_B"
log "  Pre-EOL     : $PRE_EOL"
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
    echo "LPDDR_TYPE=$LPDDR_TYPE"
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
