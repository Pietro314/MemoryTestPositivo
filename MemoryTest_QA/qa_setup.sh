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

STEPS=6

echo ""
echo "Device     : $(adb shell getprop ro.product.model | tr -d '\r')"
echo "Build type : $BUILD_TYPE"
echo "Arquitetura: $ABI ($ARCH)"
echo "APK        : $APK"
echo "memtester  : $MEMTESTER"
echo ""

info 1 "adb root"
adb root >/dev/null
adb wait-for-device

info 2 "setenforce 0 (libera SELinux ate o reboot)"
adb shell setenforce 0

info 3 "Push memtester pra /data/local/tmp/"
adb push "$MEMTESTER" /data/local/tmp/memtester >/dev/null
adb shell chmod 755 /data/local/tmp/memtester

info 4 "Install APK"
adb install -r "$APK" >/dev/null

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
