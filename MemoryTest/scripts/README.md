# Scripts de QA

## qa_setup.sh

Prepara um device userdebug pra rodar o APK MemoryTest **sem nenhuma alteração na imagem AOSP** — instala o APK, empurra o memtester, desliga SELinux e concede permissões.

### Pacote pro time de QA

Monta uma pasta com 3 (ou 4) arquivos e zipa:

```
MemoryTest_QA/
├── qa_setup.sh
├── app-release.apk
├── memtester-arm64       # devices recentes (quase tudo)
└── memtester-arm32       # opcional, devices arm32 antigos
```

Onde conseguir cada arquivo:

| Arquivo | Origem |
|---|---|
| `qa_setup.sh` | Este repositório |
| `app-release.apk` | `MemoryTest/app/build/outputs/apk/release/app-release.apk` (após `./gradlew assembleRelease`) |
| `memtester-arm64` | `out/target/product/<board>/system/bin/memtester` da árvore AOSP que você buildou (qualquer device arm64 do qual você tenha imagem compilada serve) |

### Uso pelo QA

```bash
chmod +x qa_setup.sh
./qa_setup.sh
```

O script:
1. Detecta a arquitetura do device automaticamente
2. Confirma que é userdebug/eng
3. `adb root`
4. `setenforce 0`
5. Push memtester pra `/data/local/tmp/`
6. `adb install -r` do APK
7. Concede permissões de storage

QA abre o app **Memory Test** no device, escolhe o teste, roda. Cabo USB pode até desconectar.

### Argumentos opcionais

```bash
./qa_setup.sh /caminho/custom.apk /caminho/custom-memtester
```

### Pegadinhas

- **Reboot do device** → SELinux volta pra enforcing. Roda `adb shell setenforce 0` (ou o script inteiro de novo, é idempotente).
- **Build não-userdebug** → `adb root` falha. Script aborta com mensagem clara.
- **Memtester de arquitetura errada** → script detecta o ABI e procura `memtester-<arch>` correspondente. Se o arquivo não existir na pasta, aborta dizendo qual arquitetura ele estava esperando.

### Pra Windows

QA em Windows pode rodar via:
- **Git Bash** (instalado com Git for Windows) — `.sh` roda direto
- **WSL** (Windows Subsystem for Linux)
- **PowerShell** — precisaria de uma versão `.ps1` (não fornecida ainda; me avise se precisar)
