-- setup-treino.sql
-- Cria o schema TREINO e os objetos de exemplo usados pelos 35 cenarios.
-- Idempotente: pode ser executado de novo (dropa e recria).
-- Uso: sqlplus -s / as sysdba @setup-treino.sql <PDB-ou-dash> <TREINO_PASSWORD>

whenever sqlerror continue
set verify off feedback on

define pdb = '&1'
define pwd = '&2'

column dummy new_value need_container
select case when upper('&pdb') != '-' then 1 else 0 end as dummy from dual;

prompt == Trocando de container (se aplicavel) ==
alter session set container = &pdb;

prompt == Recriando usuario TREINO ==
begin
  for r in (select username from dba_users where username = 'TREINO') loop
    execute immediate 'drop user treino cascade';
  end loop;
end;
/

prompt == Tablespace dedicada do treino (nunca a USERS, que e a default permanent do PDB e o Oracle recusa dropar: ORA-12919) ==
declare
  v_existe number;
begin
  select count(*) into v_existe from dba_tablespaces where tablespace_name = 'TREINO_DATA';
  if v_existe = 0 then
    execute immediate 'create tablespace treino_data datafile size 100M autoextend on next 50M maxsize 2G';
  end if;
end;
/

create user treino identified by "&pwd" default tablespace treino_data quota unlimited on treino_data;
grant create session, create table, create view, create sequence, create procedure, create trigger to treino;

prompt == Tabelas ==
create table treino.clientes (
  id         number primary key,
  nome       varchar2(100) not null,
  email      varchar2(150),
  criado_em  date default sysdate
);

create sequence treino.clientes_seq start with 1 increment by 1;

create table treino.pedidos (
  id          number primary key,
  cliente_id  number not null,
  valor       number(12,2) not null,
  status      varchar2(20) default 'ABERTO',
  observacao  varchar2(200),
  criado_em   date default sysdate,
  constraint fk_pedidos_cliente foreign key (cliente_id) references treino.clientes(id)
);

create sequence treino.pedidos_seq start with 1 increment by 1;
create index treino.idx_pedidos_cliente on treino.pedidos(cliente_id);

-- tabela auxiliar so para o cenario de lixeira (recyclebin)
create table treino.pedidos_hist (
  id      number primary key,
  info    varchar2(100)
);

prompt == Carga de dados ==
begin
  for i in 1..300 loop
    insert into treino.clientes (id, nome, email)
    values (treino.clientes_seq.nextval, 'Cliente '||i, 'cliente'||i||'@exemplo.com.br');
  end loop;
  commit;
end;
/

begin
  for i in 1..2000 loop
    insert into treino.pedidos (id, cliente_id, valor, status, observacao)
    values (treino.pedidos_seq.nextval, trunc(dbms_random.value(1,301)), round(dbms_random.value(10,5000),2),
            case mod(i,4) when 0 then 'ABERTO' when 1 then 'PAGO' when 2 then 'CANCELADO' else 'ENTREGUE' end,
            'Pedido gerado no setup #'||i);
  end loop;
  commit;
end;
/

prompt == View e package (usados no cenario de objetos invalidos) ==
create or replace view treino.v_pedidos_cliente as
  select p.id, p.valor, p.status, c.nome as nome_cliente
  from treino.pedidos p join treino.clientes c on c.id = p.cliente_id;

create or replace package treino.pkg_treino as
  function total_cliente(p_cliente_id number) return number;
  function nome_cliente(p_cliente_id number) return varchar2;
end pkg_treino;
/

create or replace package body treino.pkg_treino as
  function total_cliente(p_cliente_id number) return number is
    v_total number;
  begin
    select sum(valor) into v_total from treino.pedidos where cliente_id = p_cliente_id;
    return nvl(v_total, 0);
  end total_cliente;

  function nome_cliente(p_cliente_id number) return varchar2 is
    v_nome varchar2(100);
  begin
    select nome into v_nome from treino.clientes where id = p_cliente_id;
    return v_nome;
  end nome_cliente;
end pkg_treino;
/

prompt == Estatisticas iniciais ==
exec dbms_stats.gather_schema_stats('TREINO');

prompt == Setup concluido ==
select table_name, num_rows from dba_tables where owner='TREINO' order by 1;
