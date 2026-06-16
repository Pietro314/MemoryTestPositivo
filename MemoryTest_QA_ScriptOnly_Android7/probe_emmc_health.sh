#!/system/bin/sh
# probe_emmc_health.sh
# Diagnostico pra descobrir onde o L3 (mt6739, Android 7.1) expoe os dados
# de health do eMMC (life_time / pre_eol_info), ja que os paths sysfs/proc
# padrao retornaram vazio.
#
# Uso (no PC, com device conectado via adb):
#   adb push probe_emmc_health.sh /data/local/tmp/
#   adb shell "su 0 sh /data/local/tmp/probe_emmc_health.sh" > probe_L3.txt
#
# Mandar o probe_L3.txt de volta pra analise.

echo "=== UID ==="
id

echo ""
echo "=== mmc binary (mmc-utils) ==="
which mmc 2>/dev/null || command -v mmc 2>/dev/null || echo "mmc nao encontrado no PATH"
if command -v mmc >/dev/null 2>&1; then
    echo "--- mmc extcsd read /dev/block/mmcblk0 (primeiras 30 linhas) ---"
    mmc extcsd read /dev/block/mmcblk0 2>&1 | head -30
fi

echo ""
echo "=== ls /proc/bootdevice/ ==="
ls -la /proc/bootdevice/ 2>/dev/null || echo "  (nao existe)"

echo ""
echo "=== ls /proc/mtk_emmc/ ==="
ls -la /proc/mtk_emmc/ 2>/dev/null || echo "  (nao existe)"

echo ""
echo "=== ls /proc/driver/ ==="
ls -la /proc/driver/ 2>/dev/null || echo "  (nao existe)"

echo ""
echo "=== ls /sys/kernel/debug/mmc0/ ==="
ls -la /sys/kernel/debug/mmc0/ 2>/dev/null || echo "  (nao existe ou debugfs nao montado)"

echo ""
echo "=== find eol|life|health em /proc e /sys ==="
find /proc /sys -maxdepth 8 \( -name "*eol*" -o -name "*life*" -o -name "*health*" \) 2>/dev/null

echo ""
echo "=== ls /sys/class/mmc_host/ (estrutura completa) ==="
ls -laR /sys/class/mmc_host/ 2>/dev/null | head -80

echo ""
echo "=== dmesg | grep -i 'mmc\|emmc\|eol\|life' ==="
dmesg 2>/dev/null | grep -iE "mmc|emmc|eol|life" | head -40

echo ""
echo "=== fim ==="
