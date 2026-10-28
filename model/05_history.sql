-- =====================================================================
--  Доработка модели под «вброс» из docs/tasks.md:
--
--    * продавец может сменить категорию товара, но отчёты за прошлые
--      периоды должны остаться прежними — модель должна хранить историю
--      изменений;
--    * покупатели переезжают: для любого заказа должен быть виден адрес
--      покупателя на момент заказа, а не текущий.
--
--  Обе задачи решаются одинаково: измерение перестаёт быть одной строкой
--  на объект и становится историей версий. У каждой версии есть промежуток
--  дат, когда она действовала, а заказ соединяется с версией ПО ДАТЕ, а не
--  «по последнему значению». Так называется SCD2 (slowly changing
--  dimension, тип 2), но по сути это просто таблица с датами действия.
--
--  Честная деталь про наши данные. Журнала изменений в выгрузке нет:
--  есть один снимок «как сейчас». Поэтому цепочки смен здесь не построить,
--  и первая версия открывается датой, когда значение впервые встретилось
--  в данных. Смысл не в том, чтобы показать драму переезда, а в том, что
--  путь «заказ -> версия измерения на дату заказа» построен, работает и
--  проверяется: когда появится лента изменений, отчёты менять не придётся,
--  они сами останутся прежними для прошлых периодов.
--
--  Файл можно запускать сколько угодно раз: всё сначала удаляется.
-- =====================================================================

drop view if exists core.v_item_category_as_ordered;
drop view if exists core.v_order_customer_address;
drop view if exists core.v_customer_address_version;
drop view if exists core.v_customer_address_first;
drop table if exists core.dim_customer_history;
drop table if exists core.dim_product_category_history;
drop table if exists core.dim_seller_history;


-- ---------------------------------------------------------------------
-- 1. Адрес покупателя во времени.
--
--    Человек — это customer_unique_id. В данных у него может быть несколько
--    записей customer_id с разными адресами: 252 человека имеют два и более
--    разных адреса (город + штат + индекс). Это и есть переезды.
--
--    Шаг 1: смотрим, когда каждый адрес человека встретился впервые и сколько
--    заказов с этого адреса было.
--    Шаг 2: оставляем по одной версии на дату. Иногда два разных адреса
--    appear в один день: человек физически не может жить в двух городах,
--    это шум в обезличенной выгрузке. Оставляем тот адрес, с которого заказов
--    больше, а при равенстве — первый по алфавиту. Так у дат действия версий
--    не остаётся пересечений, и каждый заказ получает ровно один адрес.
--    Шаг 3: версия действует до даты появления следующего адреса.
-- ---------------------------------------------------------------------
--    Промежуточный список адресов делаем ТАБЛИЦЕЙ, а не представлением:
--    дальше по нему считаются подзапросы «когда начался следующий адрес», и
--    с индексом они проходят за секунды. На представлении те же подзапросы
--    висяли бы минутами, потому что представление пересчитывается заново на
--    каждую строку.
-- ---------------------------------------------------------------------
create table core.tmp_customer_address (
    customer_unique_id text,
    customer_city      text,
    customer_state     text,
    zip_code_prefix    text,
    first_seen         date,
    orders_at_address  integer
);

insert into core.tmp_customer_address
select cu.customer_unique_id,
       cu.customer_city,
       cu.customer_state,
       cu.zip_code_prefix,
       min(fo.purchased_at)::date  as first_seen,
       count(distinct fo.order_id) as orders_at_address
from core.dim_customer cu
join core.fact_order fo on fo.customer_id = cu.customer_id
group by cu.customer_unique_id,
         cu.customer_city,
         cu.customer_state,
         cu.zip_code_prefix;

create index idx_tmp_customer_address
    on core.tmp_customer_address (customer_unique_id, first_seen);

analyze core.tmp_customer_address;


create table core.dim_customer_history (
    customer_unique_id text    not null,
    customer_city      text,
    customer_state     text,
    zip_code_prefix    text,
    valid_from         date    not null,
    valid_to           date    not null,      -- 9999-12-31 = версия ещё действует
    is_current         boolean not null,
    orders_at_address  integer,
    primary key (customer_unique_id, valid_from)
);

insert into core.dim_customer_history
select a.customer_unique_id,
       a.customer_city,
       a.customer_state,
       a.zip_code_prefix,
       a.first_seen as valid_from,
       date '9999-12-31' as valid_to,     -- поставим ниже, когда закроем версии
       true as is_current,
       a.orders_at_address
from core.tmp_customer_address a
-- из двух адресов, появившихся в один день, оставляем только «лучший»:
-- сначала тот, с которого заказов больше, потом по алфавиту города, штата и
-- индекса. Сравнение кортежа — это просто такая запись, Postgres сравнивает
-- поля слева направо.
where not exists (
        select 1
        from core.tmp_customer_address b
        where b.customer_unique_id = a.customer_unique_id
          and b.first_seen = a.first_seen
          and (coalesce(b.orders_at_address, -1),
               coalesce(b.customer_city, ''),
               coalesce(b.customer_state, ''),
               coalesce(b.zip_code_prefix, ''))
            > (coalesce(a.orders_at_address, -1),
               coalesce(a.customer_city, ''),
               coalesce(a.customer_state, ''),
               coalesce(a.zip_code_prefix, ''))
);

-- Теперь закрываем версии: у каждой версии конец — это день ПЕРЕД началом
-- следующей версии того же человека. Тогда промежуток [valid_from, valid_to]
-- захватывает все дни версии и ни одного дня соседней: если переезд случился
-- 5 марта, старая версия действует до 4 марта, а заказ от 5 марта читается
-- уже по новой. Считаем это одним соединением таблицы с самой собой и
-- группировкой, а не подзапросом на каждую строку: на 96 тысячах строк
-- подзапрос на строку работает минутами, а такое соединение — секунды.
update core.dim_customer_history h
   set valid_to = coalesce(x.next_start - 1, date '9999-12-31'),
       is_current = x.next_start is null
  from (
        select a.customer_unique_id,
               a.valid_from,
               min(b.valid_from) as next_start
          from core.dim_customer_history a
          left join core.dim_customer_history b
                 on b.customer_unique_id = a.customer_unique_id
                and b.valid_from > a.valid_from
         group by a.customer_unique_id, a.valid_from
       ) x
 where h.customer_unique_id = x.customer_unique_id
   and h.valid_from = x.valid_from;

-- Сколько версий отбросил выбор «лучшего» адреса на дату: 4 строки из 96 352.
-- Показываем это прямо здесь, чтобы приём не был невидимым.
select '=== история адресов: замеры ===' as demo,
       (select count(distinct (customer_unique_id, first_seen)) from core.tmp_customer_address) as версий_по_данным,
       (select count(*) from core.dim_customer_history) as версий_в_истории,
       (select count(distinct customer_unique_id) from core.dim_customer_history) as людей,
       (select count(*) from (select customer_unique_id
                                from core.dim_customer_history
                               group by customer_unique_id
                              having count(*) > 1) t) as людей_с_двумя_адресами;

drop table core.tmp_customer_address;


-- Адрес заказа: берём версию, которая действовала в дату покупки.
-- Between по обе границы не пересекается: у одной даты может быть только
-- одна действующая версия (это проверяет 07_checks_b.sql).
create view core.v_order_customer_address as
select fo.order_id,
       fo.purchased_at::date   as order_date,
       h.customer_unique_id,
       h.customer_city,
       h.customer_state,
       h.zip_code_prefix
from core.fact_order fo
join core.dim_customer_history h
  on  h.customer_unique_id = fo.customer_unique_id
  and fo.purchased_at::date between h.valid_from and h.valid_to;


-- ---------------------------------------------------------------------
-- 2. Адрес продавца во времени.
--
--    Снимок один, поэтому версия одна на продавца и она открыта.
--    valid_from — дата первой продажи этого продавца: раньше этого
--    момента мы про него ничего не знаем, и придумывать дату нельзя.
-- ---------------------------------------------------------------------
create table core.dim_seller_history (
    seller_id       text    not null,
    seller_city     text,
    seller_state    text,
    zip_code_prefix text,
    valid_from      date    not null,
    valid_to        date    not null,
    is_current      boolean not null,
    primary key (seller_id, valid_from)
);

insert into core.dim_seller_history
select s.seller_id,
       s.seller_city,
       s.seller_state,
       s.zip_code_prefix,
       coalesce(f.first_sale,
                (select min(calendar_date) from core.dim_calendar)) as valid_from,
       date '9999-12-31' as valid_to,
       true as is_current
from core.dim_seller s
left join (
        select i.seller_id, min(o.purchased_at)::date as first_sale
        from core.fact_order_item i
        join core.fact_order o on o.order_id = i.order_id
        where i.seller_id is not null
        group by i.seller_id
     ) f on f.seller_id = s.seller_id;


-- ---------------------------------------------------------------------
-- 3. Категория товара во времени.
--
--    Именно здесь «вброс» про смену категории: у товара была категория A,
--    продавец перевел его в категорию B, и с этой даты новые заказы считаются
--    по B, а прежние месяцы должны остаться в A.
--
--    В снимке у товара ровно одна категория, поэтому версия одна. Дата
--    начала — дата первой продажи товара.
-- ---------------------------------------------------------------------
create table core.dim_product_category_history (
    product_id       text    not null,
    category_id      text    not null,
    display_category text    not null,
    valid_from       date    not null,
    valid_to         date    not null,
    is_current       boolean not null,
    primary key (product_id, valid_from)
);

insert into core.dim_product_category_history
select p.product_id,
       p.category_id,
       p.display_category,
       coalesce(f.first_sale,
                (select min(calendar_date) from core.dim_calendar)) as valid_from,
       date '9999-12-31' as valid_to,
       true as is_current
from core.dim_product p
left join (
        select i.product_id, min(o.purchased_at)::date as first_sale
        from core.fact_order_item i
        join core.fact_order o on o.order_id = i.order_id
        where i.product_id is not null
        group by i.product_id
     ) f on f.product_id = p.product_id;

-- Позиция заказа и категория ТОВАРА на дату этого заказа. Именно так надо
-- соединять отчёты по категориям, когда версий станет больше одной.
create or replace view core.v_item_category_as_ordered as
select i.order_id,
       i.order_item_id,
       i.seller_id,
       i.product_id,
       h.category_id,
       h.display_category,
       i.price
from core.fact_order_item i
join core.fact_order fo      on fo.order_id = i.order_id
join core.dim_product_category_history h
  on  h.product_id = i.product_id
  and fo.purchased_at::date between h.valid_from and h.valid_to;

create index idx_history_customer_valid on core.dim_customer_history (customer_unique_id, valid_from);
create index idx_history_product_valid  on core.dim_product_category_history (product_id, valid_from);
create index idx_history_seller_valid   on core.dim_seller_history (seller_id, valid_from);

analyze core.dim_customer_history;
analyze core.dim_product_category_history;
analyze core.dim_seller_history;


-- =====================================================================
--  Демонстрации: как к этим таблицам обращаться и что они дают
-- =====================================================================

select '=== история: сколько версий ===' as demo;
select 'покупатели' as object,
       count(distinct customer_unique_id) as объектов,
       count(*)                           as версий,
       count(case when is_current then 1 end) as действующих
from core.dim_customer_history
union all
select 'продавцы', count(distinct seller_id), count(*), count(case when is_current then 1 end)
from core.dim_seller_history
union all
select 'товары (категории)', count(distinct product_id), count(*), count(case when is_current then 1 end)
from core.dim_product_category_history;


-- Люди, у которых адрес менялся: для каждого заказа показываем адрес из
-- версии на дату заказа и адрес из текущей записи. У заказов, оформленных
-- до переезда, они различаются — это и есть ответ на «адрес на момент заказа».
select '=== переезды: адрес на момент заказа против текущего ===' as demo;
select a.order_id,
       a.order_date,
       a.customer_state             as state_at_order,
       a.customer_city              as city_at_order,
       c.customer_state             as state_now,
       c.customer_city              as city_now
from core.v_order_customer_address a
join core.fact_order fo      on fo.order_id = a.order_id
join core.dim_customer c     on c.customer_id = fo.customer_id
where coalesce(a.customer_state, '') <> coalesce(c.customer_state, '')
   or coalesce(a.customer_city, '')  <> coalesce(c.customer_city, '')
order by a.customer_unique_id, a.order_date
limit 10;


-- Выручка по категориям, посчитанная через историю (категория берётся на дату
-- заказа). Сегодня версии единственные, поэтому суммы должны совпасть с
-- ответом на вопрос 5: это проверка, что соединение по дате ничего не теряет
-- и не раздувает строки. Итоги сверяет 07_checks_b.sql.
select '=== категории через историю: топ-5 ===' as demo;
select h.display_category,
       round(sum(i.price), 2) as revenue_via_history
from core.fact_order_item i
join core.fact_order fo on fo.order_id = i.order_id
join core.dim_product_category_history h
  on  h.product_id = i.product_id
  and fo.purchased_at::date between h.valid_from and h.valid_to
where i.is_revenue
group by h.display_category
order by revenue_via_history desc
limit 5;
