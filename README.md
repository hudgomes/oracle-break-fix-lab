# oracle-break-fix-lab

Treino de DBA Oracle: um script que estraga de propósito um banco de
**laboratório** (nunca produção) e gera um chamado fictício para você
diagnosticar e corrigir — depois confere a resposta num gabarito.

35 cenários: 21 de dano físico (redo log, controlfile, datafile,
spfile, orapw, archivelog, FRA, listener) e 14 de dano lógico (DROP,
TRUNCATE, DELETE/UPDATE em massa, constraint, índice, sequence,
estatísticas, lixeira...). Testado em Oracle 12.1 e Oracle AI Database
26ai, single-instance com multitenant (CDB/PDB) ou non-CDB.

## ⚠️ Avisos importantes

- **Só roda em laboratório.** O script dá `shutdown abort`, corrompe
  datafiles com `dd`, remove controlfiles e redo logs de verdade. Nunca
  aponte para um banco com dado que importa.
- **Afeta o CDB inteiro, não só a PDB do schema de treino.** Os
  cenários físicos (redo, controlfile, SYSTEM, UNDO, spfile, orapw,
  archivelog, listener) agem no nível do CDB/instância — se o seu CDB
  tiver outras PDBs além da de treino, elas também caem/ficam
  inacessíveis durante o cenário. Não rode num CDB que tenha qualquer
  PDB que você não possa derrubar.
- Roda como o usuário `oracle` do sistema operacional (autenticação
  `/ as sysdba` via grupo), local na própria VM do banco — não é uma
  ferramenta remota.
- Todo cenário sempre faz backup RMAN completo + verificação de
  integridade **antes** de causar o dano. Ainda assim, não é um
  substituto para o backup real do seu ambiente.

## Instalação

### 1. Pré-requisitos

- Oracle Database instalado e rodando (testado em 12.1 e 26ai; deve
  funcionar em qualquer versão 12c+).
- Acesso SSH à VM do banco como o usuário `oracle` (ou o dono do
  software Oracle), com permissão de `sudo` se for instalar como outro
  usuário.
- `bash`, `sqlplus` e `rman` no `PATH` (já vêm com o `ORACLE_HOME`).
- Um banco "de treino": pode ser o próprio banco já existente (CDB
  root para non-CDB, ou uma PDB dedicada) — contanto que você aceite o
  aviso acima sobre o CDB inteiro ser afetado.

### 2. Clonar o repositório

```sh
git clone https://github.com/hudgomes/oracle-break-fix-lab.git
cd oracle-break-fix-lab
```

### 3. Configurar `lab.conf`

```sh
cp lab.conf.example lab.conf
```

Cada linha descreve um banco permitido, no formato:

```
nome:host:ORACLE_HOME:ORACLE_SID:PDB:BACKUP_ROOT
```

- `nome`: como você vai chamar esse banco ao rodar o script (livre).
- `host`: o `hostname -s` **real** da VM (não um alias de SSH) —
  confirme com `hostname -s` na própria VM antes de preencher.
- `PDB`: nome da pluggable database, ou `-` se o banco não usa
  container (non-CDB).
- `BACKUP_ROOT`: pasta onde os backups RMAN de segurança vão ficar
  (pode crescer bastante; de preferência um disco com espaço de
  sobra, fora do `ORACLE_HOME`).

Exemplo:

```
TREINO:minhavm:/u01/app/oracle/product/19.0/dbhome_1:orcl:TREINO:/u02/oracle-lab-backup/TREINO
```

O script só executa se a linha do `nome` escolhido tiver o mesmo
`host` da máquina onde ele está rodando — isso evita apontar para o
banco errado por engano.

### 4. Configurar a senha do schema de treino

```sh
cp lab.secrets.example lab.secrets
chmod 600 lab.secrets
```

Edite `lab.secrets` e defina `TREINO_PASSWORD` com uma senha forte
(em versões recentes do Oracle, como 23ai/26ai, a senha precisa ter
letra, número e caractere especial).

### 5. Criar o schema de treino

```sh
export ORACLE_HOME=/caminho/do/seu/ORACLE_HOME
export ORACLE_SID=seu_sid
export PATH="$ORACLE_HOME/bin:$PATH"

sqlplus -s / as sysdba @setup-treino.sql <PDB-ou- -> <senha-do-lab.secrets>
```

Use o mesmo valor de `PDB` da linha do `lab.conf` (ou `-` para
non-CDB). Isso cria o usuário `TREINO`, uma tablespace dedicada
(`TREINO_DATA`, nunca a tablespace default do banco) e tabelas de
exemplo com dados fictícios.

### 6. Dar permissão de execução

```sh
chmod +x oracle-break-fix-lab.sh
```

## Uso

```sh
./oracle-break-fix-lab.sh lista                 # lista os 35 cenarios
./oracle-break-fix-lab.sh TREINO                # sorteia 1 (as vezes 2) cenarios
./oracle-break-fix-lab.sh TREINO fisica         # sorteia so entre os fisicos (1-21)
./oracle-break-fix-lab.sh TREINO logica         # sorteia so entre os logicos (22-35)
./oracle-break-fix-lab.sh TREINO 7              # roda o cenario 7 direto
./oracle-break-fix-lab.sh TREINO status         # estado atual, ultimo backup/cenario
./oracle-break-fix-lab.sh TREINO backup         # forca um novo backup (sem estragar nada)
./oracle-break-fix-lab.sh TREINO restaurar      # restaura do ultimo backup valido
```

Troque `TREINO` pelo `nome` que você escolheu no `lab.conf`. Em todo
modo destrutivo, o script pede para você digitar o nome do banco de
novo, como confirmação.

### Saídas

- `chamados/<data>-<n>.md`: o "chamado" que você recebe, com os
  sintomas — sem revelar a causa, igual a um ticket de verdade.
- `gabarito/<data>-<n>.md`: o que foi feito de verdade e o passo a
  passo da correção.
- Backups ficam em `BACKUP_ROOT` (fora do git, não comitar).

### Fluxo recomendado

1. Rode `./oracle-break-fix-lab.sh TREINO` (ou `fisica`/`logica`/um
   número específico).
2. Leia o chamado em `chamados/`, **sem olhar o gabarito ainda**.
3. Diagnostique e corrija com as ferramentas normais (`sqlplus`,
   `rman`, alert log).
4. Confira sua solução contra `gabarito/`.
5. Rode `./oracle-break-fix-lab.sh TREINO status` para confirmar que o
   banco voltou ao normal antes do próximo cenário.

## Limitações conhecidas (vale ler antes de reportar "bug")

- **RMAN não respeita `OFFLINE DROP` em comandos amplos.** Se em algum
  cenário você tiver um datafile sem backup e precisar assumir a
  perda (`alter database datafile <n> offline drop;`), um `recover
  database;` ou `recover pluggable database;` **do RMAN** depois disso
  ainda vai reclamar que esse datafile "must be restored". Use o
  `recover database;` do **SQL*Plus** (dentro do container certo) ou
  recupere os outros arquivos um a um pelo RMAN — eles respeitam o
  status OFFLINE corretamente.
- **Multitenant antigo (12.1) x novo (23ai/26ai) se comporta diferente**
  quando falta um datafile de PDB: no 12.1 o CDB inteiro trava sem
  abrir; em versões novas só a PDB afetada fica `MOUNTED` e o resto do
  CDB abre normal. Os gabaritos cobrem os dois casos.
- **Tablespace BIGFILE x SMALLFILE.** Se o seu banco cria tablespaces
  BIGFILE por padrão, `DBMS_ROWID.ROWID_RELATIVE_FNO` retorna 0 (sem
  número relativo no rowid de bigfile) — o script já usa
  `ROWID_TO_ABSOLUTE_FNO`, que funciona nos dois casos, mas se você
  for adaptar/criar cenários novos, prefira sempre essa função.
- Scripts de recuperação incompleta (perda de redo log CURRENT/ACTIVE)
  usam RMAN com `SET UNTIL SEQUENCE`, nunca o `RECOVER ... UNTIL
  CANCEL` interativo do SQL*Plus — este último é frágil de automatizar
  (fácil de cancelar antes da hora) e, de qualquer forma, um `RECOVER
  DATABASE` simples que para no ponto certo não habilita `RESETLOGS`
  depois (seria preciso ligar explicitamente o modo de recuperação
  incompleta).

## Licença

MIT — ver `LICENSE`.
