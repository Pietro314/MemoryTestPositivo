#!/usr/bin/env bash
# run_deep.sh — Diagnostico profundo de RAM (script-only, sem APK).
#
# Mais pesado que run_full.sh: roda memtester por mais tempo e com mais loops.
# Use em bancada/diagnostico, nao em linha de producao.
#
# Uso:
#   bash run_deep.sh                       # menu interativo de profiles
#   bash run_deep.sh T2070.conf            # usa profile especifico
#   bash run_deep.sh T2070                 # idem, sem .conf
#
# Sobrescrever parametros individuais via env var:
#   MEMTEST_LOOPS=5 bash run_deep.sh T2070.conf
#
# Variaveis aceitas (definidas pelo profile ou via env):
#   MEMTEST_PERCENT, MEMTEST_MAX_MB, MEMTEST_LOOPS, MEMTEST_TIMEOUT_S,
#   MIN_MEMTEST_MB, EXPECTED_RAM_GB

PROFILE_ARG="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG_FILE="$SCRIPT_DIR/run_deep_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[LOG] Saida sendo gravada em: $LOG_FILE"

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

to_win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

err()  { echo "[ERRO] $*" >&2; exit 1; }
info() { echo "[$1] $2"; }

command -v adb >/dev/null 2>&1 || err "adb nao encontrado no PATH."

info "1/7" "Procurando device..."
adb wait-for-device

BUILD_TYPE=$(adb shell getprop ro.build.type 2>/dev/null | tr -d '\r')
ABI=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
MODEL=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')

case "$ABI" in
    arm64-v8a)            ARCH="arm64" ;;
    armeabi-v7a|armeabi)  ARCH="arm32" ;;
    x86_64)               ARCH="x86_64" ;;
    x86)                  ARCH="x86" ;;
    *) err "ABI desconhecida: '$ABI' (suportado: arm64-v8a, armeabi-v7a, x86_64, x86)" ;;
esac

# =====================================================================
# Selecao do profile (.conf com thresholds) — mesma logica do run_full.sh
# =====================================================================
PROFILE_DIR="$SCRIPT_DIR/profiles"
PROFILE_USED=""

resolve_profile() {
    local arg="$1"
    [ -z "$arg" ] && return 1
    if [ -f "$arg" ]; then
        PROFILE_USED="$arg"; return 0
    fi
    if [ -f "$PROFILE_DIR/$arg" ]; then
        PROFILE_USED="$PROFILE_DIR/$arg"; return 0
    fi
    if [ -f "$PROFILE_DIR/${arg}.conf" ]; then
        PROFILE_USED="$PROFILE_DIR/${arg}.conf"; return 0
    fi
    return 1
}

list_available_profiles() {
    PROFILES=()
    if [ ! -d "$PROFILE_DIR" ]; then return; fi
    for conf in "$PROFILE_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        case "$(basename "$conf")" in
            _*) continue ;;
        esac
        PROFILES+=("$conf")
    done
}

if [ -n "$PROFILE_ARG" ]; then
    if ! resolve_profile "$PROFILE_ARG"; then
        echo "[ERRO] Profile nao encontrado: '$PROFILE_ARG'" >&2
        echo "       Profiles disponiveis:" >&2
        list_available_profiles
        for p in "${PROFILES[@]}"; do echo "         - $(basename "$p")" >&2; done
        exit 1
    fi
elif [ -t 0 ]; then
    list_available_profiles
    if [ ${#PROFILES[@]} -eq 0 ]; then
        echo "    [AVISO] Pasta profiles/ vazia. Usando defaults hardcoded do script."
    else
        echo ""
        echo "============================================================"
        echo "  Selecione o profile (thresholds) para esse run"
        echo "  Device detectado: ${MODEL:-N/A} ($ABI)"
        echo "============================================================"
        i=1
        for p in "${PROFILES[@]}"; do
            name=$(basename "$p")
            mark=""
            if [ -n "$MODEL" ] && echo "$name" | grep -qi "$MODEL"; then
                mark=" <-- match com o device"
            fi
            printf "  [%d] %s%s\n" "$i" "$name" "$mark"
            i=$((i+1))
        done
        echo ""
        printf "  Escolha [1-%d, ou nome do arquivo]: " "${#PROFILES[@]}"
        read -r choice
        case "$choice" in
            ''|*[!0-9]*)
                if ! resolve_profile "$choice"; then
                    err "Profile invalido: '$choice'"
                fi
                ;;
            *)
                idx=$((choice - 1))
                if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#PROFILES[@]}" ]; then
                    err "Numero fora da faixa: $choice"
                fi
                PROFILE_USED="${PROFILES[$idx]}"
                ;;
        esac
    fi
else
    if [ -f "$PROFILE_DIR/default.conf" ]; then
        PROFILE_USED="$PROFILE_DIR/default.conf"
    fi
fi

if [ -n "$PROFILE_USED" ]; then
    echo "    [INFO] Profile carregado: $(basename "$PROFILE_USED")"
    # shellcheck disable=SC1090
    . "$PROFILE_USED"
fi

if [ -f "$SCRIPT_DIR/memtester-${ARCH}" ]; then
    MEMTESTER="$SCRIPT_DIR/memtester-${ARCH}"
elif [ -f "$SCRIPT_DIR/memtester" ]; then
    MEMTESTER="$SCRIPT_DIR/memtester"
else
    err "memtester nao encontrado nesta pasta (esperado memtester-${ARCH} ou memtester)"
fi

if command -v file >/dev/null 2>&1; then
    BIN_INFO=$(file -b "$MEMTESTER" 2>/dev/null)
    case "$BIN_INFO" in
        *aarch64*) BIN_ARCH="arm64" ;;
        *ARM*)     BIN_ARCH="arm32" ;;
        *x86-64*)  BIN_ARCH="x86_64" ;;
        *)         BIN_ARCH="" ;;
    esac
    if [ -n "$BIN_ARCH" ] && [ "$BIN_ARCH" != "$ARCH" ]; then
        err "memtester eh $BIN_ARCH mas device eh $ARCH ($ABI). Coloque memtester-${ARCH} na pasta."
    fi
fi

SCRIPT_LOCAL="$SCRIPT_DIR/scripts/ram_deep.sh"
[ -f "$SCRIPT_LOCAL" ] || err "scripts/ram_deep.sh nao encontrado."

echo ""
echo "Device     : ${MODEL:-N/A}"
echo "Build type : ${BUILD_TYPE:-N/A}"
echo "Arquitetura: $ABI ($ARCH)"
echo "memtester  : $MEMTESTER"
echo "Script     : $SCRIPT_LOCAL"
echo ""

info "2/7" "Escalar privilegios (best-effort)"
CURRENT_UID=$(adb shell id -u 2>/dev/null | tr -d '\r')
IS_ROOT=0
ROOT_METHOD="none"
if [ "$CURRENT_UID" = "0" ]; then
    echo "    adbd ja eh root."
    IS_ROOT=1
    ROOT_METHOD="adbd"
elif [ "$BUILD_TYPE" = "user" ]; then
    echo "    Build user, root nao suportado. Continuando sem root."
else
    # Plano A: su 0 (mais seguro, nao trava adbd em MTK)
    SU_UID=$(adb shell "su 0 id -u" 2>/dev/null | tr -d '\r')
    if [ "$SU_UID" = "0" ]; then
        IS_ROOT=1
        ROOT_METHOD="su"
        echo "    su 0 funciona — vamos usar (evita adb root que pode travar device)."
    else
        # Plano B: adb root tradicional, com retry MTK+Windows
        echo "    su indisponivel — tentando adb root tradicional."
        adb root >/dev/null 2>&1 || true
        sleep 3
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
            fi
        else
            echo "    [AVISO] device nao respondeu apos 'adb root'. Tente reconectar USB."
            echo "    Continuando sem root."
        fi
    fi
fi

info "3/7" "Push memtester para /data/local/tmp/"
adb shell mkdir -p /data/local/tmp/memtest_work || err "Falha ao criar workdir no device."
adb push "$(to_win_path "$MEMTESTER")" /data/local/tmp/memtester >/dev/null || err "Falha no push do memtester."
adb shell chmod 755 /data/local/tmp/memtester

info "4/7" "Push script para /data/local/tmp/memtest_work/"
adb push "$(to_win_path "$SCRIPT_LOCAL")" /data/local/tmp/memtest_work/ram_deep.sh >/dev/null || err "Falha no push do script."
adb shell chmod 755 /data/local/tmp/memtest_work/ram_deep.sh

info "5/7" "setenforce 0 (best-effort)"
if [ "$IS_ROOT" = "1" ]; then
    if [ "$ROOT_METHOD" = "su" ]; then
        adb shell "su 0 setenforce 0" 2>/dev/null || echo "    setenforce 0 (via su) falhou."
    else
        adb shell setenforce 0 2>/dev/null || echo "    setenforce 0 falhou (sepolicy estrita)."
    fi
else
    echo "    Pulado (sem root)."
fi

ENV_PREFIX=""
for var in MEMTEST_PERCENT MEMTEST_MAX_MB MEMTEST_LOOPS MEMTEST_TIMEOUT_S \
           MIN_MEMTEST_MB EXPECTED_RAM_GB; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        ENV_PREFIX="$ENV_PREFIX $var='$val'"
    fi
done

info "6/7" "Executando diagnostico no device (pode demorar minutos)"
echo "    Env extra:${ENV_PREFIX:- (defaults)}"
echo "    ============================================="
adb shell "${ENV_PREFIX} sh /data/local/tmp/memtest_work/ram_deep.sh"
TEST_EXIT=$?
echo "    ============================================="
echo "    Script retornou exit=$TEST_EXIT"

info "7/7" "Coletando logs do device"
SAFE_MODEL=$(echo "${MODEL:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
DEST_DIR="$SCRIPT_DIR/results/${SAFE_MODEL}_deep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$DEST_DIR"
adb pull /data/local/tmp/memtest_work "$(to_win_path "$DEST_DIR")" >/dev/null 2>&1 || \
    echo "    [AVISO] Nao foi possivel puxar /data/local/tmp/memtest_work."
echo "    Resultados copiados para: $DEST_DIR"

RESULT_FILE=$(find "$DEST_DIR" -name "ram_deep_result.txt" 2>/dev/null | head -n1)
echo ""
if [ -n "$RESULT_FILE" ] && [ -f "$RESULT_FILE" ]; then
    echo "----- ram_deep_result.txt -----"
    cat "$RESULT_FILE"
    echo "----- fim -----"
fi

echo ""
if [ "$TEST_EXIT" = "0" ]; then
    echo "✅ Diagnostico concluido (PASS). Logs em: $DEST_DIR"
else
    echo "❌ Diagnostico FAIL (exit=$TEST_EXIT). Logs em: $DEST_DIR"
fi
exit $TEST_EXIT
