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
# Este script ESCALA privilegios igual ao run_full.sh (adb root +
# setenforce 0) pra prever exatamente o que o teste real vai conseguir.
# Sem isso, o veredicto saia enganoso (dizia NOT READY em devices
# que o teste real roda 100%).

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
# ESCALACAO DE PRIVILEGIOS (mesmo fluxo do run_full.sh)
# Sem isso o pre_check da veredicto enganoso porque mlock, SELinux,
# leitura de /sys/.../health_descriptor, etc dependem de uid root +
# Permissive.
# ============================================================
print_section "PRIVILEGIOS"

INITIAL_UID=$(adb shell id -u 2>/dev/null | tr -d '\r')
[ -z "$INITIAL_UID" ] && INITIAL_UID="?"
print_kv "UID inicial"    "$INITIAL_UID"

IS_ROOT=0
ROOT_METHOD="none"
if [ "$INITIAL_UID" = "0" ]; then
    IS_ROOT=1
    ROOT_METHOD="adbd"
    print_check "$SYM_OK" "root" "adbd ja eh root"
elif [ "$BUILD_TYPE" = "user" ]; then
    print_check "$SYM_FAIL" "adb root" "build 'user' nao permite — precisa AOSP Opcao 3"
    BLOCKERS=$((BLOCKERS+1))
else
    # Plano A: tenta 'su 0' primeiro — nao trava o device como adb root pode
    # travar em alguns MTK. Confirma com 'su 0 id -u' retornando 0.
    SU_UID=$(adb shell "su 0 id -u" 2>/dev/null | tr -d '\r')
    if [ "$SU_UID" = "0" ]; then
        IS_ROOT=1
        ROOT_METHOD="su"
        print_check "$SYM_OK" "root via su" "OK (su 0 funciona — evita adb root que pode travar)"
    else
        # Plano B: adb root tradicional, com retry MTK+Windows
        print_check "$SYM_INF" "su" "indisponivel — caindo no adb root tradicional"
        adb root >/dev/null 2>&1 || true
        sleep 3
        # MTK + Windows: adb root pode quebrar adb-server, restart preventivo
        if ! adb shell true >/dev/null 2>&1; then
            adb kill-server >/dev/null 2>&1 || true
            sleep 1
            adb start-server >/dev/null 2>&1 || true
        fi
        for _ in $(seq 1 10); do
            adb shell true >/dev/null 2>&1 && break
            sleep 2
        done
        if adb shell true >/dev/null 2>&1; then
            NEW_UID=$(adb shell id -u 2>/dev/null | tr -d '\r')
            if [ "$NEW_UID" = "0" ]; then
                IS_ROOT=1
                ROOT_METHOD="adbd"
                print_check "$SYM_OK" "adb root" "OK (adbd agora roda como root)"
            else
                print_check "$SYM_WARN" "adb root" "tentou mas uid ainda $NEW_UID"
                PARTIALS=$((PARTIALS+1))
            fi
        else
            print_check "$SYM_FAIL" "adb root" "ERRO: device nao respondeu apos adb root"
            BLOCKERS=$((BLOCKERS+1))
        fi
    fi
fi

# setenforce 0 — usa su 0 se for o caso, senao adb shell direto
if [ "$IS_ROOT" = "1" ]; then
    if [ "$ROOT_METHOD" = "su" ]; then
        SETENFORCE_CMD='su 0 setenforce 0'
    else
        SETENFORCE_CMD='setenforce 0'
    fi
    if adb shell "$SETENFORCE_CMD" >/dev/null 2>&1; then
        print_check "$SYM_OK" "setenforce 0" "OK — SELinux ja em Permissive p/ probes abaixo"
    else
        print_check "$SYM_INF" "setenforce 0" "falhou (sepolicy estrita) — checks usam estado original"
    fi
else
    print_check "$SYM_INF" "setenforce 0" "pulado (sem root)"
fi

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
print_kv "RLIMIT_MEMLOCK"  "$MLOCK_RAW (KB; valor reportado pelo shell)"

MLOCK_COVERAGE=0
if [ "$IS_ROOT" = "1" ]; then
    # Processo root tem CAP_IPC_LOCK, que faz o kernel ignorar RLIMIT_MEMLOCK.
    # Mesmo que ulimit -l reporte 8 MB, o memtester como root consegue mlock
    # de GBs (confirmado em logs reais com mlock 1574 MB em TL10).
    print_check "$SYM_OK" "Cobertura RAM via memtester" "100% (root bypassa RLIMIT_MEMLOCK via CAP_IPC_LOCK)"
    MLOCK_COVERAGE=100
elif [ "$MLOCK_RAW" = "unlimited" ]; then
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
#
# Usa probe direto dos paths conhecidos (mesma lista do full_memtest.sh)
# em vez de 'find -type f'. Motivo: sysfs nodes podem nao casar com
# -type f em alguns kernels (especialmente UFS health_descriptor), e
# alguns find do toybox pulam paths sob /sys/bus/platform/devices/.
# Probe direto via 'cat' so precisa do path final, e e mais robusto.
# ============================================================
print_section "Storage health"

# Helper: para cada glob, expande no device e retorna o primeiro path
# que existe. Patterns sao expandidos pela shell do device, nao do host.
probe_first_path() {
    adb shell "for p in $*; do [ -e \"\$p\" ] && echo \"\$p\" && break; done" 2>/dev/null | tr -d '\r' | head -n1
}

read_path_value() {
    adb shell "cat '$1' 2>/dev/null" 2>/dev/null | tr -d '\r'
}

# --- life_time ---
# Ordem (igual full_memtest.sh): eMMC arquivo unico, UFS estimation_a/b, MTK /proc/bootdevice
LIFE_PATH=$(probe_first_path \
    "/sys/class/mmc_host/mmc*/mmc*:*/life_time" \
    "/sys/block/mmcblk*/device/life_time")

if [ -n "$LIFE_PATH" ]; then
    LIFE_VAL=$(read_path_value "$LIFE_PATH")
    if [ -n "$LIFE_VAL" ]; then
        print_check "$SYM_OK" "life_time (eMMC unico)" "valor=$LIFE_VAL ($LIFE_PATH)"
    else
        print_check "$SYM_WARN" "life_time (eMMC unico)" "path existe mas leitura vazia ($LIFE_PATH)"
        PARTIALS=$((PARTIALS+1))
    fi
else
    UFS_LIFE_PATH=$(probe_first_path \
        "/sys/devices/platform/soc/*ufs*/health_descriptor/life_time_estimation_a" \
        "/sys/bus/platform/devices/*ufs*/health_descriptor/life_time_estimation_a")
    if [ -n "$UFS_LIFE_PATH" ]; then
        UFS_VAL=$(read_path_value "$UFS_LIFE_PATH")
        if [ -n "$UFS_VAL" ]; then
            print_check "$SYM_OK" "life_time (UFS)" "valor=$UFS_VAL ($UFS_LIFE_PATH)"
        else
            print_check "$SYM_WARN" "life_time (UFS)" "path existe mas leitura vazia"
            PARTIALS=$((PARTIALS+1))
        fi
    else
        MTK_LIFE_PATH=$(probe_first_path \
            "/proc/bootdevice/life_time_est_typ_a" \
            "/proc/bootdevice/lifetimeA")
        if [ -n "$MTK_LIFE_PATH" ]; then
            MTK_VAL=$(read_path_value "$MTK_LIFE_PATH")
            print_check "$SYM_OK" "life_time (MTK /proc/bootdevice)" "valor=${MTK_VAL:-vazio} ($MTK_LIFE_PATH)"
        else
            print_check "$SYM_FAIL" "life_time" "kernel nao expoe em nenhum path conhecido"
            PARTIALS=$((PARTIALS+1))
        fi
    fi
fi

# --- pre_eol_info ---
# Nota: TL10 (SPRD UFS) usa nome 'eol_info' (sem prefixo pre_).
# Outros vendors usam 'pre_eol_info' padrao JEDEC.
PRE_EOL_PATH=$(probe_first_path \
    "/sys/class/mmc_host/mmc*/mmc*:*/pre_eol_info" \
    "/sys/block/mmcblk*/device/pre_eol_info" \
    "/sys/devices/platform/soc/*ufs*/health_descriptor/pre_eol_info" \
    "/sys/devices/platform/soc/*ufs*/health_descriptor/eol_info" \
    "/sys/bus/platform/devices/*ufs*/health_descriptor/pre_eol_info" \
    "/sys/bus/platform/devices/*ufs*/health_descriptor/eol_info" \
    "/proc/bootdevice/pre_eol_info")

if [ -n "$PRE_EOL_PATH" ]; then
    PRE_EOL_VAL=$(read_path_value "$PRE_EOL_PATH")
    if [ -n "$PRE_EOL_VAL" ]; then
        print_check "$SYM_OK" "pre_eol_info" "valor=$PRE_EOL_VAL ($PRE_EOL_PATH)"
    else
        # Alguns chips UFS nao populam esse byte; path existe mas conteudo eh vazio.
        # Coerente com o que o full_memtest mostra como N/A.
        print_check "$SYM_WARN" "pre_eol_info" "path existe mas valor vazio ($PRE_EOL_PATH) — chip nao populou"
        PARTIALS=$((PARTIALS+1))
    fi
else
    print_check "$SYM_FAIL" "pre_eol_info" "kernel nao expoe em nenhum path conhecido"
    PARTIALS=$((PARTIALS+1))
fi

# --- CID (eMMC) ou product_name+manufacturer (UFS) ---
CID_PATH=$(probe_first_path \
    "/sys/class/mmc_host/mmc*/mmc*:*/cid" \
    "/sys/block/mmcblk*/device/cid")

if [ -n "$CID_PATH" ]; then
    CID_VAL=$(read_path_value "$CID_PATH")
    if [ -n "$CID_VAL" ]; then
        print_check "$SYM_OK" "CID (vendor/modelo memoria)" "${CID_VAL}"
    else
        print_check "$SYM_WARN" "CID" "path existe mas leitura vazia"
        PARTIALS=$((PARTIALS+1))
    fi
else
    UFS_PNAME_PATH=$(probe_first_path \
        "/sys/devices/platform/soc/*ufs*/string_descriptors/product_name" \
        "/sys/bus/platform/devices/*ufs*/string_descriptors/product_name")
    UFS_MFR_PATH=$(probe_first_path \
        "/sys/devices/platform/soc/*ufs*/string_descriptors/manufacturer_name" \
        "/sys/bus/platform/devices/*ufs*/string_descriptors/manufacturer_name")

    if [ -n "$UFS_PNAME_PATH" ]; then
        UFS_PNAME_VAL=$(read_path_value "$UFS_PNAME_PATH")
        UFS_MFR_VAL=""
        [ -n "$UFS_MFR_PATH" ] && UFS_MFR_VAL=$(read_path_value "$UFS_MFR_PATH")
        if [ -n "$UFS_PNAME_VAL" ]; then
            if [ -n "$UFS_MFR_VAL" ]; then
                print_check "$SYM_OK" "UFS vendor/modelo" "${UFS_MFR_VAL} / ${UFS_PNAME_VAL}"
            else
                print_check "$SYM_OK" "UFS product_name" "${UFS_PNAME_VAL}"
            fi
        else
            print_check "$SYM_WARN" "UFS product_name" "path existe mas vazio"
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

# adb root status ja foi reportado na secao PRIVILEGIOS no topo

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
