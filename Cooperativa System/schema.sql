-- Cole tudo no Supabase > SQL Editor > Run

create table livros(id bigserial primary key, titulo text not null unique,
  caixas int not null default 0 check(caixas>=0), soltos int not null default 0 check(soltos>=0));
create table tipos_kit(id bigserial primary key, livro_a bigint not null references livros, livro_b bigint not null references livros,
  qtd int not null default 0 check(qtd>=0), check(livro_a<livro_b), unique(livro_a,livro_b));
create table lideres(id bigserial primary key, nome text not null unique);
create table eventos(id bigserial primary key, data date not null, nota text, fechado boolean not null default false);
create table equipes(id bigserial primary key, evento_id bigint not null references eventos on delete cascade,
  numero int not null, lider_id bigint not null references lideres, unique(evento_id,numero));
create table saidas(id bigserial primary key, equipe_id bigint not null references equipes on delete cascade,
  tipo_kit_id bigint not null references tipos_kit, saiu int not null default 0 check(saiu>=0),
  voltou int not null default 0 check(voltou>=0), check(voltou<=saiu), unique(equipe_id,tipo_kit_id));
create table historico(id bigserial primary key, quando timestamptz not null default now(),
  tipo text not null, descricao text not null, qtd int, obs text);

create function nome_kit(p bigint) returns text language sql stable as $$
  select a.titulo||' + '||b.titulo from tipos_kit k join livros a on a.id=k.livro_a join livros b on b.id=k.livro_b where k.id=p $$;

-- Recebe caixas de um título (só conta caixas)
create function receber_caixas(p_livro bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  update livros set caixas=caixas+p_n where id=p_livro;
  insert into historico(tipo,descricao,qtd,obs) select 'Caixas recebidas',titulo,p_n,p_obs from livros where id=p_livro;
end $$;

-- Abre 1 caixa: caixas -1, livros soltos +N. Sem caixa registada, não deixa.
create function abrir_caixa(p_livro bigint, p_livros int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_livros<=0 then raise exception 'Conte os livros da caixa'; end if;
  update livros set caixas=caixas-1, soltos=soltos+p_livros where id=p_livro and caixas>0;
  if not found then raise exception 'Este título não tem caixas. Registe a caixa primeiro.'; end if;
  insert into historico(tipo,descricao,qtd,obs) select 'Caixa aberta',titulo,p_livros,p_obs from livros where id=p_livro;
end $$;

-- Cria tipo de kit (ordem não importa; títulos têm de ser diferentes)
create function criar_kit(p_a bigint, p_b bigint) returns void language plpgsql as $$
begin
  if p_a=p_b then raise exception 'Um kit precisa de 2 títulos diferentes'; end if;
  insert into tipos_kit(livro_a,livro_b) values(least(p_a,p_b),greatest(p_a,p_b));
exception when unique_violation then raise exception 'Esse tipo de kit já existe';
end $$;

-- Monta kits: -N de cada livro solto, +N kits
create function montar_kits(p_kit bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
declare k tipos_kit;
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  select * into k from tipos_kit where id=p_kit;
  update livros set soltos=soltos-p_n where id in (k.livro_a,k.livro_b);
  update tipos_kit set qtd=qtd+p_n where id=p_kit;
  insert into historico(tipo,descricao,qtd,obs) values('Kits montados',nome_kit(p_kit),p_n,p_obs);
exception when check_violation then raise exception 'Livros soltos insuficientes para montar % kits',p_n;
end $$;

-- Saída: tira do CODE e passa para a equipa (líder)
create function saida_kits(p_equipe bigint, p_kit bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  update tipos_kit set qtd=qtd-p_n where id=p_kit;
  insert into saidas(equipe_id,tipo_kit_id,saiu) values(p_equipe,p_kit,p_n)
    on conflict(equipe_id,tipo_kit_id) do update set saiu=saidas.saiu+p_n;
  insert into historico(tipo,descricao,qtd,obs) select 'Saída de kits',nome_kit(p_kit)||' → '||l.nome,p_n,p_obs
    from equipes q join lideres l on l.id=q.lider_id where q.id=p_equipe;
exception when check_violation then raise exception 'Kits insuficientes no CODE';
end $$;

-- Retorno: volta do líder para o CODE
create function retorno_kits(p_equipe bigint, p_kit bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  update saidas set voltou=voltou+p_n where equipe_id=p_equipe and tipo_kit_id=p_kit;
  if not found then raise exception 'Esta equipa não levou este kit'; end if;
  update tipos_kit set qtd=qtd+p_n where id=p_kit;
  insert into historico(tipo,descricao,qtd,obs) select 'Retorno de kits',nome_kit(p_kit)||' ← '||l.nome,p_n,p_obs
    from equipes q join lideres l on l.id=q.lider_id where q.id=p_equipe;
exception when check_violation then raise exception 'Mais kits do que os que saíram';
end $$;

-- Só utilizadores com login acedem
do $$ declare t text; begin
  foreach t in array array['livros','tipos_kit','lideres','eventos','equipes','saidas','historico'] loop
    execute format('alter table %I enable row level security',t);
    execute format('create policy acesso on %I for all to authenticated using(true) with check(true)',t);
  end loop;
end $$;
