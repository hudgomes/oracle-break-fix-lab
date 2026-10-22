#!/bin/bash
# oracle-break-fix-lab.sh -- treino de DBA Oracle em laboratorio proprio.
# Uso: oracle-break-fix-lab.sh <nome-do-banco> [modo]
#   modo: (vazio)=sorteia 1 ou 2 cenarios | fisica | logica | <numero 1-35>
#         | status | backup | restaurar
#   oracle-break-fix-lab.sh lista   -> lista os 35 cenarios, sem precisar de nome
#
# So funciona em laboratorio: os bancos permitidos estao em lab.conf. Antes de
# qualquer dano, sempre faz backup RMAN completo + copias + verificacao, e exige
# que o DBA digite o nome do banco para confirmar.
set -u
umask 077

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$LAB_DIR/lab.conf"
SECRETS="$LAB_DIR/lab.secrets"
LOCK="/tmp/oracle-break-fix-lab.lock"
mkdir -p "$LAB_DIR/logs" "$LAB_DIR/.state" "$LAB_DIR/chamados" "$LAB_DIR/gabarito"
LOG="$LAB_DIR/logs/lab.log"
HOJE="$(date '+%Y-%m-%d')"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
die() { log "ERRO: $*"; exit 1; }

# ---------------------------------------------------------------- catalogo --
# formato: numero|categoria|funcao|titulo
CATALOGO=(
"1|fisico|fisico_01_redo_current|Perda do grupo de redo log CURRENT"
"2|fisico|fisico_02_redo_active|Perda de grupo de redo log ainda nao arquivado (ACTIVE)"
"3|fisico|fisico_03_redo_inactive|Perda de grupo de redo log INACTIVE ja arquivado"
"4|fisico|fisico_04_membro_redo|Perda de um membro (nao todos) de um grupo de redo"
"5|fisico|fisico_05_controlfile_um|Perda de um controlfile (dos dois multiplexados)"
"6|fisico|fisico_06_system|Corrupcao do datafile de SYSTEM (CDB root)"
"7|fisico|fisico_07_sysaux|Corrupcao do datafile de SYSAUX do PDB"
"8|fisico|fisico_08_undo|Corrupcao do datafile de UNDO (CDB root)"
"9|fisico|fisico_09_datafile_usuario|Perda de datafile de tablespace de usuario"
"10|fisico|fisico_10_bloco_tabela|Corrupcao de bloco de uma tabela"
"11|fisico|fisico_11_bloco_indice|Corrupcao de bloco de um indice"
"12|fisico|fisico_12_cabecalho_datafile|Corrupcao do cabecalho de um datafile"
"13|fisico|fisico_13_sem_temp|Tempfile removido (erro so aparece no alert)"
"14|fisico|fisico_14_spfile|Perda do spfile"
"15|fisico|fisico_15_orapw|Perda do password file (orapw)"
"16|fisico|fisico_16_archive_faltando|Gap de archivelog (arquivo removido)"
"17|fisico|fisico_17_archive_corrompido|Archivelog corrompido (nao removido)"
"18|fisico|fisico_18_datafile_sem_backup|Datafile novo, criado apos o ultimo backup, perdido"
"19|fisico|fisico_19_fra_cheia|Fast Recovery Area quase cheia"
"20|fisico|fisico_20_listener|Listener parado"
"21|fisico|fisico_21_controlfile_todos|Perda de TODOS os controlfiles"
"22|logico|logico_01_drop_purge|DROP TABLE PURGE (sem lixeira)"
"23|logico|logico_02_truncate|TRUNCATE TABLE indevido"
"24|logico|logico_03_delete|DELETE em massa sem WHERE"
"25|logico|logico_04_update|UPDATE em massa com dado errado"
"26|logico|logico_05_drop_user|DROP USER ... CASCADE indevido"
"27|logico|logico_06_drop_tablespace|DROP TABLESPACE INCLUDING CONTENTS AND DATAFILES"
"28|logico|logico_07_coluna|DROP COLUMN com dados importantes"
"29|logico|logico_08_objetos_invalidos|Objetos PL/SQL INVALID apos alteracao de estrutura"
"30|logico|logico_09_constraint|Constraint de integridade desabilitada"
"31|logico|logico_10_indice_unusable|Indice marcado UNUSABLE"
"32|logico|logico_11_sequence|Sequence reiniciada, colidindo com dados existentes"
"33|logico|logico_12_usuario_bloqueado|Usuario da aplicacao bloqueado (ACCOUNT LOCK)"
"34|logico|logico_13_lixeira|Multiplas versoes da mesma tabela na lixeira (recyclebin)"
"35|logico|logico_14_estatisticas|Estatisticas travadas/erradas (plano de execucao ruim)"
)

catalogo_linha() { local n="$1"; for l in "${CATALOGO[@]}"; do [ "${l%%|*}" = "$n" ] && { echo "$l"; return 0; }; done; return 1; }

cmd_lista() {
  echo "Num | Categoria | Titulo"
  for l in "${CATALOGO[@]}"; do
    IFS='|' read -r n cat fn titulo <<<"$l"
    printf "%-3s | %-7s | %s\n" "$n" "$cat" "$titulo"
  done
}

# ------------------------------------------------------------------ setup --
NOME="" ORACLE_HOME="" ORACLE_SID="" PDB="" BACKUP_ROOT="" TREINO_PASSWORD=""

carregar_conf() {
  NOME="$1"
  local linha
  linha=$(awk -F: -v n="$NOME" -v h="$(hostname -s)" '$0!~/^#/ && $1==n && $2==h {print; exit}' "$CONF")
  [ -n "$linha" ] || die "banco '$NOME' nao encontrado em lab.conf para este host ($(hostname -s))"
  IFS=: read -r NOME _ ORACLE_HOME ORACLE_SID PDB BACKUP_ROOT <<<"$linha"
  [ -f "$SECRETS" ] || die "faltando $SECRETS (copie de lab.secrets.example e preencha)"
  # shellcheck disable=SC1090
  source "$SECRETS"
  [ -n "${TREINO_PASSWORD:-}" ] || die "TREINO_PASSWORD vazio em lab.secrets"
  export ORACLE_HOME ORACLE_SID
  export PATH="$ORACLE_HOME/bin:$PATH"
  mkdir -p "$BACKUP_ROOT"
}

confirmar_nome() {
  echo "Esta operacao pode DANIFICAR o banco '$NOME' de verdade (ambiente de laboratorio)."
  read -r -p "Digite o nome do banco para confirmar ($NOME): " resp
  [ "$resp" = "$NOME" ] || die "confirmacao nao bateu, abortando"
}

# ------------------------------------------------------------- helpers SQL --
# SQL*Plus so aceita 1 comando por linha e exige "/" apos "end;" de bloco
# PL/SQL -- os cenarios escrevem varios comandos "stmt1; stmt2;" numa linha so
# por legibilidade, entao normalizamos aqui em vez de reescrever cada um.
normalizar_sql() {
  echo "$1" | sed -E 's/;[[:space:]]+/;\n/g' | sed -E 's/^[[:space:]]*(end;)[[:space:]]*$/\1\n\//i'
}

sql_root() {
  local sql; sql=$(normalizar_sql "$1")
  sqlplus -s / as sysdba 2>&1 <<SQLEOF
set heading off feedback off pagesize 0 verify off trimspool on linesize 1000
whenever sqlerror continue
$sql
exit;
SQLEOF
}

sql_pdb() {
  local pre="" sql; sql=$(normalizar_sql "$1")
  [ "$PDB" != "-" ] && pre="alter session set container=$PDB;"
  sqlplus -s / as sysdba 2>&1 <<SQLEOF
set heading off feedback off pagesize 0 verify off trimspool on linesize 1000
whenever sqlerror continue
$pre
$sql
exit;
SQLEOF
}

rman_run() {
  rman target / 2>&1 <<RMANEOF
$1
RMANEOF
}

db_status() {
  local q="select name, open_mode from v\$database;"
  [ "$PDB" != "-" ] && q="$q
select name, open_mode from v\$pdbs where name='$PDB';"
  sql_root "$q"
}

# --------------------------------------------------------------- pre-voo --
preflight_backup() {
  local ts; ts="$(date '+%Y%m%d-%H%M%S')"
  local dir="$BACKUP_ROOT/$ts"
  mkdir -p "$dir"
  log "Backup de seguranca em $dir ..."

  sql_root "create pfile='$dir/init${ORACLE_SID}.ora.bkp' from spfile;" >>"$LOG" 2>&1
  cp -a "$ORACLE_HOME/dbs/orapw${ORACLE_SID}" "$dir/" 2>/dev/null
  grep "^${ORACLE_SID}:" /etc/oratab > "$dir/oratab.linha" 2>/dev/null
  cp -a "$ORACLE_HOME/network/admin/listener.ora" "$dir/" 2>/dev/null
  cp -a "$ORACLE_HOME/network/admin/tnsnames.ora" "$dir/" 2>/dev/null
  sql_root "alter database backup controlfile to trace as '$dir/controlfile.trc' reuse;" >>"$LOG" 2>&1
  sql_root "select dbid from v\$database;" > "$dir/dbid.txt" 2>&1

  rman_run "
configure controlfile autobackup on;
backup as compressed backupset format '$dir/full_%U' database plus archivelog;
backup current controlfile format '$dir/ctl_%U';
" >>"$LOG" 2>&1
  if ! grep -q "Finished backup" "$LOG"; then
    log "AVISO: nao encontrei confirmacao clara de 'Finished backup' no log, validando mesmo assim."
  fi

  local minseq; minseq=$(sql_root "select min(sequence#) from v\$archived_log where deleted='NO';" | tr -d ' \t')
  [ -n "$minseq" ] || minseq=1
  rman_run "
crosscheck archivelog all;
delete noprompt expired archivelog all;
restore validate database;
restore validate archivelog from sequence $minseq;
" > "$dir/validate.txt" 2>&1
  grep -qE "^(RMAN-[0-9]+|ORA-[0-9]+):" "$dir/validate.txt" && { log "ERRO no restore validate, veja $dir/validate.txt"; return 1; }

  ( cd "$dir" && find . -type f ! -name MANIFEST.sha256 -exec sha256sum {} \; > MANIFEST.sha256 )
  log "Backup validado e com manifesto de integridade em $dir/MANIFEST.sha256"
  echo "$dir" > "$LAB_DIR/.state/${NOME}.ultimo_backup"
  echo "$dir"
}

verificar_db_aberto() {
  local out
  out=$(db_status)
  if [ "$PDB" != "-" ]; then
    echo "$out" | grep -qi "READ WRITE" && echo "$out" | grep -c "READ WRITE" | grep -q "^2$" && return 0
  else
    echo "$out" | grep -qi "READ WRITE" && return 0
  fi
  return 1
}

# ------------------------------------------------------- chamado/gabarito --
CHAMADO_TITULO="" CHAMADO_CORPO="" GABARITO_CORPO=""

proximo_arquivo() {
  local dir="$1" n="$2" i=1 f
  f="$dir/${HOJE}-${n}.md"
  while [ -e "$f" ]; do i=$((i+1)); f="$dir/${HOJE}-${n}-${i}.md"; done
  echo "$f"
}

gravar_chamado_gabarito() {
  local n="$1"
  local fc fg
  fc=$(proximo_arquivo "$LAB_DIR/chamados" "$n")
  fg=$(proximo_arquivo "$LAB_DIR/gabarito" "$n")
  cat > "$fc" <<EOF
# Chamado - $HOJE - cenario $n ($NOME)

**Cliente:** Loja Exemplo Ltda
**Assunto:** $CHAMADO_TITULO

Estou com este erro, pode verificar com urgencia?

$CHAMADO_CORPO
EOF
  cat > "$fg" <<EOF
# Gabarito - $HOJE - cenario $n ($NOME)

$GABARITO_CORPO

---
Backup usado como rede de seguranca: ver $LAB_DIR/.state/${NOME}.ultimo_backup
EOF
  log "Chamado gerado: $fc"
  log "Gabarito gerado: $fg"
}

# -------------------------------------------------------- cenarios fisicos --
redo_members_of() { # status -> lista "group:member" via v$logfile/v$log
  sql_root "select l.group#||':'||lf.member from v\$log l join v\$logfile lf on lf.group#=l.group# where l.status='$1';"
}

fisico_01_redo_current() {
  local pares; pares=$(redo_members_of CURRENT)
  sql_root "shutdown abort;" >>"$LOG" 2>&1
  echo "$pares" | while IFS=: read -r g m; do [ -n "$m" ] && rm -f "$m"; done
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco nao sobe depois de uma queda de energia"
  CHAMADO_CORPO="Faltou luz aqui e desde que a energia voltou o banco $ORACLE_SID nao conseguiu abrir."
  GABARITO_CORPO="Removidos os dois membros do grupo de redo CURRENT ($pares) com o banco desligado. Startup falha pedindo recuperacao incompleta. Ha perda do redo nao arquivado (transacoes recentes nao propagadas) -- se o objetivo fosse zero perda, so seria possivel com um membro sobrevivente do mesmo grupo. Recuperacao via RMAN (mais previsivel que o 'recover database until cancel;' interativo do SQL*Plus, que exige responder AUTO/CANCEL no momento certo e e facil de interromper cedo demais por engano): primeiro achar a sequencia certa com 'select max(sequence#)+1 from v\$archived_log where resetlogs_change#=(select resetlogs_change# from v\$database) and deleted=''NO'';' (nao usar max(sequence#) de v\$log direto, inclui a sequencia perdida); depois, tudo numa unica execucao do RMAN -- 'run { set until sequence <essa_sequencia> thread 1; restore database; recover database; }' (restore e recover juntos; so 'recover' sem 'restore' antes pode avancar demais e travar com RMAN-06556) -- por fim 'alter database open resetlogs;'. Um 'recover database;' simples (sem UNTIL) pode parar exatamente no ponto certo mas NAO habilita o RESETLOGS depois (ORA-01139) -- por isso o UNTIL SEQUENCE explicito e necessario."
}

fisico_02_redo_active() {
  sql_pdb "begin for i in 1..2000 loop insert into treino.pedidos_hist(id,info) select nvl(max(id),0)+1, 'carga' from treino.pedidos_hist; commit; end loop; end;" >>"$LOG" 2>&1
  sql_root "alter system set log_archive_dest_state_1=defer;" >>"$LOG" 2>&1
  sql_root "alter system switch logfile; alter system switch logfile;" >>"$LOG" 2>&1
  local alvo; alvo=$(sql_root "select group# from v\$log where status!='CURRENT' and archived='NO' order by sequence# desc;" | head -1 | tr -d ' \t')
  local pares; pares=$(sql_root "select lf.member from v\$logfile lf where lf.group#=$alvo;")
  sql_root "alter system set log_archive_dest_state_1=enable;" >>"$LOG" 2>&1
  sql_root "shutdown abort;" >>"$LOG" 2>&1
  echo "$pares" | while read -r m; do [ -n "$m" ] && rm -f "$m"; done
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco caiu e nao volta, fala em redo log"
  CHAMADO_CORPO="O servidor reiniciou sozinho e agora o banco $ORACLE_SID nao abre, aparece erro de redo log no alert."
  GABARITO_CORPO="Grupo de redo $alvo ainda nao arquivado (ACTIVE) foi destruido com o banco desligado (arquivamento adiado de proposito antes de remover os arquivos). Mesma familia do cenario 1, mesma receita de recuperacao incompleta: achar a sequencia certa ('select max(sequence#)+1 from v\$archived_log where resetlogs_change#=(select resetlogs_change# from v\$database) and deleted=''NO'';'), depois RMAN 'run { set until sequence <essa_sequencia> thread 1; restore database; recover database; }' e 'alter database open resetlogs;' -- com possivel perda de dados nao arquivados."
}

fisico_03_redo_inactive() {
  local g; g=$(sql_root "select group# from v\$log where status='INACTIVE' and archived='YES' order by sequence# desc;" | head -1 | tr -d ' \t')
  local pares; pares=$(sql_root "select member from v\$logfile where group#=$g;")
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  echo "$pares" | while read -r m; do [ -n "$m" ] && rm -f "$m"; done
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro de redo log no alert, banco parece ter desligado sozinho"
  CHAMADO_CORPO="Vi um erro mencionando 'redo log' no alert.log do $ORACLE_SID e o banco nao esta no ar."
  GABARITO_CORPO="Grupo de redo $g (INACTIVE, ja arquivado) teve os arquivos removidos com o banco desligado. Como ja estava arquivado e nao e mais necessario para recovery, NAO precisa restaurar nada: 'alter database clear logfile group $g;' recria os arquivos vazios e resolve, sem perda de dados. (Mais simples que os cenarios 1 e 2 -- a licao e nao restaurar por reflexo sem checar o status do grupo.)"
}

fisico_04_membro_redo() {
  local g; g=$(sql_root "select group# from v\$log where members>1 order by dbms_random.value;" | head -1 | tr -d ' \t')
  local m; m=$(sql_root "select member from v\$logfile where group#=$g and dbms_random.value<1 order by dbms_random.value;" | head -1 | tr -d ' \t')
  dd if=/dev/zero of="$m" bs=8192 count=50 conv=notrunc >>"$LOG" 2>&1
  sql_root "alter system switch logfile; alter system switch logfile; alter system switch logfile;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro aparecendo sozinho no alert.log, banco continua no ar"
  CHAMADO_CORPO="Esta aparecendo um erro de I/O mencionando um redo log no alert do $ORACLE_SID, mas o sistema continua funcionando normalmente."
  GABARITO_CORPO="Apenas UM membro do grupo $g foi corrompido (nao os dois) -- o banco sobrevive usando o membro espelhado. Correcao sem downtime: dropar o membro ruim e adicionar um novo, ex.: 'alter database add logfile member <novo_path> to group $g; alter database drop logfile member $m;' Arquivo afetado: $m"
}

fisico_05_controlfile_um() {
  local cf; cf=$(sql_root "select name from v\$controlfile order by dbms_random.value;" | head -1 | tr -d ' \t')
  local sobrevivente; sobrevivente=$(sql_root "select name from v\$controlfile where name!='$cf';" | head -1 | tr -d ' \t')
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  rm -f "$cf"
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco nao monta, erro de controlfile"
  CHAMADO_CORPO="O $ORACLE_SID nao sobe depois da manutencao de disco de hoje, o erro fala em controlfile."
  GABARITO_CORPO="Controlfile $cf foi removido (o outro, $sobrevivente, sobrevive intacto). Correcao: com o banco em nomount, copiar o sobrevivente para o caminho que falta ('cp $sobrevivente $cf') e dar 'alter database mount; alter database open;'. Nao precisa de RMAN pois ha copia valida local."
}

fisico_06_system() {
  # Corromper blocos no meio do arquivo nao impede o open (so da erro quando
  # alguem le aquele bloco especifico) -- precisa do cabecalho (bloco 0) para
  # o Oracle recusar montar/abrir de cara. Confirmado neste ambiente: blocos
  # no meio do SYSTEM nao bloqueiam startup, so aparecem num restore validate.
  local f; f=$(sql_root "select file_name from cdb_data_files where tablespace_name='SYSTEM' and con_id=1;" | head -1 | tr -d ' \t')
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$f" bs=8192 count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Instancia nao abre, erro no datafile de SYSTEM"
  CHAMADO_CORPO="O $ORACLE_SID nao abre de forma alguma, o erro aponta para o datafile do SYSTEM."
  GABARITO_CORPO="Datafile de SYSTEM do CDB root ($f) corrompido em disco. Como SYSTEM e critico, a instancia nao abre. Correcao via RMAN: 'startup mount; restore datafile <num>; recover datafile <num>; alter database open;' (identificar <num> com 'report schema;' ou 'select file# from v\$datafile'). Backup usado: ver pasta do ultimo backup."
}

fisico_07_sysaux() {
  # Precisa do cabecalho (bloco 0) -- corrupcao no meio do arquivo nao impede
  # o PDB de abrir, so da erro quando algo le aquele bloco (ver fisico_06).
  local f; f=$(sql_pdb "select file_name from cdb_data_files where tablespace_name='SYSAUX' and con_id=(select con_id from v\$pdbs where name='$PDB');" | head -1 | tr -d ' \t')
  sql_root "alter pluggable database $PDB close immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$f" bs=8192 count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "alter pluggable database $PDB open;" >>"$LOG" 2>&1
  CHAMADO_TITULO="PDB $PDB nao abre, resto do banco normal"
  CHAMADO_CORPO="O CDB esta de pe mas o PDB $PDB nao consigo abrir, erro no SYSAUX."
  GABARITO_CORPO="Datafile de SYSAUX do PDB $PDB corrompido ($f), PDB fechado. Correcao com a instancia mounted (nao precisa trocar de container, RMAN resolve pelo numero absoluto do arquivo): 'restore datafile <num>; recover datafile <num>;' e depois 'alter pluggable database $PDB open;'"
}

fisico_08_undo() {
  # Cabecalho (bloco 0), nao meio do arquivo -- ver nota em fisico_06.
  local f; f=$(sql_root "select file_name from cdb_data_files where tablespace_name like 'UNDOTBS%' and con_id=1;" | head -1 | tr -d ' \t')
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$f" bs=8192 count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco trava no startup, nao completa a abertura"
  CHAMADO_CORPO="O $ORACLE_SID fica parado tentando subir e nao completa, parece travado."
  GABARITO_CORPO="Datafile de UNDO do CDB root ($f) corrompido. A instancia precisa do undo para recuperacao de transacoes, entao trava/erra no startup. Correcao via RMAN com o banco em mount: 'restore datafile <num>; recover datafile <num>; alter database open;'"
}

fisico_09_datafile_usuario() {
  local f; f=$(sql_pdb "select file_name from cdb_data_files where tablespace_name='TREINO_DATA' and con_id=(select con_id from v\$pdbs where name='$PDB');" | head -1 | tr -d ' \t')
  sql_root "shutdown abort;" >>"$LOG" 2>&1
  rm -f "$f"
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro de arquivo faltando, aplicacao nao grava mais pedidos"
  CHAMADO_CORPO="A aplicacao que usa a tablespace TREINO_DATA do $PDB parou de funcionar, acho que falta um arquivo."
  GABARITO_CORPO="Datafile da tablespace TREINO_DATA do PDB $PDB removido ($f). O efeito no CDB ROOT varia por versao: em 12.1 multitenant o root nem abre com esse arquivo faltando (ORA-01157/ORA-01110 no 'alter database open;'); em versoes mais novas (23ai/26ai) o isolamento e melhor -- o root abre normal e so o PDB $PDB fica MOUNTED. Nos dois casos a saida e a mesma, com a instancia pelo menos em MOUNT: RMAN direto, sem precisar trocar de container (resolve pelo numero absoluto do arquivo): 'restore datafile <num>; recover datafile <num>;' e so depois abrir -- 'alter database open;' se o root tambem estava fechado, ou so 'alter pluggable database $PDB open;' se so o PDB estava preso."
}

achar_bloco() {
  # $1 = sql que retorna "file#:block#" de um objeto
  sql_pdb "$1" | head -1 | tr -d ' \t'
}

fisico_10_bloco_tabela() {
  # rowid_relative_fno da 0 em tablespace BIGFILE (sem numero relativo no
  # rowid) -- rowid_to_absolute_fno funciona nos dois casos (smallfile e
  # bigfile) e sempre bate com file_id de cdb_data_files.
  local fb; fb=$(achar_bloco "select dbms_rowid.rowid_to_absolute_fno(rowid,'TREINO','PEDIDOS')||':'||dbms_rowid.rowid_block_number(rowid) from treino.pedidos where rownum=1;")
  local fn="${fb%%:*}" bl="${fb##*:}"
  local path; path=$(sql_pdb "select file_name from cdb_data_files where file_id=$fn;" | head -1 | tr -d ' \t')
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$path" bs=8192 seek="$bl" count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro ORA-01578 ao consultar pedidos"
  CHAMADO_CORPO="Alguns relatorios da tabela de pedidos estao dando erro ORA-01578 (bloco corrompido)."
  GABARITO_CORPO="Bloco $bl do arquivo $fn (datafile $path), da tabela TREINO.PEDIDOS, foi zerado. O banco abre normalmente, o erro so aparece ao ler aquele bloco. Correcao pontual sem restaurar o arquivo inteiro: 'recover datafile $fn block $bl;' (ou RMAN 'blockrecover datafile $fn block $bl;')."
}

fisico_11_bloco_indice() {
  # block_id e o 1o bloco do extent -- no ASSM costuma ser bitmap, nao B-tree
  # de verdade; soma-se um offset para cair num bloco realmente usado.
  local fb; fb=$(achar_bloco "select file_id||':'||(block_id+3) from dba_extents where owner='TREINO' and segment_name='IDX_PEDIDOS_CLIENTE' and rownum=1;")
  local fn="${fb%%:*}" bl="${fb##*:}"
  local path; path=$(sql_pdb "select file_name from cdb_data_files where file_id=$fn;" | head -1 | tr -d ' \t')
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$path" bs=8192 seek="$bl" count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro ORA-01578 num indice, so em algumas consultas"
  CHAMADO_CORPO="De vez em quando uma consulta na tabela de pedidos da erro ORA-01578 mencionando um indice."
  GABARITO_CORPO="Bloco $bl do indice TREINO.IDX_PEDIDOS_CLIENTE (arquivo $fn, $path) foi zerado. Diferente de um bloco de tabela: indice se reconstroi a partir dos dados, nao precisa de restore. Cuidado: 'alter index ... rebuild;' simples AINDA LE o indice antigo (inclusive o bloco corrompido) e repete o mesmo ORA-01578 -- o fix real e dropar e criar de novo (so entao le a tabela, nao o indice velho): 'drop index treino.idx_pedidos_cliente; create index treino.idx_pedidos_cliente on treino.pedidos(cliente_id);' ('rebuild online', se disponivel na edicao, tambem resolve)."
}

fisico_12_cabecalho_datafile() {
  local f; f=$(sql_pdb "select file_name from cdb_data_files where tablespace_name='TREINO_DATA' and con_id=(select con_id from v\$pdbs where name='$PDB');" | head -1 | tr -d ' \t')
  sql_root "alter pluggable database $PDB close immediate;" >>"$LOG" 2>&1
  dd if=/dev/zero of="$f" bs=8192 count=1 conv=notrunc >>"$LOG" 2>&1
  sql_root "alter pluggable database $PDB open;" >>"$LOG" 2>&1
  CHAMADO_TITULO="PDB nao abre, erro de verificacao de datafile"
  CHAMADO_CORPO="O PDB $PDB nao abre, o erro fala em falha de verificacao (verification check) de um arquivo."
  GABARITO_CORPO="Cabecalho (bloco 1) do datafile $f zerado -- diferente de corrupcao no meio do arquivo, aqui o Oracle nem reconhece a identidade do arquivo. Nao ha recovery de bloco possivel: precisa do restore completo do datafile ('restore datafile <num>; recover datafile <num>;') antes de reabrir o PDB."
}

fisico_13_sem_temp() {
  local f; f=$(sql_pdb "select file_name from dba_temp_files;" | head -1 | tr -d ' \t')
  rm -f "$f"
  sql_pdb "alter session set workarea_size_policy=manual; alter session set sort_area_size=1; select /*+ no_index(p) */ * from treino.pedidos order by valor desc, observacao desc, criado_em desc;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Relatorio com ORDER BY falhando, nada mais parece afetado"
  CHAMADO_CORPO="Um relatorio que ordena os pedidos comecou a dar erro, o resto do sistema parece normal."
  GABARITO_CORPO="Tempfile removido ($f). O banco continua no ar (tempfile so da erro quando algo precisa dele, por isso nao aparece de cara, e aparece no alert.log so na hora do uso). Nao ha nada para restaurar -- TEMP nunca entra em backup. Correcao: 'alter tablespace temp add tempfile size 100M autoextend on;' (e opcionalmente remover a entrada orfa com 'alter database tempfile <id> drop;' se preciso)."
}

fisico_14_spfile() {
  local spdir="$ORACLE_HOME/dbs"
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  mv "$spdir/spfile${ORACLE_SID}.ora" "$spdir/spfile${ORACLE_SID}.ora.escondido" 2>/dev/null
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco nao inicia, nao acha arquivo de parametros"
  CHAMADO_CORPO="Tentei subir o $ORACLE_SID e da erro dizendo que nao encontra o spfile."
  GABARITO_CORPO="spfile${ORACLE_SID}.ora movido de $spdir. Duas saidas validas: (1) mais simples -- usar a copia de pfile feita no backup ('startup pfile=<copia_do_backup>/init${ORACLE_SID}.ora.bkp;' e depois recriar o spfile com 'create spfile from pfile;'); (2) RMAN 'startup nomount; restore spfile from autobackup;' -- SEM spfile/controlfile valido no dbs, o RMAN pede 'set dbid=<numero>' antes (o dbid esta salvo em dbid.txt no backup) e o 'from autobackup' generico pode nao achar a peca pelo dia/formato default -- se nao achar, apontar a peca exata ('restore spfile from <caminho_do_autobackup.bkp>;'). Depois de restaurar o spfile, 'shutdown abort; startup;' para reiniciar limpo."
}

fisico_15_orapw() {
  mv "$ORACLE_HOME/dbs/orapw${ORACLE_SID}" "$ORACLE_HOME/dbs/orapw${ORACLE_SID}.escondido" 2>/dev/null
  CHAMADO_TITULO="Ferramenta de monitoramento nao conecta mais via SYSDBA"
  CHAMADO_CORPO="Uma ferramenta que conecta remoto como sysdba (usuario/senha) no $ORACLE_SID comecou a dar ORA-01031."
  GABARITO_CORPO="Password file orapw${ORACLE_SID} removido de $ORACLE_HOME/dbs. Conexao local '/ as sysdba' continua funcionando (autenticacao por grupo do SO), so quebra autenticacao remota por senha. Correcao: 'orapwd file=$ORACLE_HOME/dbs/orapw${ORACLE_SID} password=<senha> force=y' (ou copiar o orapw salvo no backup). Em versoes mais novas (23ai/26ai) o orapwd valida complexidade de senha (OPW-00029) -- a senha precisa ter numero, letra e caractere especial, ex.: 'Senha#123456'."
}

fisico_16_archive_faltando() {
  sql_root "alter system switch logfile;" >>"$LOG" 2>&1
  local arc; arc=$(sql_root "select name from v\$archived_log where deleted='NO' order by sequence# desc;" | head -1 | tr -d ' \t')
  rm -f "$arc"
  CHAMADO_TITULO="RMAN crosscheck mostrando archivelog EXPIRED"
  CHAMADO_CORPO="Rodei um crosscheck no RMAN do $ORACLE_SID e um archivelog apareceu como EXPIRED, nao sei se e grave."
  GABARITO_CORPO="Archivelog $arc removido do disco diretamente (fora do RMAN), criando um gap. 'crosscheck archivelog all;' marca EXPIRED; 'delete expired archivelog all;' limpa o catalogo. Como o backup de rotina ja copiou os archivelogs, e possivel recuperar com 'restore archivelog sequence <n>;' caso ele seja necessario para uma recuperacao futura."
}

fisico_17_archive_corrompido() {
  local arc; arc=$(sql_root "select name from v\$archived_log where deleted='NO' order by sequence# desc;" | head -1 | tr -d ' \t')
  dd if=/dev/zero of="$arc" bs=8192 seek=5 count=20 conv=notrunc >>"$LOG" 2>&1
  CHAMADO_TITULO="Validacao de archivelog falhando no RMAN"
  CHAMADO_CORPO="Um 'restore archivelog validate' no $ORACLE_SID esta reportando erro num arquivo que nem foi removido."
  GABARITO_CORPO="Archivelog $arc continua no disco (por isso o crosscheck nao pega), mas o conteudo foi corrompido com dd -- so aparece em 'restore archivelog validate' ou quando o RMAN tenta de fato le-lo. Correcao: restaurar essa sequencia especifica do backup, 'restore archivelog sequence <n>;'"
}

fisico_18_datafile_sem_backup() {
  local ts="LAB_SEM_BKP_$(date +%s)"
  sql_pdb "create tablespace $ts datafile size 50M;" >>"$LOG" 2>&1
  local f; f=$(sql_pdb "select file_name from cdb_data_files where tablespace_name='$ts' and con_id=(select con_id from v\$pdbs where name='$PDB');" | head -1 | tr -d ' \t')
  sql_root "shutdown abort;" >>"$LOG" 2>&1
  rm -f "$f"
  sql_root "startup;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Tablespace nova nao abre, RMAN nao acha backup dela"
  CHAMADO_CORPO="Criamos uma tablespace nova ontem e hoje o arquivo dela desapareceu; o RMAN diz que nao tem backup."
  GABARITO_CORPO="Tablespace $ts (datafile $f) foi criada DEPOIS do ultimo backup completo e perdida antes de qualquer backup incremental rodar -- por isso 'restore datafile' falha com RMAN-06026 (sem backup). Licao: sempre fazer backup logo apos criar estrutura nova. Como aqui a tablespace esta vazia e sem uso real, a saida pratica e assumir a perda: 'alter database datafile <num> offline drop;' -- em versoes mais antigas (12.1) isso da ORA-01516 se rodado no CDB root (precisa primeiro 'alter session set container=$PDB;', que funciona mesmo com o root so em mount); em versoes mais novas pode resolver direto. Depois, abrir o que estiver fechado (root e/ou PDB) e recriar a tablespace do zero dentro do PDB."
}

fisico_19_fra_cheia() {
  local dest; dest=$(sql_root "select value from v\$parameter where name='db_recovery_file_dest';" | head -1 | tr -d ' \t')
  local quota_mb; quota_mb=$(( $(sql_root "select value from v\$parameter where name='db_recovery_file_dest_size';" | head -1 | tr -d ' \t') / 1024 / 1024 ))
  local alvo_mb=$(( quota_mb * 97 / 100 ))
  mkdir -p "$dest/LAB_ENCHE_FRA"
  dd if=/dev/zero of="$dest/LAB_ENCHE_FRA/lixo.dat" bs=1M count="$alvo_mb" >>"$LOG" 2>&1
  CHAMADO_TITULO="Backups e archivelog comecando a falhar por falta de espaco"
  CHAMADO_CORPO="O job de backup do $ORACLE_SID comecou a falhar e os alertas mencionam a FRA quase cheia."
  GABARITO_CORPO="FRA ($dest) preenchida artificialmente para ~97% da cota configurada ($quota_mb MB) com um arquivo de lixo em $dest/LAB_ENCHE_FRA/lixo.dat. Correcao imediata: apagar esse arquivo de lixo (nao e backup de verdade) para liberar espaco; correcao definitiva: aumentar 'db_recovery_file_dest_size' ou revisar politica de retencao de backups."
}

fisico_20_listener() {
  lsnrctl stop >>"$LOG" 2>&1
  CHAMADO_TITULO="Aplicacao nao conecta mais no banco"
  CHAMADO_CORPO="A aplicacao que usa o $ORACLE_SID parou de conectar, erro ORA-12541 (TNS no listener)."
  GABARITO_CORPO="Listener parado (lsnrctl stop). O banco em si esta saudavel -- conexao local '/ as sysdba' funciona. Correcao: 'lsnrctl start'."
}

fisico_21_controlfile_todos() {
  local cfs; cfs=$(sql_root "select name from v\$controlfile;")
  sql_root "shutdown immediate;" >>"$LOG" 2>&1
  echo "$cfs" | while read -r f; do [ -n "$f" ] && rm -f "$f"; done
  sql_root "startup nomount;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Banco nao monta, nenhum controlfile encontrado"
  CHAMADO_CORPO="Perdemos TODOS os controlfiles do $ORACLE_SID num problema de disco. O banco nem monta."
  GABARITO_CORPO="Os controlfiles ($cfs) foram todos removidos. Sem nenhuma copia local, a saida e RMAN: 'startup nomount;' (sem spfile/controlfile valido, pode pedir 'set dbid=<numero>', salvo em dbid.txt no backup); 'restore controlfile from autobackup;' (se o 'from autobackup' generico nao achar pelo dia/formato, apontar a peca exata: 'restore controlfile from <caminho_do_autobackup.bkp>;'); 'alter database mount; restore database; recover database;' (RMAN detecta sozinho que o controlfile e restaurado, nao precisa da clausula 'using backup controlfile'); por fim 'alter database open resetlogs;' -- o cenario mais severo do laboratorio fisico, mas sem perda de dados se o backup+archivelog estiverem em dia."
}

# -------------------------------------------------------- cenarios logicos --
logico_01_drop_purge() {
  sql_pdb "drop table treino.pedidos purge;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Tabela de pedidos desapareceu"
  CHAMADO_CORPO="Fiz uma limpeza e a tabela TREINO.PEDIDOS nao existe mais, nem na lixeira."
  GABARITO_CORPO="DROP TABLE ... PURGE ignora a lixeira E remove o objeto por completo -- diferente de DELETE/UPDATE/TRUNCATE em tabela que ainda existe, aqui Flashback Query NAO funciona (a tabela nem existe mais para ser referenciada, da ORA-00942 se tentar 'as of timestamp'). Recuperacao com consistencia: RMAN Tablespace/Table Point-in-Time Recovery para uma instancia auxiliar, num ponto antes do drop, seguido de export/import (Data Pump) so da tabela TREINO.PEDIDOS de volta para producao. Alternativa pratica se houver um export Data Pump anterior da tabela: importar direto dele, mais simples e mais rapido que montar uma instancia auxiliar -- vale a pena quando a tabela e pequena frente ao banco (ex.: tabela de 1GB num banco de 5TB) e a aplicacao tolera os dados voltarem no ponto do export, nao no instante exato antes do drop."
}

logico_02_truncate() {
  sql_pdb "truncate table treino.pedidos;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Tabela de pedidos ficou vazia"
  CHAMADO_CORPO="A tabela TREINO.PEDIDOS esta vazia, ninguem assume ter rodado delete."
  GABARITO_CORPO="TRUNCATE e DDL -- diferente de DELETE, Flashback Query NAO traz os dados de volta aqui (essa e a licao central do cenario): pedir um AS OF anterior ao truncate pode dar ORA-01466 (definicao da tabela mudou, em versoes mais antigas) ou simplesmente devolver 0 linhas sem erro (em versoes mais novas) -- o comportamento exato varia por versao, mas o resultado pratico e o mesmo: sem dados. Recuperacao exige RMAN Tablespace Point-in-Time Recovery (ou RECOVER TABLE em versoes que suportam) para uma instancia auxiliar, restaurando a um ponto antes do truncate -- ou, se houver um export Data Pump recente da tabela, restaurar por ele e aceitar que os dados ficam no ponto do export (nao no exato instante antes do truncate), o que costuma ser aceitavel quando a tabela e pequena e isolada (poucas FKs/dependencias de outras tabelas que mudaram desde o export)."
}

logico_03_delete() {
  sql_pdb "delete from treino.pedidos;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Tabela de pedidos ficou vazia (de novo)"
  CHAMADO_CORPO="TREINO.PEDIDOS esta sem registros, parece um delete sem WHERE."
  GABARITO_CORPO="DELETE gera undo linha a linha -- diferente do truncate, aqui Flashback Query resolve: 'insert into treino.pedidos select * from treino.pedidos as of timestamp (systimestamp - interval '10' minute);' desde que ainda dentro da retencao de undo."
}

logico_04_update() {
  sql_pdb "update treino.pedidos set valor = 0;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Todos os pedidos aparecem com valor zero"
  CHAMADO_CORPO="Os valores dos pedidos em TREINO.PEDIDOS todos zeraram, deve ter sido um update errado."
  GABARITO_CORPO="UPDATE em massa zerou a coluna VALOR. Recuperavel por Flashback Query dentro da retencao de undo: 'update treino.pedidos p set valor = (select valor from treino.pedidos as of timestamp (systimestamp - interval '10' minute) old where old.id=p.id);'"
}

logico_05_drop_user() {
  sql_pdb "drop user treino cascade;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Usuario TREINO nao existe mais no banco"
  CHAMADO_CORPO="O esquema TREINO inteiro desapareceu do $PDB, nao sei o que houve."
  GABARITO_CORPO="DROP USER CASCADE remove usuario e todos os objetos -- Flashback Query nao ajuda (metadados do usuario tambem se foram). Recuperacao padrao: RMAN duplicate/PITR para uma instancia auxiliar num ponto antes do drop, exportar o schema TREINO via Data Pump e importar de volta no banco de producao -- isso preserva a consistencia (tudo no mesmo SCN). Alternativa pratica, se existir um export Data Pump anterior do schema: importar direto dele, sem auxiliar/PITR. E mais rapido e mais barato (nao precisa duplicar um banco de producao inteiro so para tirar um schema pequeno), mas NAO mantem consistencia com o resto do banco -- os dados voltam no ponto do export, nao no instante exato antes do drop. Decisao de DBA: compensa quando o schema e pequeno/isolado frente ao banco (ex.: banco de 5TB, schema de 1GB) e a aplicacao tolera esse gap; nao compensa se o schema tem FKs/dependencias fortes com dados que mudaram depois do export."
}

logico_06_drop_tablespace() {
  sql_pdb "drop tablespace treino_data including contents and datafiles;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro ao acessar qualquer objeto do schema TREINO"
  CHAMADO_CORPO="Nada do schema TREINO funciona mais, o erro fala que a tablespace TREINO_DATA nao existe."
  GABARITO_CORPO="Tablespace TREINO_DATA removida com os datafiles (DROP TABLESPACE INCLUDING CONTENTS AND DATAFILES). Recuperacao classica: RMAN Tablespace Point-in-Time Recovery (TSPITR) da tablespace TREINO_DATA para o momento anterior ao drop -- preserva consistencia. Alternativa pratica se houver export Data Pump anterior dos objetos dessa tablespace: recriar a tablespace vazia e importar por ele, mais simples que um TSPITR, mas sem garantia de consistencia com o restante do banco (mesmo criterio do cenario de DROP USER: vale a pena quando o volume de dados e pequeno frente ao banco todo e a aplicacao tolera o gap de tempo do export)."
}

logico_07_coluna() {
  sql_pdb "alter table treino.pedidos drop column observacao;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Perdemos as observacoes dos pedidos"
  CHAMADO_CORPO="A coluna de observacoes dos pedidos desapareceu da tabela TREINO.PEDIDOS."
  GABARITO_CORPO="DROP COLUMN e DDL irreversivel -- sem flashback de coluna isolada. Recuperacao exige restaurar a tabela a partir do backup (RMAN table/tablespace recovery para auxiliar, extraindo so a coluna perdida), o que preserva consistencia com o resto do banco. Se houver um export Data Pump anterior da tabela, pode ser mais rapido extrair so aquela coluna dele e popular de volta via UPDATE por chave -- mais pratico quando a tabela e pequena, mas os valores recuperados refletem o momento do export, nao o instante exato antes do drop column."
}

logico_08_objetos_invalidos() {
  sql_pdb "alter table treino.clientes rename column nome to nome_cliente;" >>"$LOG" 2>&1
  sql_pdb "select object_name, status from dba_objects where owner='TREINO' and status='INVALID';" >>"$LOG" 2>&1
  CHAMADO_TITULO="Relatorio de pedidos por cliente parou de funcionar"
  CHAMADO_CORPO="A view/relatorio que junta pedidos e clientes esta dando erro, acho que e algum objeto invalido."
  GABARITO_CORPO="Coluna TREINO.CLIENTES.NOME foi renomeada para NOME_CLIENTE, invalidando TREINO.V_PEDIDOS_CLIENTE e TREINO.PKG_TREINO (que referenciam o nome antigo). Nao resolve so com 'alter ... compile' -- e preciso ajustar a definicao da view/package para o novo nome de coluna (ou desfazer o rename) e so depois recompilar."
}

logico_09_constraint() {
  sql_pdb "alter table treino.pedidos disable constraint fk_pedidos_cliente;" >>"$LOG" 2>&1
  sql_pdb "insert into treino.pedidos (id, cliente_id, valor, status) values (treino.pedidos_seq.nextval, 999999, 100, 'ABERTO'); commit;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Relatorio mostra pedido de cliente que nao existe"
  CHAMADO_CORPO="Apareceu um pedido em TREINO.PEDIDOS referenciando um cliente_id que nao existe em TREINO.CLIENTES."
  GABARITO_CORPO="A constraint FK_PEDIDOS_CLIENTE foi desabilitada, permitindo um pedido orfao (cliente_id=999999) entrar. Correcao: localizar/tratar as linhas orfas ('select * from treino.pedidos where cliente_id not in (select id from treino.clientes);') e so depois 'alter table treino.pedidos enable constraint fk_pedidos_cliente;' (falha se ainda houver orfaos)."
}

logico_10_indice_unusable() {
  sql_pdb "alter index treino.idx_pedidos_cliente unusable;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Relatorio por cliente ficou lento"
  CHAMADO_CORPO="Uma consulta que filtra pedidos por cliente, que era rapida, ficou lenta no $PDB."
  GABARITO_CORPO="Indice TREINO.IDX_PEDIDOS_CLIENTE marcado UNUSABLE (o otimizador para de usa-lo). Correcao: 'alter index treino.idx_pedidos_cliente rebuild;'"
}

logico_11_sequence() {
  sql_pdb "drop sequence treino.pedidos_seq; create sequence treino.pedidos_seq start with 1 increment by 1;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Erro de chave duplicada ao criar pedido novo"
  CHAMADO_CORPO="A aplicacao esta dando ORA-00001 (unique constraint) ao criar um pedido novo em TREINO.PEDIDOS."
  GABARITO_CORPO="TREINO.PEDIDOS_SEQ foi recriada do zero (START WITH 1), colidindo com IDs que ja existem na tabela. Correcao: recriar a sequence a partir do maior ID real: 'drop sequence treino.pedidos_seq; create sequence treino.pedidos_seq start with ' || (select max(id)+1 from treino.pedidos) || ' increment by 1;'"
}

logico_12_usuario_bloqueado() {
  sql_pdb "alter user treino account lock;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Aplicacao nao conecta, ORA-28000"
  CHAMADO_CORPO="A aplicacao que usa o usuario TREINO no $PDB nao conecta mais, erro ORA-28000."
  GABARITO_CORPO="Usuario TREINO bloqueado (ACCOUNT LOCK). Correcao: 'alter user treino account unlock;'"
}

logico_13_lixeira() {
  local i
  for i in 1 2 3; do
    sql_pdb "delete from treino.pedidos_hist; insert into treino.pedidos_hist values (1,'versao $i'); commit; drop table treino.pedidos_hist;" >>"$LOG" 2>&1
    sql_pdb "create table treino.pedidos_hist (id number primary key, info varchar2(100));" >>"$LOG" 2>&1
  done
  sql_pdb "drop table treino.pedidos_hist;" >>"$LOG" 2>&1
  CHAMADO_TITULO="Preciso recuperar a tabela PEDIDOS_HIST, mas a versao certa"
  CHAMADO_CORPO="Apaguei TREINO.PEDIDOS_HIST sem querer, mas sei que ela foi recriada e apagada varias vezes hoje -- preciso da versao de ANTES do ultimo drop, nao a mais recente."
  GABARITO_CORPO="Ha multiplas versoes de PEDIDOS_HIST na lixeira (varios BIN\$...). Cuidado: a view 'recyclebin' (= user_recyclebin) so mostra objetos do USUARIO CONECTADO -- conectado como sysdba (SYS) ela aparece vazia mesmo tendo lixo da TREINO. Usar 'select object_name, original_name, droptime from dba_recyclebin where owner=''TREINO'' and original_name=''PEDIDOS_HIST'' order by droptime;' para listar todas por data. 'flashback table treino.pedidos_hist to before drop;' sem qualificar restaura so a MAIS RECENTE -- para pegar uma versao anterior e preciso usar o nome BIN\$ exato dela: 'flashback table \"BIN\$....\" to before drop;'"
}

logico_14_estatisticas() {
  sql_pdb "exec dbms_stats.delete_table_stats('TREINO','PEDIDOS');" >>"$LOG" 2>&1
  sql_pdb "exec dbms_stats.set_table_stats('TREINO','PEDIDOS', numrows=>1, numblks=>1, no_invalidate=>false);" >>"$LOG" 2>&1
  sql_pdb "exec dbms_stats.lock_table_stats('TREINO','PEDIDOS');" >>"$LOG" 2>&1
  CHAMADO_TITULO="Relatorio de pedidos ficou muito lento sem motivo aparente"
  CHAMADO_CORPO="Um relatorio sobre TREINO.PEDIDOS que sempre foi rapido esta demorando muito, sem nenhuma mudanca de codigo."
  GABARITO_CORPO="Estatisticas da tabela TREINO.PEDIDOS foram travadas com valores errados (1 linha, quando na verdade tem centenas) via dbms_stats.set_table_stats + lock_table_stats -- o otimizador escolhe planos ruins por achar a tabela vazia. Correcao: 'exec dbms_stats.unlock_table_stats(''TREINO'',''PEDIDOS''); exec dbms_stats.gather_table_stats(''TREINO'',''PEDIDOS'');'"
}

# ----------------------------------------------------------------- status --
cmd_status() {
  echo "=== $NOME ($ORACLE_SID / PDB=$PDB) em $(hostname -s) ==="
  db_status
  echo "--- ultimo backup ---"
  cat "$LAB_DIR/.state/${NOME}.ultimo_backup" 2>/dev/null || echo "(nenhum backup registrado ainda)"
  echo "--- ultimo cenario aplicado ---"
  cat "$LAB_DIR/.state/${NOME}.ultimo_cenario" 2>/dev/null || echo "(nenhum)"
}

# ------------------------------------------------------------- restaurar --
cmd_restaurar() {
  local dir; dir=$(cat "$LAB_DIR/.state/${NOME}.ultimo_backup" 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || die "nao ha backup registrado para restaurar"
  log "Restaurando $NOME a partir de $dir ..."
  sql_root "shutdown abort;" >>"$LOG" 2>&1
  sql_root "startup nomount;" >>"$LOG" 2>&1
  rman_run "
restore controlfile from autobackup;
alter database mount;
restore database;
recover database;
alter database open resetlogs;
" | tee -a "$LOG"
  log "Restauracao concluida (verifique o status)."
}

# ------------------------------------------------------- modo destrutivo --
executar_cenario() {
  local n="$1"
  local linha; linha=$(catalogo_linha "$n") || die "cenario $n nao existe"
  IFS='|' read -r _ cat fn titulo <<<"$linha"
  log "Executando cenario $n ($titulo) ..."
  CHAMADO_TITULO="" CHAMADO_CORPO="" GABARITO_CORPO=""
  "$fn"
  gravar_chamado_gabarito "$n"
  echo "$n ($titulo) em $(date)" >> "$LAB_DIR/.state/${NOME}.ultimo_cenario"
}

cmd_destruir() {
  local modo="$1"
  verificar_db_aberto || die "banco/PDB nao esta aberto -- abra manualmente antes de rodar o laboratorio (regra: nunca abrir no lugar do DBA)"
  confirmar_nome
  preflight_backup >/dev/null || die "backup de seguranca falhou, abortando sem causar dano"

  local alvo=()
  case "$modo" in
    "") # sorteia 1, as vezes 2
      alvo=( $(shuf -i 1-35 -n 1) )
      [ $((RANDOM % 5)) -eq 0 ] && alvo+=( $(shuf -i 1-35 -n 1) )
      ;;
    fisica) alvo=( $(shuf -i 1-21 -n 1) ) ;;
    logica) alvo=( $(shuf -i 22-35 -n 1) ) ;;
    *)
      [[ "$modo" =~ ^[0-9]+$ ]] && [ "$modo" -ge 1 ] && [ "$modo" -le 35 ] || die "modo invalido: $modo"
      alvo=( "$modo" )
      ;;
  esac

  for n in "${alvo[@]}"; do
    executar_cenario "$n"
  done
  echo
  echo "Pronto. Use 'copie os backups em $BACKUP_ROOT para um local de sua preferencia, MANTENDO o backup onde esta' antes de qualquer teste que possa sujar ainda mais o ambiente."
}

# -------------------------------------------------------------------- CLI --
# So roda a CLI quando executado direto (nao quando "source"ado por um
# testador que queira chamar as funcoes de cenario individualmente).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  exec 9>"$LOCK"
  flock -n 9 || die "outra instancia do laboratorio em execucao (lock $LOCK)"

  MODO1="${1:-}"
  [ "$MODO1" = "lista" ] && { cmd_lista; exit 0; }

  NOME_ARG="${1:-}"; MODO="${2:-}"
  [ -n "$NOME_ARG" ] || die "uso: $0 <nome-do-banco>|lista [modo]"
  carregar_conf "$NOME_ARG"

  case "$MODO" in
    status) cmd_status ;;
    backup) confirmar_nome; preflight_backup ;;
    restaurar) confirmar_nome; cmd_restaurar ;;
    fisica|logica|"") cmd_destruir "$MODO" ;;
    [0-9]*) cmd_destruir "$MODO" ;;
    *) die "modo desconhecido: $MODO (use: fisica, logica, <numero>, status, backup, restaurar)" ;;
  esac
fi
