-- Cole tudo no Supabase > SQL Editor > Run
-- ATENÇÃO: isto APAGA todos os dados do sistema (livros, kits, eventos, histórico).
-- O login em auth.users NÃO é tocado por este script.

drop table if exists historico, saidas, equipes, eventos, lideres, tipos_kit, livros cascade;
drop function if exists nome_kit, criar_livro, receber_caixas, abrir_caixa, criar_kit, montar_kits,
  criar_lider, criar_evento, criar_equipe, saida_kits, retorno_kits, fechar_evento,
  excluir_livro, excluir_kit, excluir_lider cascade;

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
  categoria text not null, tipo text not null, descricao text not null, qtd int, obs text);

create function nome_kit(p bigint) returns text language sql stable as $$
  select a.titulo||' + '||b.titulo from tipos_kit k join livros a on a.id=k.livro_a join livros b on b.id=k.livro_b where k.id=p $$;

-- Título novo (a deteção de nomes parecidos é feita no site antes de chamar isto)
create function criar_livro(p_titulo text, p_obs text default null) returns void language plpgsql as $$
begin
  insert into livros(titulo) values(trim(p_titulo));
  insert into historico(categoria,tipo,descricao,obs) values('Livros','Título criado',trim(p_titulo),p_obs);
exception when unique_violation then raise exception 'Já existe um título com esse nome exato';
end $$;

-- Recebe caixas de um título (só conta caixas)
create function receber_caixas(p_livro bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  update livros set caixas=caixas+p_n where id=p_livro;
  insert into historico(categoria,tipo,descricao,qtd,obs) select 'Livros','Caixas recebidas',titulo,p_n,p_obs from livros where id=p_livro;
end $$;

-- Abre 1 caixa: caixas -1, livros soltos +N. Sem caixa registada, não deixa.
create function abrir_caixa(p_livro bigint, p_livros int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_livros<=0 then raise exception 'Conte os livros da caixa'; end if;
  update livros set caixas=caixas-1, soltos=soltos+p_livros where id=p_livro and caixas>0;
  if not found then raise exception 'Este título não tem caixas. Registe a caixa primeiro.'; end if;
  insert into historico(categoria,tipo,descricao,qtd,obs) select 'Livros','Caixa aberta',titulo,p_livros,p_obs from livros where id=p_livro;
end $$;

-- Cria tipo de kit (ordem não importa; títulos têm de ser diferentes)
create function criar_kit(p_a bigint, p_b bigint, p_obs text default null) returns void language plpgsql as $$
declare novo_id bigint;
begin
  if p_a=p_b then raise exception 'Um kit precisa de 2 títulos diferentes'; end if;
  insert into tipos_kit(livro_a,livro_b) values(least(p_a,p_b),greatest(p_a,p_b)) returning id into novo_id;
  insert into historico(categoria,tipo,descricao,obs) values('Kits','Tipo de kit criado',nome_kit(novo_id),p_obs);
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
  insert into historico(categoria,tipo,descricao,qtd,obs) values('Kits','Kits montados',nome_kit(p_kit),p_n,p_obs);
exception when check_violation then raise exception 'Livros soltos insuficientes para montar % kits',p_n;
end $$;

-- Líder novo
create function criar_lider(p_nome text, p_obs text default null) returns void language plpgsql as $$
begin
  insert into lideres(nome) values(trim(p_nome));
  insert into historico(categoria,tipo,descricao,obs) values('Líderes','Líder criado',trim(p_nome),p_obs);
exception when unique_violation then raise exception 'Já existe um líder com esse nome exato';
end $$;

-- Evento novo
create function criar_evento(p_data date, p_nota text default null) returns void language plpgsql as $$
begin
  insert into eventos(data,nota) values(p_data,p_nota);
  insert into historico(categoria,tipo,descricao,obs) values('Eventos','Evento criado',to_char(p_data,'DD/MM/YYYY'),p_nota);
end $$;

-- Equipa nova: número automático (+1) e líder exclusivo (não pode estar noutra equipa em aberto)
create function criar_equipe(p_evento bigint, p_lider bigint) returns void language plpgsql as $$
declare n int;
begin
  if exists(select 1 from equipes q join eventos e on e.id=q.evento_id where e.fechado=false and q.lider_id=p_lider) then
    raise exception 'Este líder já está numa equipa em aberto noutro evento';
  end if;
  select coalesce(max(numero),0)+1 into n from equipes where evento_id=p_evento;
  insert into equipes(evento_id,numero,lider_id) values(p_evento,n,p_lider);
  insert into historico(categoria,tipo,descricao,obs) select 'Eventos','Equipa criada','Equipa '||n||' – '||l.nome,null from lideres l where l.id=p_lider;
end $$;

-- Saída: tira do CODE e passa para a equipa (líder)
create function saida_kits(p_equipe bigint, p_kit bigint, p_n int, p_obs text default null) returns void language plpgsql as $$
begin
  if p_n<=0 then raise exception 'Quantidade inválida'; end if;
  update tipos_kit set qtd=qtd-p_n where id=p_kit;
  insert into saidas(equipe_id,tipo_kit_id,saiu) values(p_equipe,p_kit,p_n)
    on conflict(equipe_id,tipo_kit_id) do update set saiu=saidas.saiu+p_n;
  insert into historico(categoria,tipo,descricao,qtd,obs) select 'Eventos','Saída de kits',nome_kit(p_kit)||' → '||l.nome,p_n,p_obs
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
  insert into historico(categoria,tipo,descricao,qtd,obs) select 'Eventos','Retorno de kits',nome_kit(p_kit)||' ← '||l.nome,p_n,p_obs
    from equipes q join lideres l on l.id=q.lider_id where q.id=p_equipe;
exception when check_violation then raise exception 'Mais kits do que os que saíram';
end $$;

-- Fecha o acerto do evento: kits não devolvidos deixam de contar como "em falta"
create function fechar_evento(p_evento bigint) returns void language plpgsql as $$
begin
  update eventos set fechado=true where id=p_evento;
  insert into historico(categoria,tipo,descricao,obs) select 'Eventos','Evento fechado',to_char(data,'DD/MM/YYYY'),null from eventos where id=p_evento;
end $$;

-- Excluir título: só se não tiver caixas, livros soltos, nem ser usado por um tipo de kit
create function excluir_livro(p_id bigint) returns void language plpgsql as $$
declare l livros;
begin
  select * into l from livros where id=p_id;
  if l.id is null then raise exception 'Título não encontrado'; end if;
  if l.caixas>0 or l.soltos>0 then raise exception 'Este título ainda tem caixas ou livros soltos'; end if;
  if exists(select 1 from tipos_kit where livro_a=p_id or livro_b=p_id) then
    raise exception 'Este título é usado por um tipo de kit; apague o kit primeiro';
  end if;
  delete from livros where id=p_id;
  insert into historico(categoria,tipo,descricao) values('Livros','Título excluído',l.titulo);
end $$;

-- Excluir tipo de kit: só se não houver kits desse tipo no CODE nem histórico de saídas
create function excluir_kit(p_id bigint) returns void language plpgsql as $$
declare k_nome text; k_qtd int;
begin
  select nome_kit(id),qtd into k_nome,k_qtd from tipos_kit where id=p_id;
  if k_nome is null then raise exception 'Kit não encontrado'; end if;
  if k_qtd>0 then raise exception 'Ainda há kits deste tipo no CODE'; end if;
  if exists(select 1 from saidas where tipo_kit_id=p_id) then
    raise exception 'Este kit já foi usado numa saída e não pode ser apagado';
  end if;
  delete from tipos_kit where id=p_id;
  insert into historico(categoria,tipo,descricao) values('Kits','Tipo de kit excluído',k_nome);
end $$;

-- Excluir líder: só se nunca tiver integrado uma equipa (aberta ou já fechada)
create function excluir_lider(p_id bigint) returns void language plpgsql as $$
declare v_nome text;
begin
  select nome into v_nome from lideres where id=p_id;
  if v_nome is null then raise exception 'Líder não encontrado'; end if;
  if exists(select 1 from equipes where lider_id=p_id) then
    raise exception 'Este líder já participou de uma equipa e não pode ser apagado';
  end if;
  delete from lideres where id=p_id;
  insert into historico(categoria,tipo,descricao) values('Líderes','Líder excluído',v_nome);
end $$;

-- Só utilizadores com login acedem
do $$ declare t text; begin
  foreach t in array array['livros','tipos_kit','lideres','eventos','equipes','saidas','historico'] loop
    execute format('alter table %I enable row level security',t);
    execute format('drop policy if exists acesso on %I',t);
    execute format('create policy acesso on %I for all to authenticated using(true) with check(true)',t);
  end loop;
end $$;
