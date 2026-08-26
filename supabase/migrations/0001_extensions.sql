-- Расширения, на которых держится поиск.
--
-- pgvector даёт векторный тип и операторы близости для смыслового поиска.
-- pg_trgm нужен для опечаток: голосовые записи распознаются неточно,
-- и «Скуратов» иногда приезжает как «Скураттов».
-- unaccent снимает диакритику, чтобы «ё» и «е» не считались разными буквами.

create extension if not exists vector;
create extension if not exists pg_trgm;
create extension if not exists unaccent;

-- Русская конфигурация полнотекстового поиска со снятием диакритики.
-- Стандартная russian не убирает «ё», из-за чего «счёт» и «счет»
-- попадают в разные лексемы и запись не находится.
do $$
begin
  if not exists (select 1 from pg_ts_config where cfgname = 'russian_unaccent') then
    create text search configuration russian_unaccent (copy = russian);

    alter text search configuration russian_unaccent
      alter mapping for hword, hword_part, word
      with unaccent, russian_stem;
  end if;
end
$$;
