# oracle-break-fix-lab

Treino de DBA Oracle: um script que estraga de propósito um banco de laboratório
(nunca produção) e gera um chamado fictício para o DBA diagnosticar e corrigir.

Servidores de laboratório: `lab104` (12.1.0.1) e `lab102` (26ai). Nenhum outro
host deve rodar isto.

## Uso (rodar como `oracle`, local na VM de laboratório)

```
./oracle-break-fix-lab.sh lista                # lista os 35 cenarios
./oracle-break-fix-lab.sh SMART1                # sorteia 1 (as vezes 2) cenarios
./oracle-break-fix-lab.sh SMART1 fisica         # sorteia so entre os fisicos (1-21)
./oracle-break-fix-lab.sh SMART1 logica         # sorteia so entre os logicos (22-35)
./oracle-break-fix-lab.sh SMART1 7              # roda o cenario 7 direto
./oracle-break-fix-lab.sh SMART1 status         # estado atual, ultimo backup/cenario
./oracle-break-fix-lab.sh SMART1 backup         # forca um novo backup (sem estragar nada)
./oracle-break-fix-lab.sh SMART1 restaurar      # restaura do ultimo backup valido
```

`SMART1`, `smartsrv` e `DEV` são os nomes definidos em `lab.conf`.

## Antes de usar em uma VM nova

1. `cp lab.secrets.example lab.secrets && chmod 600 lab.secrets` e preencher a senha.
2. `sqlplus -s / as sysdba @setup-treino.sql <PDB-ou-dash> <senha>` para criar o schema TREINO.
3. Confirmar que o banco/PDB de `lab.conf` está aberto.

## Saídas

- `chamados/<data>-<n>.md`: o "chamado" que o DBA recebe (sem revelar a causa).
- `gabarito/<data>-<n>.md`: o que foi feito de verdade e como corrigir.
- Backups ficam em `BACKUP_ROOT` (fora do git, pode ser grande).

Todo cenário sempre faz backup RMAN completo + verificação antes de causar o
dano. Copie os backups para onde quiser, mas nunca apague o original de lá.
