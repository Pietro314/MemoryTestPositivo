#!/usr/bin/env bash
# pre_check.sh — avalia o que esse device suporta antes de rodar o teste.
#
# Uso: bash pre_check.sh
#
# Saida:
#   - Terminal (resumo + detalhes + veredicto)
#   - reports/preinfo_<MODELO>_<TIMESTAMP>.txt (arquivo identico)
#
# O veredicto te diz qual dos 2 caminhos seguir:
#   - READY        : roda bash run_full.sh, ScriptOnly resolve 100%
#   - PARTIAL      : roda run_full.sh com cobertura reduzida OU pede AOSP
#   - NOT READY    : pede AOSP Opção 3 antes de testar (script-only nao basta)
#
# Esse script NAO modifica o device. So le info via adb shell.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Git Bash (Windows): nao converter paths Unix automaticamente
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

command -v adb >/dev/null 2>&1 || { echo "[ERRO] adb nao encontrado no PATH" >&2; exit 1; }

echo "[INFO] Procurando device..."
adb wait-for-device

# --- coleta info basica do device ---
MODEL=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')
BRAND=$(adb shell getprop ro.product.brand 2>/dev/null | tr -d '\r')
DEVICE=$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')
BOARD=$(adb shell getprop ro.product.board 2>/dev/null | tr -d '\r')
SOC=$(adb shell getprop ro.soc.manufacturer 2>/dev/null | tr -d '\r')
HARDWARE=$(adb shell getprop ro.hardware 2>/dev/null | tr -d '\r')
ANDROID=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
BUILD_TYPE=$(adb shell getprop ro.build.type 2>/dev/null | tr -d '\r')
DEBUGGABLE=$(adb shell getprop ro.debuggable 2>/dev/null | tr -d '\r')
ABI=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
FINGERPRINT=$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')

# --- prepara arquivo de relatorio ---
SAFE_MODEL=$(echo "${MODEL:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$SCRIPT_DIR/reports"
REPORT_FILE="$SCRIPT_DIR/reports/preinfo_${SAFE_MODEL}_${TIMESTAMP}.txt"

# duplica saida pra terminal + arquivo
exec > >(tee -a "$REPORT_FILE") 2>&1

# --- helpers ---
SYM_OK="[OK]"
SYM_WARN="[!]"
SYM_FAIL="[X]"
SYM_INF="[i]"

print_section() {
    echo ""
    echo "============================================================"
    echo "  $1"
    echo "============================================================"
}

print_kv() {
    printf "  %-22s : %s\n" "$1" "$2"
}

print_check() {
    # print_check SYM "Label" "Detalhe"
    printf "  %-4s %-38s %s\n" "$1" "$2" "$3"
}

# contadores de severidade
BLOCKERS=0       # impedem teste confiavel
PARTIALS=0       # warnings de cobertura reduzida

# ============================================================
# CABEÇALHO
# ============================================================
echo "============================================================"
echo "  MemoryTest Pre-Check Report"
echo "  Gerado: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Arquivo: $REPORT_FILE"
echo "============================================================"

print_section "DEVICE"
print_kv "Modelo"         "${MODEL:-N/A}"
print_kv "Fabricante"     "${BRAND:-N/A}"
print_kv "Device code"    "${DEVICE:-N/A}"
print_kv "Board"          "${BOARD:-N/A}"
print_kv "Hardware"       "${HARDWARE:-N/A}"
print_kv "SoC vendor"     "${SOC:-N/A}"
print_kv "Android"        "${ANDROID:-N/A}"
print_kv "Build type"     "${BUILD_TYPE:-N/A}"
print_kv "Debuggable"     "${DEBUGGABLE:-N/A}"
print_kv "ABI"            "${ABI:-N/A}"
print_kv "Fingerprint"    "${FINGERPRINT:-N/A}"

# ============================================================
# RAM
# ============================================================
print_section "RAM"

MEM_TOTAL_KB=$(adb shell "grep MemTotal /proc/meminfo 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '\r')
MEM_AVAIL_KB=$(adb shell "grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print \$2}'" 2>/dev/null | tr -d '\r')
[ -z "$MEM_TOTAL_KB" ] && MEM_TOTAL_KB=0
[ -z "$MEM_AVAIL_KB" ] && MEM_AVAIL_KB=0
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_TOTAL_GB=$(( (MEM_TOTAL_MB + 1023) / 1024 ))

print_kv "MemTotal"       "${MEM_TOTAL_MB} MB (~${MEM_TOTAL_GB} GB)"
print_kv "MemAvailable"   "${MEM_AVAIL_MB} MB"

# DDR type
DDR_TYPE=$(adb shell "getprop ro.boot.ddr_type" 2>/dev/null | tr -d '\r')
[ -z "$DDR_TYPE" ] && DDR_TYPE=$(adb shell "getprop ro.boot.dram_type" 2>/dev/null | tr -d '\r')
[ -z "$DDR_TYPE" ] && DDR_TYPE=$(adb shell "getprop vendor.boot.ddr_type" 2>/dev/null | tr -d '\r')
print_kv "DDR type"       "${DDR_TYPE:-nao exposto pelo bootloader}"

# ============================================================
# SELinux
# ============================================================
print_section "SELinux"

SELINUX=$(adb shell "getenforce" 2>/dev/null | tr -d '\r')
print_kv "Estado"         "${SELINUX:-N/A}"
if [ "$SELINUX" = "Enforcing" ]; then
    print_check "$SYM_WARN" "SELinux Enforcing" "pode bloquear leitura de /sys/* via app comum"
elif [ "$SELINUX" = "Permissive" ]; then
    print_check "$SYM_OK" "SELinux Permissive" "leituras de /sys/* nao sao bloqueadas"
else
    print_check "$SYM_INF" "SELinux state" "indeterminado"
fi

# ============================================================
# mlock - capacidade real de teste de RAM
# ============================================================
print_section "mlock — cobertura efetiva do teste de RAM"

MLOCK_RAW=$(adb shell "ulimit -l" 2>/dev/null | tr -d '\r')
print_kv "RLIMIT_MEMLOCK"  "$MLOCK_RAW (KB; valor que o memtester pode travar)"

MLOCK_COVERAGE=0
if [ "$MLOCK_RAW" = "unlimited" ]; then
    print_check "$SYM_OK" "Cobertura RAM via memtester" "100% (mlock unlimited)"
    MLOCK_COVERAGE=100
elif [ -n "$MLOCK_RAW" ] && [ "$MLOCK_RAW" -gt 0 ] 2>/dev/null; then
    MLOCK_MB=$(( MLOCK_RAW / 1024 ))
    if [ "$MEM_TOTAL_MB" -gt 0 ]; then
        MLOCK_COVERAGE=$(( MLOCK_MB * 100 / MEM_TOTAL_MB ))
    fi
    DETAIL="${MLOCK_MB} MB de ${MEM_TOTAL_MB} MB total = ${MLOCK_COVERAGE}%"
    if [ "$MLOCK_COVERAGE" -ge 75 ]; then
        print_check "$SYM_OK"   "Cobertura RAM via memtester" "$DETAIL"
    elif [ "$MLOCK_COVERAGE" -ge 25 ]; then
        print_check "$SYM_WARN" "Cobertura RAM via memtester" "$DETAIL — parcial"
        PARTIALS=$((PARTIALS+1))
    else
        print_check "$SYM_FAIL" "Cobertura RAM via memtester" "$DETAIL — insuficiente"
        BLOCKERS=$((BLOCKERS+1))
    fi
else
    print_check "$SYM_FAIL" "RLIMIT_MEMLOCK"     "nao foi possivel detectar"
    BLOCKERS=$((BLOCKERS+1))
fi

# ============================================================
# Storage health (life_time / pre_eol_info / CID / UFS)
# ============================================================
print_section "Storage health"

# life_time (eMMC formato Allwinner-style ou separado)
LIFE_TIME_PATH=$(adb shell "find /sys -name life_time -type f 2>/dev/null | head -n1" 2>/dev/null | tr -d '\r')
if [ -n "$LIFE_TIME_PATH" ]; then
    LIFE_VAL=$(adb shell "cat '$LIFE_TIME_PATH' 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ -n "$LIFE_VAL" ]; then
        print_check "$SYM_OK" "life_time (eMMC)" "valor=$LIFE_VAL ($LIFE_TIME_PATH)"
    else
        print_check "$SYM_WARN" "life_time (eMMC)" "arquivo existe mas leitura vazia (provavel SELinux)"
        PARTIALS=$((PARTIALS+1))
    fi
else
    # tenta UFS
    UFS_LIFE=$(adb shell "find /sys -name 'life_time_estimation_*' -type f 2>/dev/null | head -n1" 2>/dev/null | tr -d '\r')
    if [ -n "$UFS_LIFE" ]; then
        UFS_VAL=$(adb shell "cat '$UFS_LIFE' 2>/dev/null" 2>/dev/null | tr -d '\r')
        if [ -n "$UFS_VAL" ]; then
            print_check "$SYM_OK" "life_time (UFS)" "valor=$UFS_VAL"
        else
            print_check "$SYM_WARN" "life_time (UFS)" "arquivo existe mas leitura vazia"
            PARTIALS=$((PARTIALS+1))
        fi
    else
        print_check "$SYM_FAIL" "life_time" "kernel nao expoe — saude da memoria nao detectavel"
        PARTIALS=$((PARTIALS+1))
    fi
fi

# pre_eol_info
PRE_EOL_PATH=$(adb shell "find /sys -name pre_eol_info -type f 2>/dev/null | head -n1" 2>/dev/null | tr -d '\r')
if [ -n "$PRE_EOL_PATH" ]; then
    PRE_EOL_VAL=$(adb shell "cat '$PRE_EOL_PATH' 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ -n "$PRE_EOL_VAL" ]; then
        print_check "$SYM_OK" "pre_eol_info" "valor=$PRE_EOL_VAL"
    else
        print_check "$SYM_WARN" "pre_eol_info" "arquivo existe mas leitura vazia"
        PARTIALS=$((PARTIALS+1))
    fi
else
    print_check "$SYM_FAIL" "pre_eol_info" "kernel nao expoe"
    PARTIALS=$((PARTIALS+1))
fi

# CID (eMMC) ou product_name (UFS) - identifica vendor/modelo
CID_PATH=$(adb shell "find /sys -name cid -type f 2>/dev/null | head -n1" 2>/dev/null | tr -d '\r')
if [ -n "$CID_PATH" ]; then
    CID_VAL=$(adb shell "cat '$CID_PATH' 2>/dev/null" 2>/dev/null | tr -d '\r')
    if [ -n "$CID_VAL" ]; then
        print_check "$SYM_OK" "CID (vendor/modelo memoria)" "${CID_VAL}"
    else
        print_check "$SYM_WARN" "CID" "arquivo existe mas leitura vazia"
        PARTIALS=$((PARTIALS+1))
    fi
else
    UFS_PNAME=$(adb shell "find /sys -name product_name -path '*string_descriptor*' 2>/dev/null | head -n1" 2>/dev/null | tr -d '\r')
    if [ -n "$UFS_PNAME" ]; then
        UFS_PNAME_VAL=$(adb shell "cat '$UFS_PNAME' 2>/dev/null" 2>/dev/null | tr -d '\r')
        if [ -n "$UFS_PNAME_VAL" ]; then
            print_check "$SYM_OK" "UFS product_name" "${UFS_PNAME_VAL}"
        else
            print_check "$SYM_WARN" "UFS product_name" "arquivo existe mas leitura vazia"
            PARTIALS=$((PARTIALS+1))
        fi
    else
        print_check "$SYM_FAIL" "Vendor/modelo memoria" "kernel nao expoe (storage info ficara UNKNOWN)"
        PARTIALS=$((PARTIALS+1))
    fi
fi

# espaco livre /data
STOR_FREE_KB=$(adb shell "df /data 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null | tr -d '\r')
[ -z "$STOR_FREE_KB" ] && STOR_FREE_KB=0
STOR_FREE_MB=$(( STOR_FREE_KB / 1024 ))
print_kv "Free space /data" "${STOR_FREE_MB} MB"

# ============================================================
# memtester - pre-instalado e binario do pacote
# ============================================================
print_section "memtester"

PRE_INSTALLED=""
for path in /system/bin/memtester /system/xbin/memtester /vendor/bin/memtester; do
    EXISTS=$(adb shell "[ -x '$path' ] && echo yes" 2>/dev/null | tr -d '\r')
    if [ "$EXISTS" = "yes" ]; then
        PRE_INSTALLED="$path"
        break
    fi
done
if [ -n "$PRE_INSTALLED" ]; then
    print_check "$SYM_OK" "memtester pre-instalado no device" "$PRE_INSTALLED — AOSP integration ja feita"
else
    print_check "$SYM_INF" "memtester pre-instalado no device" "NAO — vai usar o binario pushado pelos run_*.sh"
fi

# checa binario do pacote bate com a ABI
case "$ABI" in
    arm64-v8a)            EXPECTED_ARCH="arm64" ;;
    armeabi-v7a|armeabi)  EXPECTED_ARCH="arm32" ;;
    x86_64)               EXPECTED_ARCH="x86_64" ;;
    x86)                  EXPECTED_ARCH="x86" ;;
    *)                    EXPECTED_ARCH="" ;;
esac

if [ -n "$EXPECTED_ARCH" ]; then
    BIN_FILE=""
    if [ -f "$SCRIPT_DIR/memtester-${EXPECTED_ARCH}" ]; then
        BIN_FILE="memtester-${EXPECTED_ARCH}"
    elif [ -f "$SCRIPT_DIR/memtester" ]; then
        BIN_FILE="memtester"
    fi
    if [ -n "$BIN_FILE" ]; then
        # confirma arch via 'file' se disponivel
        if command -v file >/dev/null 2>&1; then
            BIN_INFO=$(file -b "$SCRIPT_DIR/$BIN_FILE" 2>/dev/null)
            print_check "$SYM_OK" "Binario do pacote para $EXPECTED_ARCH" "$BIN_FILE"
            print_kv "  Detalhes binario"  "${BIN_INFO:0:90}"
        else
            print_check "$SYM_OK" "Binario do pacote para $EXPECTED_ARCH" "$BIN_FILE"
        fi
    else
        print_check "$SYM_FAIL" "Binario do pacote para $EXPECTED_ARCH" "AUSENTE — adicione memtester-${EXPECTED_ARCH} ao pacote"
        BLOCKERS=$((BLOCKERS+1))
    fi
fi

# ============================================================
# Permissoes auxiliares (cosmeticas)
# ============================================================
print_section "Permissoes auxiliares"

DROP_CACHES_W=$(adb shell "[ -w /proc/sys/vm/drop_caches ] && echo writable || echo readonly" 2>/dev/null | tr -d '\r')
if [ "$DROP_CACHES_W" = "writable" ]; then
    print_check "$SYM_OK" "drop_caches" "writable — cache pode ser limpo antes do teste"
else
    print_check "$SYM_INF" "drop_caches" "readonly (sem root) — apenas otimizacao cosmetica"
fi

DMESG_OUT=$(adb shell "dmesg 2>&1 | head -1" 2>/dev/null | tr -d '\r')
if echo "$DMESG_OUT" | grep -qE 'denied|permission|operation not permitted' 2>/dev/null; then
    print_check "$SYM_WARN" "dmesg" "bloqueado/restrito (analise de erros kernel limitada — cosmetica)"
elif [ -n "$DMESG_OUT" ]; then
    print_check "$SYM_OK" "dmesg" "acessivel (analise de erros kernel funciona)"
else
    print_check "$SYM_INF" "dmesg" "saida vazia/desconhecida"
fi

if [ "$BUILD_TYPE" = "userdebug" ] || [ "$BUILD_TYPE" = "eng" ]; then
    print_check "$SYM_INF" "adb root" "build $BUILD_TYPE (provavelmente disponivel — NAO testado, alguns devices MTK quebram)"
else
    print_check "$SYM_WARN" "adb root" "build user — adb root nao disponivel"
fi

# ============================================================
# VEREDICTO
# ============================================================
print_section "VEREDICTO"

if [ "$BLOCKERS" -eq 0 ] && [ "$PARTIALS" -eq 0 ]; then
    STATUS="READY"
    STATUS_DESC="Pode rodar bash run_full.sh com confianca total — ScriptOnly cobre 100%."
elif [ "$BLOCKERS" -eq 0 ]; then
    STATUS="PARTIAL"
    STATUS_DESC="ScriptOnly funciona, mas com cobertura reduzida (ver warnings acima)."
else
    STATUS="NOT READY"
    STATUS_DESC="ScriptOnly tem bloqueios criticos. Recomenda-se AOSP Opcao 3 antes de testar."
fi

echo ""
echo "  STATUS: $STATUS"
echo ""
echo "  $STATUS_DESC"
echo ""
echo "  Resumo:"
echo "    - Bloqueios graves     : $BLOCKERS"
echo "    - Limitacoes parciais  : $PARTIALS"
echo "    - Cobertura RAM (mlock): ${MLOCK_COVERAGE}%"
echo ""

case "$STATUS" in
    "READY")
        echo "  Proximo passo: rodar bash run_full.sh com um dos profiles abaixo."
        ;;
    "PARTIAL")
        echo "  2 caminhos possiveis:"
        echo ""
        echo "    A) Aceitar a cobertura parcial:"
        echo "         rodar bash run_full.sh com um dos profiles abaixo"
        echo "         (storage e parte da RAM serao validados — ver warnings acima"
        echo "          pra entender o que NAO sera testado)"
        echo ""
        echo "    B) Pedir AOSP Opcao 3 pra cobertura 100%:"
        echo "         replicar o setup do TL10 — ver README secao 'AOSP Opcao 3'."
        ;;
    "NOT READY")
        echo "  Acao necessaria:"
        echo "    Pedir time AOSP integrar a Opcao 3 nesse device antes de testar."
        echo "    Ver README do pacote secao 'AOSP Opcao 3'."
        ;;
esac

# Lista profiles disponiveis e destaca os que dao match com o modelo
PROFILE_DIR="$SCRIPT_DIR/profiles"
if [ -d "$PROFILE_DIR" ]; then
    echo ""
    echo "  ----- Profiles disponiveis em profiles/ -----"
    MATCH_FOUND=0
    OTHER_FOUND=0
    for conf in "$PROFILE_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf")
        case "$name" in
            _*) continue ;;
        esac
        if [ -n "$MODEL" ] && echo "$name" | grep -qi "$MODEL"; then
            echo "    > $name      (match com o device)"
            MATCH_FOUND=1
        fi
    done
    for conf in "$PROFILE_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        name=$(basename "$conf")
        case "$name" in
            _*) continue ;;
        esac
        if [ -z "$MODEL" ] || ! echo "$name" | grep -qi "$MODEL"; then
            echo "      $name"
            OTHER_FOUND=1
        fi
    done

    if [ "$MATCH_FOUND" -eq 0 ]; then
        echo ""
        echo "  Nenhum profile bate diretamente com o modelo '$MODEL'."
        echo "  Voce pode:"
        echo "    1) Criar um profile pra esse device:"
        echo "         cp profiles/_template.conf profiles/${MODEL:-NOVO}.conf"
        echo "         (e ajustar os thresholds conforme spec)"
        echo "    2) Rodar com profiles/default.conf (thresholds genericos)"
    fi

    echo ""
    echo "  Comandos de exemplo:"
    if [ "$MATCH_FOUND" -eq 1 ]; then
        # pega primeiro match pra exemplificar
        for conf in "$PROFILE_DIR"/*.conf; do
            name=$(basename "$conf")
            case "$name" in _*) continue ;; esac
            if [ -n "$MODEL" ] && echo "$name" | grep -qi "$MODEL"; then
                echo "    bash run_full.sh $name"
                echo "    bash run_deep.sh $name"
                break
            fi
        done
    else
        echo "    bash run_full.sh default.conf"
        echo "    bash run_deep.sh default.conf"
    fi
    echo ""
    echo "  Ou rode sem argumento pra ver menu interativo:"
    echo "    bash run_full.sh"
fi

echo ""
echo "============================================================"
echo "  Relatorio salvo: $REPORT_FILE"
echo "============================================================"
