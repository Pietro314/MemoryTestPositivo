#!/usr/bin/env bash
# qa_setup.sh — prepara um device userdebug pra rodar o APK MemoryTest.
#
# Uso (com APK e memtester na mesma pasta deste script):
#   ./qa_setup.sh
#
# Uso (caminhos customizados):
#   ./qa_setup.sh /caminho/app.apk /caminho/memtester
#
# Pre-requisitos:
#   - Device userdebug (adb root tem que funcionar)
#   - adb instalado e no PATH
#   - Arquivos esperados na pasta deste script (ou passados como argumento):
#       app-release.apk
#       memtester-arm64   (e/ou memtester-arm32 pra devices arm32 antigos)

set -e

# Localiza a pasta deste script (funciona mesmo se chamado por path absoluto)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log automatico — toda saida vai pra arquivo na pasta do script
LOG_FILE="$SCRIPT_DIR/qa_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[LOG] Saida sendo gravada em: $LOG_FILE"

# Git Bash (Windows): MSYS converte automaticamente paths que parecem Unix
# (ex: /data/local/tmp) pra Windows (ex: C:/Program Files/Git/data/local/tmp).
# Isso quebra o destino do `adb push` (que eh path do device, nao do host).
# Desligamos a conversao globalmente e convertemos paths do HOST explicitamente
# via to_win_path() onde precisar. Em Linux/Mac as variaveis sao no-op.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

to_win_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "$1"
    fi
}

APK_ARG="${1:-}"
MEMTESTER_ARG="${2:-}"

PKG="com.factory.memorytest"

err()  { echo "[ERRO] $*" >&2; exit 1; }
info() { echo "[$1/$STEPS] $2"; }

# Sanity: adb existe?
command -v adb >/dev/null 2>&1 || err "adb não encontrado no PATH. Instale o Android platform-tools."

# Sanity: device conectado?
echo "[0/6] Procurando device..."
adb wait-for-device

# Sanity: userdebug?
BUILD_TYPE=$(adb shell getprop ro.build.type 2>/dev/null | tr -d '\r')
case "$BUILD_TYPE" in
    userdebug|eng) ;;
    *) err "Build não é userdebug/eng (encontrado: '$BUILD_TYPE'). adb root não vai funcionar." ;;
esac

# Detecta arquitetura do device
ABI=$(adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
case "$ABI" in
    arm64-v8a)            ARCH="arm64" ;;
    armeabi-v7a|armeabi)  ARCH="arm32" ;;
    x86_64)               ARCH="x86_64" ;;
    x86)                  ARCH="x86" ;;
    *) err "ABI desconhecida do device: '$ABI'. Suportado: arm64-v8a, armeabi-v7a." ;;
esac

# Resolve path do APK: arg explicito > app-release.apk > unico .apk na pasta
if [ -n "$APK_ARG" ]; then
    APK="$APK_ARG"
elif [ -f "$SCRIPT_DIR/app-release.apk" ]; then
    APK="$SCRIPT_DIR/app-release.apk"
else
    apk_count=$(ls "$SCRIPT_DIR"/*.apk 2>/dev/null | wc -l | tr -d ' ')
    if [ "$apk_count" = "1" ]; then
        APK=$(ls "$SCRIPT_DIR"/*.apk)
    elif [ "$apk_count" = "0" ]; then
        err "Nenhum .apk encontrado em $SCRIPT_DIR"
    else
        err "Multiplos .apk em $SCRIPT_DIR — passa o caminho como 1o argumento"
    fi
fi

# Resolve path do memtester: arg explicito > memtester-<arch> > memtester
if [ -n "$MEMTESTER_ARG" ]; then
    MEMTESTER="$MEMTESTER_ARG"
elif [ -f "$SCRIPT_DIR/memtester-${ARCH}" ]; then
    MEMTESTER="$SCRIPT_DIR/memtester-${ARCH}"
elif [ -f "$SCRIPT_DIR/memtester" ]; then
    MEMTESTER="$SCRIPT_DIR/memtester"
else
    err "memtester nao encontrado (esperado memtester-${ARCH} ou memtester em $SCRIPT_DIR)"
fi

[ -f "$APK" ]       || err "APK nao acessivel: $APK"
[ -f "$MEMTESTER" ] || err "memtester nao acessivel: $MEMTESTER"

# Detecta arquitetura do binario memtester e compara com a do device — evita
# "exec format error" silencioso quando o APK tentar executar mais tarde.
if command -v file >/dev/null 2>&1; then
    MEMTESTER_INFO=$(file -b "$MEMTESTER" 2>/dev/null)
    case "$MEMTESTER_INFO" in
        *aarch64*) MEMTESTER_ARCH="arm64" ;;
        *ARM*)     MEMTESTER_ARCH="arm32" ;;
        *x86-64*)  MEMTESTER_ARCH="x86_64" ;;
        *)         MEMTESTER_ARCH="" ;;
    esac
    if [ -n "$MEMTESTER_ARCH" ] && [ "$MEMTESTER_ARCH" != "$ARCH" ]; then
        err "Binario memtester eh $MEMTESTER_ARCH mas device eh $ARCH ($ABI). Coloque um memtester-${ARCH} na pasta do script."
    fi
fi

STEPS=6

echo ""
echo "Device     : $(adb shell getprop ro.product.model | tr -d '\r')"
echo "Build type : $BUILD_TYPE"
echo "Arquitetura: $ABI ($ARCH)"
echo "APK        : $APK"
echo "memtester  : $MEMTESTER"
echo ""

info 1 "adb root"
# adb root e PULADO por padrao porque em alguns devices (notavelmente MediaTek
# + Windows, ex: Positivo L400, MT8766B) ele quebra a conexao USB e o adb-server
# perde o device de vez, fazendo todos os passos seguintes (push, install)
# falharem com 'no devices/emulators found'. Como o APK platform-signed ja tem
# permissoes altas e o memtester roda como uid shell sem problema, root nao e
# necessario pro fluxo principal.
#
# Pra forcar adb root (apenas em devices que sabidamente funcionam): RUN_ADB_ROOT=1 bash qa_setup.sh
IS_ROOT=0
CURRENT_UID=$(adb shell id -u 2>/dev/null | tr -d '\r')
if [ "$CURRENT_UID" = "0" ]; then
    echo "    adbd ja esta rodando como root."
    IS_ROOT=1
elif [ "${RUN_ADB_ROOT:-0}" = "1" ]; then
    echo "    RUN_ADB_ROOT=1, tentando adb root..."
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
    if ! adb shell true >/dev/null 2>&1; then
        echo "    [ERRO] device sumiu apos 'adb root'."
        echo "    Reconecte o cabo USB e rode novamente SEM RUN_ADB_ROOT (default):"
        echo "        bash qa_setup.sh"
        err "Abortando — adb root quebrou a conexao."
    fi
    NEW_UID=$(adb shell id -u 2>/dev/null | tr -d '\r')
    [ "$NEW_UID" = "0" ] && IS_ROOT=1
else
    echo "    Pulado por padrao (RUN_ADB_ROOT=0). Memtester roda sem root nesse fluxo."
fi

# Sanity check: device tem que estar online pros proximos passos (push/install)
if ! adb shell true >/dev/null 2>&1; then
    err "Device nao esta acessivel via adb. Reconecte o USB e rode 'adb devices' pra confirmar."
fi

info 2 "setenforce 0 (libera SELinux ate o reboot)"
if [ "$IS_ROOT" = "1" ]; then
    adb shell setenforce 0 || echo "    [AVISO] setenforce 0 falhou (provavel sepolicy estrita)."
else
    echo "    Pulado (precisa root). Se o APK falhar com 'permission denied' em algum script, sera SELinux."
fi

info 3 "Push memtester pra /data/local/tmp/"
adb push "$(to_win_path "$MEMTESTER")" /data/local/tmp/memtester
adb shell chmod 755 /data/local/tmp/memtester

info 4 "Install APK"
adb install -r "$(to_win_path "$APK")"

info 5 "Conceder permissoes de storage"
adb shell pm grant "$PKG" android.permission.WRITE_EXTERNAL_STORAGE 2>/dev/null || true
adb shell pm grant "$PKG" android.permission.READ_EXTERNAL_STORAGE  2>/dev/null || true
adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true

info 6 "Verificacao final"
adb shell pm path "$PKG" | grep -q "package:" || err "APK nao parece instalado."
adb shell '[ -x /data/local/tmp/memtester ]' || err "memtester nao executavel no device."

echo ""
echo "✓ Setup concluido. Abra 'Memory Test' no device e rode os testes."
echo ""
echo "Obs: se o device reiniciar, rode novamente:"
echo "    adb shell setenforce 0"
echo "(ou rode este script de novo - eh idempotente)"
