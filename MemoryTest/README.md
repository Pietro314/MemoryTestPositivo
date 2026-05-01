# Memory Test Factory App

App Android para fábrica de smartphones que executa testes de memória RAM e
storage através de scripts shell rodados como root via daemon nativo.

## Arquitetura

```
[APK Kotlin] --LocalSocket--> [memtest_daemon (root)] --exec--> [scripts]
```

O APK não precisa de root: o daemon nativo (em AOSP) roda como UID 0 via
`init.rc` e executa os scripts. Variáveis de teste por modelo são passadas
ao daemon como `KEY=VALUE` e injetadas no ambiente do script.

Detalhes da integração AOSP em `../aosp_solution/INTEGRACAO_AOSP.md`.

## Funcionalidades

- **Cadastro de devices**: nome, fabricante, código, RAM, storage, classe de
  storage (eMMC/UFS), e todos os limiares de teste editáveis.
- **Defaults inteligentes**: ao escolher RAM e classe de storage, os limiares
  sugeridos preenchem o formulário automaticamente. Baseado em `RamPresets` e
  `StorageClass` em `domain/`.
- **Sugestão por similaridade**: ao cadastrar device com a mesma RAM de outro
  já cadastrado, app oferece copiar os valores do existente.
- **Execução com UI dupla**: aba "Status" com cards por etapa (Pending / Running
  / Pass / Fail / Warn) e aba "Log" com saída crua do script.
- **Histórico persistente**: cada execução é salva no banco (Room) com seus
  steps individuais. Acessível pela home ou por device.
- **Compartilhamento de relatório**: arquivo `.txt` salvo em
  `/sdcard/MemoryTest/` e compartilhável via Intent.

## Estrutura de pastas

```
app/src/main/
├── assets/                          # scripts (referência; produção usa /vendor/etc/factory/)
├── java/com/factory/memorytest/
│   ├── MemoryTestApp.kt             # Application + service locator
│   ├── data/
│   │   ├── db/                      # Room: entities, DAOs, AppDatabase
│   │   └── repo/                    # Repositories
│   ├── domain/                      # Modelos puros + presets
│   ├── service/                     # DaemonClient + ScriptOutputParser
│   └── ui/
│       ├── devicelist/
│       ├── deviceedit/
│       ├── devicedetail/
│       ├── testrun/
│       └── history/
└── res/                             # layouts, drawables, themes Material 3
```

## Build

```bash
./gradlew assembleDebug
```

APK gerado em `app/build/outputs/apk/debug/app-debug.apk`.

## Tecnologias

- Kotlin 1.9 + Coroutines
- Material Components 3 (DayNight)
- Room 2.6 (KSP)
- AndroidX ViewBinding, ViewModel, LiveData
- minSdk 33, targetSdk 34
