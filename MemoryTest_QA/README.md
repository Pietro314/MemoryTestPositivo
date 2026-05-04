# MemoryTest_QA — pacote pronto pra QA

Pasta auto-contida pra preparar um device userdebug e instalar o APK MemoryTest **sem nenhuma alteração na imagem AOSP**.

## Conteúdo da pasta

```
MemoryTest_QA/
├── qa_setup.sh         # script de setup
├── app-release.apk     # APK MemoryTest assinado
├── README.md           # este arquivo
└── memtester-arm64     # ⚠️ adicionar manualmente — ver abaixo
```

## Adicionando o memtester

O binário `memtester` não está no repositório (depende da arquitetura do device-under-test). Você precisa pegar de uma árvore AOSP que tenha sido buildada com `PRODUCT_PACKAGES += memtester`:

```bash
# arm64 (a maioria dos devices recentes)
cp ~/tl10_2/out/target/product/<board>/system/bin/memtester \
   MemoryTest_QA/memtester-arm64

# arm32 (devices antigos, opcional)
cp /caminho/para/build_arm32/out/target/product/<board>/system/bin/memtester \
   MemoryTest_QA/memtester-arm32
```

Confirma a arquitetura do binário:
```bash
file MemoryTest_QA/memtester-arm64
# Esperado: ELF 64-bit LSB pie executable, ARM aarch64
```

## Distribuição pro QA

Zipa a pasta inteira (com o memtester já dentro):
```bash
cd /Users/pietrogirardi/projetcs/MemoryTest
zip -r MemoryTest_QA.zip MemoryTest_QA/
```

Manda o `.zip` pro time de QA. Eles descompactam e seguem.

## Uso pelo QA

1. Descompacta o `.zip`
2. Abre terminal na pasta `MemoryTest_QA/`
3. Conecta o device userdebug via USB
4. Roda:
   ```bash
   chmod +x qa_setup.sh
   ./qa_setup.sh
   ```
5. Abre o app **Memory Test** no device e roda os testes

O cabo USB pode até desconectar depois do setup. O script:
- Detecta automaticamente a arquitetura do device (arm64/arm32)
- Confirma que é build userdebug/eng
- `adb root` + `setenforce 0`
- Push do memtester pra `/data/local/tmp/`
- `adb install -r` do APK
- Concede permissões de storage

## Argumentos opcionais

```bash
./qa_setup.sh /caminho/custom.apk /caminho/custom-memtester
```
(Por padrão usa `app-release.apk` e `memtester-<arch>` da própria pasta.)

## Pegadinhas

- **Reboot do device** → SELinux volta pra enforcing. Roda `adb shell setenforce 0` (ou o script inteiro de novo, é idempotente).
- **Build não-userdebug** → `adb root` falha. Script aborta com mensagem clara. Confirma com `adb shell getprop ro.build.type`.
- **Memtester de arquitetura errada** → "exec format error" no log do APK. Confirma com `file memtester-arm64`.

## Pra Windows

QA em Windows pode rodar via **Git Bash** (instalado com Git for Windows) — `.sh` roda direto. WSL também funciona. Não tem versão `.ps1` ainda; me avise se precisar.
