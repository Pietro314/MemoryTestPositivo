# reports/

Pasta destino dos relatórios gerados pelo `pre_check.sh`.

Cada execução cria um arquivo:
```
preinfo_<MODELO>_<YYYYMMDD_HHMMSS>.txt
```

Exemplo:
```
preinfo_L400_20260508_143022.txt
preinfo_T2070_20260508_153045.txt
```

Esses arquivos são a "fingerprint" de capacidades de cada device da matriz —
arquive-os para registro de quais SKUs precisam de AOSP Opção 3 e quais o
ScriptOnly cobre 100%.

Pode commitar esses relatórios em algum repo de QA pra histórico, ou só
arquivar internamente.
