#!/usr/bin/env bash
# run_full.sh — Factory test info-only (script-only, sem APK).
#
# Coleta info do device + health de storage (life_time, pre_eol) + dmesg.
# NAO faz stress de RAM nem I/O de storage — esses estao em run_deep.sh.
#
# Uso:
#   bash run_full.sh                       # menu interativo de profiles
#   bash run_full.sh T2070.conf            # usa profile especifico
#   bash run_full.sh T2070                 # idem, sem .conf
#   bash run_full.sh /path/to/x.conf       # path absoluto
#
# Sobrescrever threshold via env var (mesmo passando profile):
#   EXPECTED_RAM_GB=8 bash run_full.sh T2070.conf
#
# Variaveis aceitas (definidas pelo profile ou via env):
#   EXPECTED_RAM_GB — valor minimo de RAM esperado (default 4)
#
# Pre-requisitos:
#   - adb no PATH
#   - device userdebug conectado e autorizado (adb devices mostra)
#   - scripts/full_memtest.sh nesta pasta
#   (memtester nao eh necessario pra run_full — so pra run_deep)

PROFILE_ARG="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log automatico
LOG_FILE="$SCRIPT_DIR/run_full_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[LOG] Saida sendo gravada em: $LOG_FILE"

# Git Bash (Windows): nao converter paths Unix automaticamente
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
# Selecao do profile (.conf com thresholds)
# Ordem de resolucao:
#   1) Se PROFILE_ARG foi passado: tenta como path/nome (com ou sem .conf)
#   2) Senao, se rodando interativo: mostra menu pra escolher
#   3) Senao, fallback pra profiles/default.conf
# =====================================================================
PROFILE_DIR="$SCRIPT_DIR/profiles"
PROFILE_USED=""

resolve_profile() {
    # arg: nome ou path; popula PROFILE_USED se achar
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
    # popula array global PROFILES com paths .conf disponiveis (exceto _*)
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
        echo "       Procurei em: $PROFILE_DIR/${PROFILE_ARG}, $PROFILE_DIR/${PROFILE_ARG}.conf, e como path absoluto" >&2
        echo "       Profiles disponiveis:" >&2
        list_available_profiles
        for p in "${PROFILES[@]}"; do echo "         - $(basename "$p")" >&2; done
        exit 1
    fi
elif [ -t 0 ]; then
    # interativo: mostra menu
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
            # destaca os que tem o modelo no nome
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
                # nome do arquivo
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
    # nao-interativo (CI) sem argumento: cai em default.conf
    if [ -f "$PROFILE_DIR/default.conf" ]; then
        PROFILE_USED="$PROFILE_DIR/default.conf"
    fi
fi

if [ -n "$PROFILE_USED" ]; then
    echo "    [INFO] Profile carregado: $(basename "$PROFILE_USED")"
    # shellcheck disable=SC1090
    . "$PROFILE_USED"
fi

SCRIPT_LOCAL="$SCRIPT_DIR/scripts/full_memtest.sh"
[ -f "$SCRIPT_LOCAL" ] || err "scripts/full_memtest.sh nao encontrado."

echo ""
echo "Device     : ${MODEL:-N/A}"
echo "Build type : ${BUILD_TYPE:-N/A}"
echo "Arquitetura: $ABI ($ARCH)"
echo "Modo       : factory info-only (sem memtester, sem stress)"
echo "Script     : $SCRIPT_LOCAL"
echo ""

# Best-effort root escalation (script funciona sem root, mas setenforce 0 e
# dmesg precisam dele pra rodar 100%). Tenta 'su 0' primeiro pois alguns
# devices MTK travam com 'adb root'.
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
    # Plano A: su 0 (mais seguro, nao trava adbd)
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
            echo "    Continuando sem root — alguns passos vao reportar 'skip'."
        fi
    fi
fi

info "3/7" "Criar workdir no device"
adb shell mkdir -p /data/local/tmp/memtest_work || err "Falha ao criar /data/local/tmp/memtest_work no device."

info "4/7" "Push script para /data/local/tmp/memtest_work/"
adb push "$(to_win_path "$SCRIPT_LOCAL")" /data/local/tmp/memtest_work/full_memtest.sh >/dev/null || err "Falha no push do script."
adb shell chmod 755 /data/local/tmp/memtest_work/full_memtest.sh

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

# Monta prefix de env vars pra repassar ao script no device.
# Factory info-only consome apenas EXPECTED_RAM_GB.
ENV_PREFIX=""
for var in EXPECTED_RAM_GB; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        ENV_PREFIX="$ENV_PREFIX $var='$val'"
    fi
done

info "6/7" "Executando teste no device"
echo "    Env extra:${ENV_PREFIX:- (defaults)}"
echo "    ============================================="
adb shell "${ENV_PREFIX} sh /data/local/tmp/memtest_work/full_memtest.sh"
TEST_EXIT=$?
echo "    ============================================="
echo "    Script retornou exit=$TEST_EXIT"

info "7/7" "Coletando logs do device"
SAFE_MODEL=$(echo "${MODEL:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
DEST_DIR="$SCRIPT_DIR/results/${SAFE_MODEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$DEST_DIR"
adb pull /data/local/tmp/memtest_work "$(to_win_path "$DEST_DIR")" >/dev/null 2>&1 || \
    echo "    [AVISO] Nao foi possivel puxar /data/local/tmp/memtest_work (sem dados ou erro de pull)."
echo "    Resultados copiados para: $DEST_DIR"

# Resumo final lendo result.txt se foi puxado
RESULT_FILE=$(find "$DEST_DIR" -name "result.txt" 2>/dev/null | head -n1)
echo ""
if [ -n "$RESULT_FILE" ] && [ -f "$RESULT_FILE" ]; then
    echo "----- result.txt -----"
    cat "$RESULT_FILE"
    echo "----- fim -----"
fi

echo ""
if [ "$TEST_EXIT" = "0" ]; then
    echo "✅ Teste concluido (PASS). Logs em: $DEST_DIR"
else
    echo "❌ Teste FAIL (exit=$TEST_EXIT). Logs em: $DEST_DIR"
fi
exit $TEST_EXIT
