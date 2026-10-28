-- =====================================================================
--  Модель данных Capibara целиком, одним файлом.
--
--  Файл собран скриптом model/make_all_in_one.sh из четырёх шагов:
--    01_core.sql     -> схема core (факты и измерения) из raw
--    02_mart.sql     -> представления mart
--    03_answers.sql  -> ответы на 10 вопросов (блоки А и Б)
--    04_checks.sql   -> 15 проверок целостности и проба вброса
--
--  Запуск:  psql -f model/all_in_one.sql
--           или docker compose exec -T postgres psql -U hack -d marketplace < model/all_in_one.sql
--  Перед каждым шагом свои таблицы удаляются, поэтому запуск
--  повторять можно, результат каждый раз один и тот же.
-- =====================================================================

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 01_core.sql
-- =====================================================================
--  Модель данных Capibara. Схема core.
--
--  Запускать после scripts/load_raw.py.
--  Скрипт можно запускать много раз подряд: он сначала удаляет свои
--  таблицы, потом создаёт их заново и наполняет из raw.
--
--  Правила, которых тут держимся:
--
--  1. raw не меняем. Всё читаем оттуда и приводим типы уже здесь.
--
--  2. В raw всё лежит текстом, даже даты и деньги. Поэтому почти в каждой
--     строке написано nullif(btrim(x), '')::numeric или ::timestamp.
--     btrim убирает пробелы, nullif превращает пустую строку в null,
--     а приведение типа уже не падает.
--
--  3. Выручка = сумма price по заказам со статусом delivered.
--     Без стоимости доставки. Почему так — расписано в NOTES.md.
--     Флаг is_revenue стоит в fact_order, чтобы аналитику не пришлось
--     самому помнить, какие статусы считать.
--
--  4. Уровень (зерно) таблиц записан прямо в названии и в комментарии:
--     одна строка в fact_order = один заказ,
--     одна строка в fact_order_item = один товар одного продавца в заказе.
--
--  5. История изменений (вброс): категория товара и адрес покупателя
--     хранятся версиями (SCD2, valid_from / valid_to). Сами изменения
--     пишутся в журнал в схеме changelog, которую этот скрипт НЕ удаляет:
--     пересборка из raw заново проигрывает журнал, и история не теряется.
-- =====================================================================

drop table if exists core.fact_order_item cascade;
drop table if exists core.fact_payment cascade;
drop table if exists core.fact_review cascade;
drop table if exists core.fact_order cascade;
drop table if exists core.dim_calendar cascade;
drop table if exists core.dim_category cascade;
drop table if exists core.dim_product_category_hist cascade;
drop table if exists core.dim_product cascade;
drop table if exists core.dim_seller cascade;
drop table if exists core.dim_customer_address cascade;
drop table if exists core.dim_customer cascade;
drop table if exists core.dim_order_status cascade;

-- схемы создаём здесь, чтобы файл работал и на базе, где их ещё нет
-- (обычно их делает scripts/load_raw.py, но нам важно запускаться самим)
create schema if not exists core;
create schema if not exists mart;
create schema if not exists changelog;


-- ---------------------------------------------------------------------
-- changelog — журнал изменений, которых нет в raw.
--
-- raw — это снимок на момент выгрузки, в нём нет ни смены категорий,
-- ни переездов. Поэтому изменения приходят отдельно и складываются сюда,
-- по строке на событие. Таблицы создаются через if not exists и никогда
-- не удаляются: core пересобирается с нуля, а журнал остаётся, и история
-- версий каждый раз восстанавливается из raw + журнала одинаково.
--
-- Писать в журнал руками не нужно: функции changelog.change_product_category
-- и changelog.move_customer (в конце файла) пишут событие и сразу же
-- обновляют версии в core.
-- ---------------------------------------------------------------------
create table if not exists changelog.product_category_change (
    change_id    bigserial primary key,
    product_id   text not null,
    category_id  text not null,          -- новая категория (португальское имя)
    changed_at   timestamp not null,     -- с какого момента действует
    recorded_at  timestamp not null default now(),
    comment      text
);

create table if not exists changelog.customer_move (
    move_id            bigserial primary key,
    customer_unique_id text not null,
    customer_city      text,
    customer_state     text,
    zip_code_prefix    text,
    moved_at           timestamp not null,   -- с какого момента новый адрес
    recorded_at        timestamp not null default now()
);


-- ---------------------------------------------------------------------
-- dim_order_status — справочник статусов заказа.
--
-- Здесь один раз решено, какой статус считается выручкой. Дальше по модели
-- везде ходит флаг is_revenue, а не список статусов. Если бизнес решит
-- считать выручку в момент отгрузки, менять придётся только это место.
-- ---------------------------------------------------------------------
create table core.dim_order_status (
    order_status text primary key,
    status_group text not null,
    is_revenue   boolean not null
);

insert into core.dim_order_status (order_status, status_group, is_revenue)
select distinct
       o.order_status,
       case
           when o.order_status = 'delivered' then 'дошёл до покупателя'
           when o.order_status in ('canceled', 'unavailable') then 'не состоялся'
           else 'в пути или в обработке'
       end,
       o.order_status = 'delivered'
from raw.orders o
order by 1;


-- ---------------------------------------------------------------------
-- dim_customer — покупатель.
--
-- В raw.customers два идентификатора, и это не дубли:
--   customer_id        — id одного ЗАКАЗА-покупателя, у каждой покупки свой;
--   customer_unique_id — id самого ЧЕЛОВЕКА, он повторяется при повторных
--                        покупках (99 441 строк, но только 96 096 уникальных).
-- Поэтому ключом измерения оставляем customer_id (он соответствует заказу),
-- а customer_unique_id храним как атрибут — по нему считаем людей и возвраты.
-- ---------------------------------------------------------------------
create table core.dim_customer (
    customer_id        text primary key,
    customer_unique_id text not null,
    customer_city      text,
    customer_state     text,
    zip_code_prefix    text
);

insert into core.dim_customer
select distinct
       c.customer_id,
       c.customer_unique_id,
       nullif(btrim(c.customer_city), ''),
       nullif(btrim(c.customer_state), ''),
       nullif(btrim(c.customer_zip_code_prefix), '')
from raw.customers c;


-- ---------------------------------------------------------------------
-- dim_customer_address — адрес человека (customer_unique_id) версиями.
-- Одна строка = один период, когда человек жил по одному адресу.
--
-- В raw адрес записан на каждый заказ отдельно (через customer_id), так что
-- переезды в данных уже есть: у 252 человек между заказами меняется адрес.
-- Складываем в одну ленту события «заказ с таким-то адресом» и «переезд»
-- из журнала, сортируем по времени и склеиваем подряд идущие одинаковые
-- адреса в одну версию. Версия действует с valid_from до valid_to
-- (полуинтервал, у текущей valid_to = infinity).
--
-- Заказ получает address_sk той версии, в которую попало его событие,
-- поэтому адрес в заказе — всегда адрес на момент заказа, и следующий
-- переезд его не перепишет. Связку заказ -> версия держим во временной
-- таблице address_event: по ней же строится fact_order.
--
-- Мелочь: у 290 человек по два заказа в одну и ту же секунду. Если адреса
-- у них разные, первая версия получается нулевой длины (valid_from = valid_to),
-- но заказ всё равно привязан к ней по ключу, а не по датам.
-- ---------------------------------------------------------------------
drop table if exists pg_temp.address_event;

create temp table address_event as
with ev as (
    select cu.customer_unique_id,
           cu.customer_city,
           cu.customer_state,
           cu.zip_code_prefix,
           nullif(btrim(o.order_purchase_timestamp), '')::timestamp as event_at,
           'order'::text      as source,
           o.order_id,
           null::bigint       as move_id
    from raw.orders o
    join core.dim_customer cu on cu.customer_id = o.customer_id
    union all
    select m.customer_unique_id,
           nullif(btrim(m.customer_city), ''),
           nullif(btrim(m.customer_state), ''),
           nullif(btrim(m.zip_code_prefix), ''),
           m.moved_at,
           'move',
           null,
           m.move_id
    from changelog.customer_move m
),
ordered as (
    select ev.*,
           row_number() over w as rn,
           -- новая версия начинается, если адрес отличается от предыдущего события
           case when row_number() over w = 1 then 1
                when customer_city   is not distinct from lag(customer_city)   over w
                 and customer_state  is not distinct from lag(customer_state)  over w
                 and zip_code_prefix is not distinct from lag(zip_code_prefix) over w
                then 0 else 1
           end as is_new
    from ev
    window w as (partition by customer_unique_id order by event_at, order_id, move_id)
)
select o.*,
       sum(is_new) over (partition by customer_unique_id order by rn)::integer as version
from ordered o;

create table core.dim_customer_address (
    address_sk         bigint primary key,   -- суррогатный ключ версии
    customer_unique_id text not null,
    version            integer not null,     -- 1, 2, 3... внутри человека
    customer_city      text,
    customer_state     text,
    zip_code_prefix    text,
    valid_from         timestamp not null,
    valid_to           timestamp not null,
    is_current         boolean not null,
    source             text not null,        -- откуда версия: order или move
    unique (customer_unique_id, version)
);

insert into core.dim_customer_address
select row_number() over (order by v.customer_unique_id, v.version),
       v.customer_unique_id,
       v.version,
       v.customer_city,
       v.customer_state,
       v.zip_code_prefix,
       v.valid_from,
       coalesce(lead(v.valid_from) over w, timestamp 'infinity'),
       lead(v.valid_from) over w is null,
       v.source
from (
    select customer_unique_id,
           version,
           customer_city,
           customer_state,
           zip_code_prefix,
           min(event_at)                        as valid_from,
           (array_agg(source order by rn))[1]   as source
    from address_event
    group by customer_unique_id, version, customer_city, customer_state, zip_code_prefix
) v
window w as (partition by v.customer_unique_id order by v.version);


-- ---------------------------------------------------------------------
-- dim_seller — продавец. Ключ seller_id, в raw он уникальный.
-- Город и штат храним как есть. Это простая версия без историчности:
-- если продавец переедет, старые отчёты пересчитаются по новому городу.
-- ---------------------------------------------------------------------
create table core.dim_seller (
    seller_id         text primary key,
    seller_city       text,
    seller_state      text,
    zip_code_prefix   text
);

insert into core.dim_seller
select distinct
       s.seller_id,
       nullif(btrim(s.seller_city), ''),
       nullif(btrim(s.seller_state), ''),
       nullif(btrim(s.seller_zip_code_prefix), '')
from raw.sellers s;


-- ---------------------------------------------------------------------
-- dim_category — категории товаров.
--
-- Категории в данных на португальском, перевод лежит в отдельном файле,
-- и у двух категорий перевода нет. Плюс у 610 товаров категории нет вовсе.
--
-- Ключом оставляем португальское имя (оно есть в карточках товаров),
-- а английское — атрибут. Название для отчётов берём английское, а если
-- перевода нет — португальское, но не сваливаем непереведённые категории
-- в одну кучу: иначе из отчёта пропадают две категории, хотя товары
-- этих категорий продаются.
-- ---------------------------------------------------------------------
create table core.dim_category (
    category_id    text primary key,   -- португальское имя категории
    name_portuguese text,
    name_english    text,
    display_name    text not null      -- как показывать в отчётах
);

insert into core.dim_category (category_id, name_portuguese, name_english, display_name)
select p.category_name,
       p.category_name,
       t.product_category_name_english,
       coalesce(t.product_category_name_english, p.category_name) as display_name
from (
    -- все категории, которые встретились в карточках товаров,
    -- пустую категорию показываем одной строкой not_available
    select distinct coalesce(nullif(btrim(pr.product_category_name), ''), 'not_available') as category_name
    from raw.products pr
) p
left join raw.product_category_translation t
       on t.product_category_name = p.category_name;


-- ---------------------------------------------------------------------
-- dim_product_category_hist — категория товара версиями.
-- Одна строка = один период, когда товар был в одной категории.
--
-- Первая версия — категория из raw, она действует с -infinity: до первой
-- смены товар всегда был в ней. Каждая запись журнала
-- changelog.product_category_change открывает новую версию и закрывает
-- предыдущую. Позиция заказа берёт ту версию, которая действовала в момент
-- покупки, поэтому смена категории не переписывает прошлые отчёты.
-- ---------------------------------------------------------------------
create table core.dim_product_category_hist (
    product_id       text not null,
    version          integer not null,
    category_id      text not null,
    display_category text not null,
    valid_from       timestamp not null,
    valid_to         timestamp not null,
    is_current       boolean not null,
    primary key (product_id, version)
);

insert into core.dim_product_category_hist
select e.product_id,
       row_number() over w,
       e.category_id,
       coalesce(c.display_name, e.category_id),
       e.valid_from,
       coalesce(lead(e.valid_from) over w, timestamp 'infinity'),
       lead(e.valid_from) over w is null
from (
    select pr.product_id,
           coalesce(nullif(btrim(pr.product_category_name), ''), 'not_available') as category_id,
           timestamp '-infinity' as valid_from,
           0::bigint             as change_id
    from raw.products pr
    union all
    -- журнал по товару, которого нет в raw, пропускаем: версии не к чему крепить
    select ch.product_id, ch.category_id, ch.changed_at, ch.change_id
    from changelog.product_category_change ch
    where exists (select 1 from raw.products pr where pr.product_id = ch.product_id)
) e
left join core.dim_category c on c.category_id = e.category_id
window w as (partition by e.product_id order by e.valid_from, e.change_id);


-- ---------------------------------------------------------------------
-- dim_product — карточка товара.
--
-- Категории может не быть, тогда ведём товар в категорию not_available,
-- чтобы он не потерялся из отчёта по категориям.
-- Категория здесь — ТЕКУЩАЯ (последняя версия из dim_product_category_hist).
-- Для отчётов по прошлым периодам категорию берём не отсюда, а из позиции
-- заказа: там она на момент покупки.
-- ---------------------------------------------------------------------
create table core.dim_product (
    product_id       text primary key,
    category_id      text not null,
    display_category text not null,
    photos_qty       integer,
    weight_g         numeric(12,2),
    length_cm        numeric(12,2),
    height_cm        numeric(12,2),
    width_cm         numeric(12,2)
);

insert into core.dim_product
select pr.product_id,
       h.category_id,
       h.display_category,
       nullif(btrim(pr.product_photos_qty), '')::integer,
       nullif(btrim(pr.product_weight_g), '')::numeric,
       nullif(btrim(pr.product_length_cm), '')::numeric,
       nullif(btrim(pr.product_height_cm), '')::numeric,
       nullif(btrim(pr.product_width_cm), '')::numeric
from raw.products pr
join core.dim_product_category_hist h
  on h.product_id = pr.product_id
 and h.is_current;


-- ---------------------------------------------------------------------
-- dim_calendar — календарь по дням.
--
-- Нужен, чтобы в отчётах не терялись месяцы, в которых заказов не было.
-- В наших данных в ноябре 2016 нет ни одного заказа, и обычная
-- группировка заказов этот месяц просто не покажет: отчёт даст 23 строки
-- вместо 24. Отчёт строим от календаря, тогда месяц на месте и с нулями.
-- ---------------------------------------------------------------------
create table core.dim_calendar (
    calendar_date date primary key,
    year          integer not null,
    month         integer not null,
    month_start   date not null,
    is_month_start boolean not null
);

insert into core.dim_calendar
select d::date,
       extract(year from d)::integer,
       extract(month from d)::integer,
       date_trunc('month', d)::date,
       d::date = date_trunc('month', d)::date
from (
    select generate_series(
        (select min(nullif(btrim(order_purchase_timestamp), '')::timestamp) from raw.orders)::date,
        (select max(nullif(btrim(order_purchase_timestamp), '')::timestamp) from raw.orders)::date,
        interval '1 day'
    ) as d
) days;


-- ---------------------------------------------------------------------
-- fact_order — заказ целиком. Одна строка = один заказ.
--
-- Сюда стекаются суммы со всех позиций заказа, поэтому чек считается
-- правильно: чек — свойство заказа, а не строчки в нём.
--
-- Заказов без позиций 775 (это в основном отменённые и unavailable),
-- они остаются в таблице с нулями: заказ был, товаров он не принёс.
--
-- Адрес покупателя — на момент заказа: address_sk указывает на версию
-- из dim_customer_address, город и штат этой версии лежат рядом, чтобы
-- отчётам по штатам не нужен был лишний join. Переезд после заказа
-- открывает новую версию и этот заказ не трогает.
-- ---------------------------------------------------------------------
create table core.fact_order (
    order_id            text primary key,
    customer_id         text,
    customer_unique_id  text,
    address_sk          bigint,
    customer_city       text,
    customer_state      text,
    order_status        text,
    is_revenue          boolean not null,
    purchased_at        timestamp,
    approved_at         timestamp,
    carrier_at          timestamp,
    delivered_at        timestamp,
    estimated_delivery_date date,
    month_start         date,
    items_count         integer not null default 0,
    goods_total         numeric(14,2) not null default 0,
    freight_total       numeric(14,2) not null default 0,
    order_total         numeric(14,2) not null default 0,
    paid_total          numeric(14,2) not null default 0,
    payment_types       text,
    max_installments    integer,
    review_score_avg    numeric(4,2),
    delivery_days       integer,
    is_delayed          boolean
);

insert into core.fact_order
select o.order_id,
       o.customer_id,
       cu.customer_unique_id,
       ad.address_sk,
       ad.customer_city,
       ad.customer_state,
       o.order_status,
       st.is_revenue,
       nullif(btrim(o.order_purchase_timestamp), '')::timestamp,
       nullif(btrim(o.order_approved_at), '')::timestamp,
       nullif(btrim(o.order_delivered_carrier_date), '')::timestamp,
       nullif(btrim(o.order_delivered_customer_date), '')::timestamp,
       nullif(btrim(o.order_estimated_delivery_date), '')::date,
       date_trunc('month', nullif(btrim(o.order_purchase_timestamp), '')::timestamp)::date,
       coalesce(i.items_count, 0),
       coalesce(i.goods_total, 0),
       coalesce(i.freight_total, 0),
       coalesce(i.goods_total, 0) + coalesce(i.freight_total, 0),
       coalesce(p.paid_total, 0),
       p.payment_types,
       p.max_installments,
       r.review_score_avg,
       case when nullif(btrim(o.order_delivered_customer_date), '')::timestamp is not null
            then nullif(btrim(o.order_delivered_customer_date), '')::timestamp::date
                 - nullif(btrim(o.order_purchase_timestamp), '')::timestamp::date
       end,
       case when nullif(btrim(o.order_delivered_customer_date), '')::timestamp is not null
                 and nullif(btrim(o.order_estimated_delivery_date), '')::date is not null
            then (nullif(btrim(o.order_delivered_customer_date), '')::timestamp)::date
                 > nullif(btrim(o.order_estimated_delivery_date), '')::date
       end
from raw.orders o
left join core.dim_order_status st on st.order_status = o.order_status
left join core.dim_customer cu      on cu.customer_id = o.customer_id
left join address_event ae          on ae.order_id = o.order_id
left join core.dim_customer_address ad
       on ad.customer_unique_id = ae.customer_unique_id
      and ad.version = ae.version
left join (
        select order_id,
               count(*) as items_count,
               sum(nullif(btrim(price), '')::numeric) as goods_total,
               sum(nullif(btrim(freight_value), '')::numeric) as freight_total
        from raw.order_items
        group by order_id
     ) i on i.order_id = o.order_id
left join (
        select order_id,
               sum(nullif(btrim(payment_value), '')::numeric) as paid_total,
               string_agg(distinct payment_type, ', ') as payment_types,
               max(nullif(btrim(payment_installments), '')::integer) as max_installments
        from raw.order_payments
        group by order_id
     ) p on p.order_id = o.order_id
left join (
        select order_id,
               round(avg(nullif(btrim(review_score), '')::numeric), 2) as review_score_avg
        from raw.order_reviews
        group by order_id
     ) r on r.order_id = o.order_id;


-- ---------------------------------------------------------------------
-- fact_order_item — позиции заказа. Одна строка = один товар одного
-- продавца в одном заказе. Ключ (order_id, order_item_id): сам по себе
-- order_item_id — это просто порядковый номер внутри заказа, он повторяется
-- в разных заказах, поэтому ключ только парный.
--
-- Числа qty здесь нет: в выгрузке одна строка = одна единица товара,
-- поэтому units всегда равен числу строк. Это ограничение данных,
-- отличить «два одинаковых товара в одной строке» от «одного» нельзя.
--
-- is_revenue копируем из заказа, чтобы выручку продавца можно было считать
-- одной строкой и не забывать отсекать несостоявшиеся заказы.
--
-- Категория — на момент покупки: берём ту версию из
-- dim_product_category_hist, в интервал которой попал purchased_at.
-- Если продавец потом сменит категорию, эта позиция останется в старой,
-- и отчёт по категориям за прошлые месяцы не изменится.
-- ---------------------------------------------------------------------
create table core.fact_order_item (
    order_id          text not null,
    order_item_id     integer not null,
    seller_id         text,
    product_id        text,
    customer_id       text,
    customer_unique_id text,
    seller_city       text,
    seller_state      text,
    category_id       text,
    display_category  text,
    purchased_at      timestamp,
    month_start       date,
    price             numeric(12,2) not null,
    freight_value     numeric(12,2) not null default 0,
    item_total        numeric(12,2) not null,
    shipping_limit_date timestamp,
    is_revenue        boolean not null,
    primary key (order_id, order_item_id)
);

insert into core.fact_order_item
select i.order_id,
       nullif(btrim(i.order_item_id), '')::integer,
       i.seller_id,
       i.product_id,
       o.customer_id,
       cu.customer_unique_id,
       s.seller_city,
       s.seller_state,
       coalesce(h.category_id, 'not_available'),
       coalesce(h.display_category, 'not_available'),
       nullif(btrim(o.order_purchase_timestamp), '')::timestamp,
       date_trunc('month', nullif(btrim(o.order_purchase_timestamp), '')::timestamp)::date,
       coalesce(nullif(btrim(i.price), '')::numeric, 0),
       coalesce(nullif(btrim(i.freight_value), '')::numeric, 0),
       coalesce(nullif(btrim(i.price), '')::numeric, 0)
         + coalesce(nullif(btrim(i.freight_value), '')::numeric, 0),
       nullif(btrim(i.shipping_limit_date), '')::timestamp,
       fo.is_revenue
from raw.order_items i
join raw.orders o            on o.order_id = i.order_id
left join core.dim_customer cu on cu.customer_id = o.customer_id
left join raw.sellers s       on s.seller_id = i.seller_id
left join core.dim_product_category_hist h
       on h.product_id = i.product_id
      and nullif(btrim(o.order_purchase_timestamp), '')::timestamp >= h.valid_from
      and nullif(btrim(o.order_purchase_timestamp), '')::timestamp <  h.valid_to
left join core.fact_order fo  on fo.order_id = i.order_id;


-- ---------------------------------------------------------------------
-- fact_payment — платежи. Одна строка = один способ оплаты одного заказа.
-- Заказ могут оплатить сразу несколькими способами, их различает
-- payment_sequential, поэтому ключ парный (order_id, payment_sequential).
-- ---------------------------------------------------------------------
create table core.fact_payment (
    order_id           text not null,
    payment_sequential integer not null,
    payment_type       text,
    installments       integer,
    payment_value      numeric(12,2) not null default 0,
    month_start        date,
    is_revenue         boolean not null,
    primary key (order_id, payment_sequential)
);

insert into core.fact_payment
select p.order_id,
       nullif(btrim(p.payment_sequential), '')::integer,
       p.payment_type,
       nullif(btrim(p.payment_installments), '')::integer,
       coalesce(nullif(btrim(p.payment_value), '')::numeric, 0),
       date_trunc('month', nullif(btrim(o.order_purchase_timestamp), '')::timestamp)::date,
       coalesce(st.is_revenue, false)
from raw.order_payments p
left join raw.orders o             on o.order_id = p.order_id
left join core.dim_order_status st on st.order_status = o.order_status;


-- ---------------------------------------------------------------------
-- fact_review — отзывы.
--
-- Тут два сюрприза в данных:
--   a) review_id НЕ уникален: один и тот же review_id встречается на двух
--      разных заказах (814 таких строк). Видимо, так ids поменяли при
--      обезличивании. Значит ключом review_id быть не может,
--      ключ (order_id, review_id).
--   b) на один заказ бывает 2-3 отзыва (547 таких заказов).
-- Поэтому в fact_review одна строка = один отзыв, а средний балл заказа
-- считаем отдельно и округляем до двух знаков.
-- ---------------------------------------------------------------------
create table core.fact_review (
    order_id     text not null,
    review_id    text not null,
    review_score integer,
    has_comment  boolean not null default false,
    created_at   timestamp,
    month_start  date,
    primary key (order_id, review_id)
);

insert into core.fact_review
select r.order_id,
       r.review_id,
       min(nullif(btrim(r.review_score), '')::integer),
       -- был ли хоть один текстовый отзыв: max по 1/0 и сравнение с 1
       max(case when nullif(btrim(r.review_comment_message), '') is not null
                then 1 else 0 end) = 1,
       min(nullif(btrim(r.review_creation_date), '')::timestamp),
       date_trunc('month', min(nullif(btrim(r.review_creation_date), '')::timestamp))::date
from raw.order_reviews r
-- дубли review_id на одном и том же заказе просто склеиваем в одну строку:
-- group by делает ровно то, что нужно, и ключ (order_id, review_id) становится уникальным
group by r.order_id, r.review_id;


-- индексы, чтобы отчёты считались быстро
create index idx_fact_order_month    on core.fact_order (month_start);
create index idx_fact_order_unique   on core.fact_order (customer_unique_id);
create index idx_fact_item_seller    on core.fact_order_item (seller_id);
create index idx_fact_item_category  on core.fact_order_item (category_id);
create index idx_fact_item_month     on core.fact_order_item (month_start);
create index idx_review_score        on core.fact_review (review_score);
create index idx_fact_order_state    on core.fact_order (customer_state);
create index idx_fact_item_product   on core.fact_order_item (product_id);
create index idx_address_current     on core.dim_customer_address (customer_unique_id) where is_current;

analyze core.fact_order;
analyze core.fact_order_item;
analyze core.fact_payment;
analyze core.fact_review;
analyze core.dim_customer;
analyze core.dim_customer_address;
analyze core.dim_product;
analyze core.dim_product_category_hist;
analyze core.dim_calendar;


-- ---------------------------------------------------------------------
-- Как вносить изменения (вброс): две функции.
--
--   select changelog.change_product_category('<product_id>', '<категория>', '2018-09-01');
--   select changelog.move_customer('<customer_unique_id>', 'rio de janeiro', 'RJ', '20000', '2018-09-01');
--
-- Обе делают одно и то же: пишут событие в журнал, закрывают текущую
-- версию (valid_to = момент изменения) и открывают новую. Факты прошлых
-- периодов не трогают. Пересборка 01_core.sql проигрывает тот же журнал
-- и приходит ровно к тем же версиям.
--
-- Изменение задним числом (раньше начала текущей версии) не принимаем:
-- оно переписало бы уже сданную историю. Если такое правда нужно —
-- это осознанная правка журнала и пересборка, а не вызов функции.
-- ---------------------------------------------------------------------
create or replace function changelog.change_product_category(
    p_product_id  text,
    p_category_id text,
    p_changed_at  timestamp default now()::timestamp,
    p_comment     text default null
) returns void
language plpgsql as $$
declare
    v_display text;
    v_cur     core.dim_product_category_hist%rowtype;
begin
    select display_name into v_display
    from core.dim_category
    where category_id = p_category_id;
    if not found then
        raise exception 'категории % нет в core.dim_category', p_category_id;
    end if;

    select * into v_cur
    from core.dim_product_category_hist
    where product_id = p_product_id and is_current;
    if not found then
        raise exception 'товара % нет в core.dim_product_category_hist', p_product_id;
    end if;
    if p_changed_at <= v_cur.valid_from then
        raise exception 'изменение задним числом: % раньше начала текущей версии (%)',
            p_changed_at, v_cur.valid_from;
    end if;

    insert into changelog.product_category_change (product_id, category_id, changed_at, comment)
    values (p_product_id, p_category_id, p_changed_at, p_comment);

    update core.dim_product_category_hist
       set valid_to = p_changed_at, is_current = false
     where product_id = p_product_id and version = v_cur.version;

    insert into core.dim_product_category_hist
    values (p_product_id, v_cur.version + 1, p_category_id, v_display,
            p_changed_at, timestamp 'infinity', true);

    update core.dim_product
       set category_id = p_category_id, display_category = v_display
     where product_id = p_product_id;

    -- позиции, купленные уже после изменения, относятся к новой версии
    -- (на исторических данных таких нет, но функция должна быть честной)
    update core.fact_order_item
       set category_id = p_category_id, display_category = v_display
     where product_id = p_product_id and purchased_at >= p_changed_at;
end;
$$;


create or replace function changelog.move_customer(
    p_customer_unique_id text,
    p_city               text,
    p_state              text,
    p_zip_code_prefix    text,
    p_moved_at           timestamp default now()::timestamp
) returns void
language plpgsql as $$
declare
    v_cur core.dim_customer_address%rowtype;
begin
    select * into v_cur
    from core.dim_customer_address
    where customer_unique_id = p_customer_unique_id and is_current;
    if not found then
        raise exception 'покупателя % нет в core.dim_customer_address', p_customer_unique_id;
    end if;
    -- valid_from текущей версии не раньше последнего заказа человека,
    -- поэтому проверка заодно гарантирует, что после переезда заказов нет
    if p_moved_at <= v_cur.valid_from then
        raise exception 'переезд задним числом: % раньше начала текущей версии (%)',
            p_moved_at, v_cur.valid_from;
    end if;

    -- приводим как при пересборке: пустая строка = null
    p_city            := nullif(btrim(p_city), '');
    p_state           := nullif(btrim(p_state), '');
    p_zip_code_prefix := nullif(btrim(p_zip_code_prefix), '');

    -- тот же адрес пересборка склеила бы с текущей версией, поэтому
    -- и здесь новой версии не открываем
    if p_city            is not distinct from v_cur.customer_city
       and p_state           is not distinct from v_cur.customer_state
       and p_zip_code_prefix is not distinct from v_cur.zip_code_prefix then
        raise exception 'адрес покупателя % не изменился', p_customer_unique_id;
    end if;

    insert into changelog.customer_move
        (customer_unique_id, customer_city, customer_state, zip_code_prefix, moved_at)
    values (p_customer_unique_id, p_city, p_state, p_zip_code_prefix, p_moved_at);

    update core.dim_customer_address
       set valid_to = p_moved_at, is_current = false
     where address_sk = v_cur.address_sk;

    insert into core.dim_customer_address
    values ((select max(address_sk) + 1 from core.dim_customer_address),
            p_customer_unique_id, v_cur.version + 1,
            p_city, p_state, p_zip_code_prefix,
            p_moved_at, timestamp 'infinity', true, 'move');
end;
$$;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 02_mart.sql
-- =====================================================================
--  Витрины в схеме mart. Это простые взгляды (view) поверх tables core.
--
--  Смотреть сюда удобно, а считать что-то новое всё равно можно прямо
--  из core: витрины нужны только для частых вопросов, чтобы не писать
--  одни и те же join-ы заново.
--
--  Во всех витринах выручка = goods_total / price, то есть только товары,
--  и только по заказам с is_revenue = true (статус delivered).
-- =====================================================================

drop view if exists mart.v_monthly_revenue;
drop view if exists mart.v_seller_revenue;
drop view if exists mart.v_category_revenue;
drop view if exists mart.v_customer_base;
drop view if exists mart.v_delivery_month;
drop view if exists mart.v_payment_mix;
drop view if exists mart.v_order_status;
drop view if exists mart.v_delivery_state;


-- Выручка и заказы по месяцам. Считаем ОТ календаря, а не от заказов:
-- так остаётся строка для месяца, в котором заказов не было (ноябрь 2016).
create view mart.v_monthly_revenue as
select cal.month_start,
       count(fo.order_id)                          as orders,
       coalesce(sum(fo.goods_total), 0)            as revenue,
       coalesce(sum(fo.freight_total), 0)          as freight,
       coalesce(sum(fo.order_total), 0)            as revenue_with_freight
from (select distinct month_start from core.dim_calendar) cal
left join core.fact_order fo
       on fo.month_start = cal.month_start
      and fo.is_revenue
group by cal.month_start;


-- Выручка продавца. Считаем по позициям, потому что в один заказ могут
-- положить товары разных продавцов: заказ целиком принадлежит только одному
-- продавцу, если он там один, а так каждый получает свою часть.
create view mart.v_seller_revenue as
select i.seller_id,
       max(s.seller_city)  as seller_city,
       max(s.seller_state) as seller_state,
       count(distinct i.order_id) as orders,
       count(*)                   as units,
       sum(i.price)               as revenue
from core.fact_order_item i
left join core.dim_seller s on s.seller_id = i.seller_id
where i.is_revenue
group by i.seller_id;


-- Выручка по категориям. Категория есть у каждой позиции: у товаров без
-- категории стоит not_available, поэтому сумма по категориям равна общей
-- выручке и ничего не теряется.
create view mart.v_category_revenue as
select i.display_category,
       count(distinct i.order_id) as orders,
       count(*)                   as units,
       sum(i.price)               as revenue
from core.fact_order_item i
where i.is_revenue
group by i.display_category;


-- Покупатели: одна строка = один человек (customer_unique_id), а не заказ.
create view mart.v_customer_base as
select cu.customer_unique_id,
       min(fo.purchased_at)::date              as first_order_date,
       max(fo.purchased_at)::date              as last_order_date,
       count(distinct fo.order_id)             as orders_total,
       count(distinct case when fo.is_revenue then fo.order_id end) as orders_revenue,
       coalesce(sum(case when fo.is_revenue then fo.goods_total else 0 end), 0) as revenue,
       max(ad.customer_city)                   as customer_city,
       max(ad.customer_state)                  as customer_state
from core.dim_customer cu
join core.fact_order fo on fo.customer_id = cu.customer_id
-- город и штат — ТЕКУЩИЙ адрес человека (последняя версия), а не
-- случайный из его заказов: адрес на момент заказа лежит в fact_order
left join core.dim_customer_address ad
       on ad.customer_unique_id = cu.customer_unique_id
      and ad.is_current
group by cu.customer_unique_id;


-- Доставка по месяцам: сколько заказов привезли позже обещанного срока.
create view mart.v_delivery_month as
select fo.month_start,
       count(*)                                            as delivered_orders,
       count(case when fo.is_delayed then 1 end)           as delayed_orders,
       round(100.0 * count(case when fo.is_delayed then 1 end) / nullif(count(*), 0), 2) as delayed_pct,
       round(avg(fo.delivery_days)::numeric, 2)            as avg_delivery_days,
       round(avg(fo.review_score_avg), 2)                  as avg_review_score
from core.fact_order fo
where fo.is_revenue
group by fo.month_start;


-- Способы оплаты по месяцам.
create view mart.v_payment_mix as
select p.month_start,
       p.payment_type,
       count(distinct p.order_id) as orders,
       sum(p.payment_value)       as paid
from core.fact_payment p
where p.is_revenue
group by p.month_start, p.payment_type;


-- Воронка статусов: все заказы, в любом статусе. Сколько из них
-- без единой позиции — отдельной колонкой (это в основном unavailable
-- и canceled: заказ создан, а товара так и не оказалось).
create view mart.v_order_status as
select st.order_status,
       st.status_group,
       st.is_revenue,
       count(fo.order_id)                              as orders,
       count(case when fo.items_count = 0 then 1 end)  as orders_without_items
from core.dim_order_status st
left join core.fact_order fo on fo.order_status = st.order_status
group by st.order_status, st.status_group, st.is_revenue;


-- Доставка по штату покупателя. Штат — на момент заказа (из fact_order),
-- а не текущий: если человек переехал, его старые заказы остаются
-- в том штате, куда их везли. Только доставленные заказы, у которых
-- есть дата вручения, иначе срок доставки не посчитать.
create view mart.v_delivery_state as
select fo.customer_state,
       count(*)                                            as delivered_orders,
       count(case when fo.is_delayed then 1 end)           as delayed_orders,
       round(100.0 * count(case when fo.is_delayed then 1 end) / count(*), 2) as delayed_pct,
       round(avg(fo.delivery_days)::numeric, 2)            as avg_delivery_days
from core.fact_order fo
where fo.is_revenue
  and fo.delivery_days is not null
group by fo.customer_state;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 03_answers.sql
-- =====================================================================
--  Ответы на десять вопросов из docs/tasks.md (блоки А и Б).
--
--  Все запросы идут через схему core и витрины mart, напрямую к raw
--  ни один ответ не обращается. Ответы заодно сохраняем в таблицы
--  mart.answer_q1 ... answer_q10, чтобы цифры можно было перепроверить
--  и сравнить между запусками.
--
--  Общие правила для всех ответов:
--    * выручка = сумма price по позициям, без доставки (freight);
--    * в выручку идут только заказы с is_revenue = true. Этот флаг
--      выставлен один раз в core.dim_order_status (сейчас это только
--      статус delivered) и дальше копируется в fact_order и
--      fact_order_item, так что список статусов здесь не повторяется;
--    * у каждого ответа есть контрольный select: он сверяет результат
--      с контрольными цифрами из задания (24 месяца, 13 221 498.11,
--      159.88, 96 096 / 3.12%, 74 категории). У блока Б контрольных
--      цифр в задании нет, там контрольный select сверяет ответ с
--      итогами модели (все заказы, все платежи и т.п.);
--    * штат покупателя (вопросы 7 и 9) — на момент заказа, из
--      core.fact_order, а не текущий адрес человека.
--
--  Порядок блока в каждом вопросе один и тот же:
--    1) create table mart.answer_qN — сам ответ;
--    2) select-заголовок '=== N ... ===', чтобы в выводе psql было
--       видно, где какой ответ;
--    3) select * из таблицы ответа;
--    4) контрольный запрос (если он есть).
-- =====================================================================

-- Таблицы ответов пересоздаём на каждом запуске: так файл можно гонять
-- сколько угодно раз подряд, и результат всегда считается заново
-- из текущего состояния core/mart, а не берётся из старого прогона.
drop table if exists mart.answer_q1;
drop table if exists mart.answer_q2;
drop table if exists mart.answer_q3;
drop table if exists mart.answer_q4;
drop table if exists mart.answer_q5;
drop table if exists mart.answer_q6;
drop table if exists mart.answer_q7;
drop table if exists mart.answer_q8;
drop table if exists mart.answer_q9;
drop table if exists mart.answer_q9_type;
drop table if exists mart.answer_q10;


-- ---------------------------------------------------------------------
-- 1. Выручка и число заказов по месяцам, сентябрь 2016 — август 2018.
--
--    Идём от календаря, поэтому ноябрь 2016 никуда не пропадает: заказов
--    в том месяце не было вовсе, и обычная группировка orders дала бы
--    23 строки вместо 24.
--
--    Откуда берутся цифры:
--      mart.v_monthly_revenue — это core.dim_calendar (все месяцы
--      подряд) left join core.fact_order по month_start, только
--      заказы с is_revenue. Пустой месяц получает orders = 0
--      (count по null даёт 0) и revenue = 0 (через coalesce).
--
--    Колонки:
--      month   — месяц в виде 'YYYY-MM', чтобы было удобно читать
--                и сортировать как текст;
--      orders  — число доставленных заказов, оформленных в этом месяце
--                (месяц считаем по дате покупки, purchased_at);
--      revenue — сумма goods_total этих заказов, то есть только товары
--                без доставки, округлено до копеек.
--
--    Фильтр between берёт ровно 24 месяца. Календарь тянется до последней
--    даты заказа, поэтому в нём есть ещё 2018-09 и 2018-10 (20 заказов,
--    ни одного доставленного). По заданию в отчёт они не входят.
-- ---------------------------------------------------------------------
create table mart.answer_q1 as
select to_char(m.month_start, 'YYYY-MM') as month,
       m.orders,
       round(m.revenue, 2)               as revenue
from mart.v_monthly_revenue m
where m.month_start between date '2016-09-01' and date '2018-08-01'
order by m.month_start;

select '=== 1. Выручка и заказы по месяцам ===' as answer;
select * from mart.answer_q1;

-- Контроль к вопросу 1:
--   rows_expected_24            — строк должно быть ровно 24 (по одной
--                                 на месяц, включая пустой ноябрь 2016);
--   zero_months                 — месяцев с нулевой выручкой, ожидаем 1
--                                 (это и есть 2016-11);
--   total_expected_13221498_11  — итог за весь период, должен совпасть
--                                 с общей выручкой 13 221 498.11.
--   Если строк 23, значит календарь потерялся и отчёт построен
--   от заказов, а не от месяцев.
select count(*)                as rows_expected_24,
       count(case when revenue = 0 then 1 end) as zero_months,
       round(sum(revenue), 2)  as total_expected_13221498_11
from mart.answer_q1;


-- ---------------------------------------------------------------------
-- 2. Топ-10 продавцов по выручке с городом и штатом.
--    Считаем по позициям: в заказе могут быть товары нескольких продавцов,
--    поэтому выручка продавца — это сумма цен только его товаров.
--
--    Почему не по fact_order: у заказа нет одного продавца. Если бы мы
--    приписали весь goods_total заказа каждому его продавцу, выручка
--    многопродавцовых заказов посчиталась бы несколько раз, и сумма
--    по продавцам оказалась бы больше общей выручки.
--
--    Откуда берутся цифры:
--      mart.v_seller_revenue — core.fact_order_item (только is_revenue),
--      сгруппированный по seller_id, с городом и штатом из
--      core.dim_seller (left join: продавец без карточки не выпадает,
--      просто будет без города).
--
--    Колонки:
--      orders  — в скольких разных заказах были товары продавца
--                (count distinct order_id);
--      units   — сколько позиций он продал; одна строка позиции =
--                одна единица товара, колонки количества в выгрузке нет;
--      revenue — сумма price его позиций, без доставки.
--
--    Сортировка: по выручке по убыванию, а при равной выручке — по
--    seller_id, чтобы десятка не менялась от запуска к запуску.
--    Контроль из задания: у первого продавца 226 987.93.
-- ---------------------------------------------------------------------
create table mart.answer_q2 as
select s.seller_id,
       s.seller_city,
       s.seller_state,
       s.orders,
       s.units,
       round(s.revenue, 2) as revenue
from mart.v_seller_revenue s
order by s.revenue desc, s.seller_id
limit 10;

select '=== 2. Топ-10 продавцов ===' as answer;
select * from mart.answer_q2;


-- ---------------------------------------------------------------------
-- 3. Средний чек заказа.
--
--    Берём fact_order: там одна строка на заказ, поэтому чек — это сумма
--    всех позиций заказа, а не средняя по строчке позиции.
--    Чек = товары + доставка (столько заплатил покупатель).
--    Средние числа строк и единиц — контрольные: оба около 1.14, значит
--    уровень выбран верно. Единицы равны строкам, потому что числа qty
--    в выгрузке нет: одна строка позиции = одна единица товара.
--
--    Колонки:
--      avg_check                 — средний order_total (товары + доставка)
--                                  по доставленным заказам, ответ: 159.88;
--      avg_lines                 — в среднем позиций (строк) в заказе;
--      avg_units                 — в среднем единиц товара в заказе.
--                                  Считается из того же items_count, что
--                                  и avg_lines, — см. пояснение про qty
--                                  выше; колонка оставлена отдельно, чтобы
--                                  ответ совпадал по форме с заданием;
--      avg_check_without_freight — средний goods_total, то есть чек без
--                                  доставки (137.04), для сравнения;
--      orders                    — сколько заказов вошло в среднее.
--
--    Заказы без позиций (их 775, в основном отменённые) сюда не
--    попадают: у них is_revenue = false, так что нулевые чеки
--    среднее не занижают.
-- ---------------------------------------------------------------------
create table mart.answer_q3 as
select round(avg(order_total), 2)  as avg_check,
       round(avg(items_count), 2)  as avg_lines,
       round(avg(items_count), 2)  as avg_units,
       round(avg(goods_total), 2)  as avg_check_without_freight,
       count(*)                    as orders
from core.fact_order
where is_revenue;

select '=== 3. Средний чек ===' as answer;
select * from mart.answer_q3;

-- Для сравнения: те же деньги, посчитанные по позиции (неверный уровень).
-- Здесь сумма делится на число строк позиций, а не на число заказов,
-- поэтому получается средняя стоимость одной позиции, а не чек:
--   goods_per_item — средняя цена товара в позиции (119.98);
--   full_per_item  — средняя позиция вместе с доставкой (139.97) —
--                    это ровно тот неверный ответ, о котором
--                    предупреждает задание.
-- Разница с 159.88 и есть те ~1.14 позиции на заказ.
select 'неверный уровень: средняя позиция' as comment,
       round(sum(price) / count(*), 2)      as goods_per_item,
       round(sum(item_total) / count(*), 2) as full_per_item
from core.fact_order_item
where is_revenue;


-- ---------------------------------------------------------------------
-- 4. Покупатели и повторные покупки.
--
--    Считаем по customer_unique_id: customer_id в выгрузке привязан
--    к заказу, у одного и того же человека при повторной покупке он новый.
--    Если посчитать по customer_id, получится 99 441 «покупателя».
--
--    Откуда берутся цифры:
--      mart.v_customer_base — одна строка на человека
--      (customer_unique_id), собранная из core.dim_customer и
--      core.fact_order. orders_total — все его заказы, в любом статусе.
--
--    Колонки:
--      customers    — сколько всего разных людей (строк в витрине),
--                     ответ: 96 096;
--      returned     — сколько из них сделали больше одного заказа;
--      returned_pct — доля вернувшихся в процентах, ответ: 3.12%.
--
--    «Вернулся» понимаем как «оформил второй заказ», поэтому берём
--    orders_total, а не orders_revenue: повторная покупка — это факт
--    оформления заказа, даже если его потом отменили. 100.0 в формуле
--    стоит для того, чтобы деление было дробным, а не целочисленным.
-- ---------------------------------------------------------------------
create table mart.answer_q4 as
select count(*)                                            as customers,
       count(case when orders_total > 1 then 1 end)        as returned,
       round(100.0 * count(case when orders_total > 1 then 1 end) / count(*), 2) as returned_pct
from mart.v_customer_base;

select '=== 4. Покупатели и возвраты ===' as answer;
select * from mart.answer_q4;

-- Проверка, что unique_id не «гуляет»: у одного customer_unique_id
-- может быть несколько customer_id (это и есть повторные покупки),
-- но у одного customer_id только один unique_id.
-- Ожидаем:
--   rows            = order_level_ids = 99 441 — customer_id уникален,
--                     одна строка на одну запись «покупатель в заказе»;
--   humans          = 96 096 — столько же, сколько customers в ответе.
-- Если бы rows был больше order_level_ids, у какого-то customer_id
-- оказалось бы несколько людей, и счёт по unique_id был бы неверным.
select 'customer_id -> unique_id' as check_name,
       count(*) as rows,
       count(distinct customer_id) as order_level_ids,
       count(distinct customer_unique_id) as humans
from core.dim_customer;


-- ---------------------------------------------------------------------
-- 5. Выручка по категориям с долей.
--
--    Товаров без категории 610, они уходят в not_available, а не выпадают.
--    Категорий получается 74 (73 настоящих + not_available): две категории
--    не имеют перевода, и мы оставляем их под португальским именем,
--    а не сливаем в одну «непереведённую» — иначе из отчёта пропадут
--    две категории с реальными продажами.
--    Сумма долей даёт 100%, сумма выручки равна общей выручке Capibara.
--
--    Откуда берутся цифры:
--      mart.v_category_revenue — core.fact_order_item (только is_revenue),
--      сгруппированный по display_category. display_category — это
--      английское название, если перевод есть, иначе португальское,
--      а для пустой категории — not_available.
--
--    Колонки:
--      display_category — название категории для отчёта;
--      revenue          — сумма price позиций этой категории;
--      share_pct        — доля категории в общей выручке, в процентах.
--
--    Знаменатель доли считаем подзапросом t по той же витрине и
--    подклеиваем его к каждой строке через cross join (у t ровно одна
--    строка). Так числитель и знаменатель гарантированно посчитаны
--    по одному набору позиций, и доли в сумме дают 100%.
-- ---------------------------------------------------------------------
create table mart.answer_q5 as
select c.display_category,
       round(c.revenue, 2) as revenue,
       round(100.0 * c.revenue / t.total_revenue, 2) as share_pct
from mart.v_category_revenue c
cross join (select sum(revenue) as total_revenue from mart.v_category_revenue) t
order by c.revenue desc;

-- В таблице ответа лежат все 74 категории, а на экран выводим
-- только первые 15 по выручке, чтобы вывод не растягивался.
select '=== 5. Выручка по категориям (топ-15 из 74) ===' as answer;
select * from mart.answer_q5 limit 15;

-- Контроль к вопросу 5:
--   categories_expected_74 — 73 категории с продажами + not_available;
--   total_13221498_11      — сумма по категориям равна общей выручке,
--                            то есть ни одна позиция не потерялась;
--   shares_sum_pct         — сумма долей, ожидаем 100.0 (возможна
--                            разница в сотые из-за округления каждой
--                            доли до двух знаков).
select 'control' as check_name,
       count(*)                    as categories_expected_74,
       round(sum(revenue), 2)      as total_13221498_11,
       round(sum(share_pct), 1)    as shares_sum_pct
from mart.answer_q5;


-- =====================================================================
--  Блок Б.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 6. Как менялась цена одного товара.
--
--    Берём товар, который продавался по наибольшему числу разных цен,
--    и показываем, по какой цене и сколько его продали в каждый день.
--
--    Откуда берутся цифры:
--      core.fact_order_item, только is_revenue: «продавался» понимаем
--      так же, как выручку, — заказ дошёл до покупателя. Цена — price
--      позиции, без доставки. Дата — день покупки (purchased_at).
--
--    Выбор товара: count(distinct price) по товару, при равенстве —
--    меньший product_id, чтобы ответ не менялся от запуска к запуску.
--    Подзапрос p — ровно одна строка, к позициям он цепляется join-ом.
--
--    Колонки:
--      sale_date  — день покупки;
--      price      — цена позиции;
--      units_sold — сколько единиц продано в этот день по этой цене
--                   (одна строка позиции = одна единица, как и в вопросе 2).
--    Если в один день товар уходил по двум ценам, строк за день будет две.
-- ---------------------------------------------------------------------
create table mart.answer_q6 as
select i.purchased_at::date as sale_date,
       i.price,
       count(*)             as units_sold
from core.fact_order_item i
join (
    select product_id
    from core.fact_order_item
    where is_revenue
    group by product_id
    order by count(distinct price) desc, product_id
    limit 1
) p on p.product_id = i.product_id
where i.is_revenue
group by i.purchased_at::date, i.price
order by sale_date, price;

select '=== 6. История цены товара ===' as answer;

-- какой товар выбран и сколько у него разных цен
select i.product_id,
       max(i.display_category)  as category,
       count(distinct i.price)  as distinct_prices,
       min(i.price)             as min_price,
       max(i.price)             as max_price,
       count(*)                 as units_sold
from core.fact_order_item i
where i.is_revenue
group by i.product_id
order by count(distinct i.price) desc, i.product_id
limit 1;

select * from mart.answer_q6;

-- Контроль к вопросу 6: число разных цен в ответе равно максимуму
-- по всем товарам, единицы в сумме равны продажам товара.
select count(distinct price) as distinct_prices,
       sum(units_sold)       as units_total
from mart.answer_q6;


-- ---------------------------------------------------------------------
-- 7. Доставка по штатам покупателя.
--
--    Только штаты, где не меньше 500 заказов.
--
--    Откуда берутся цифры:
--      mart.v_delivery_state — core.fact_order, доставленные заказы
--      (is_revenue) с известной датой вручения, по штату покупателя.
--      Штат — на момент заказа: заказ везли туда, где человек жил тогда,
--      и переезд после заказа не должен перекидывать его в другой штат.
--
--    Колонки:
--      customer_state    — штат покупателя;
--      orders            — доставленных заказов, по ним же и порог 500;
--      avg_delivery_days — средний срок от покупки до вручения, в днях
--                          (разница дат, без часов);
--      delayed_pct       — доля заказов, привезённых позже обещанной даты
--                          (estimated_delivery_date), в процентах.
--
--    8 доставленных заказов без даты вручения сюда не входят: срок
--    для них не посчитать. Порог считаем по тем же заказам, что и средние,
--    чтобы 500 значило «500 заказов в среднем», а не «500 заказов вообще».
-- ---------------------------------------------------------------------
create table mart.answer_q7 as
select d.customer_state,
       d.delivered_orders as orders,
       d.avg_delivery_days,
       d.delayed_pct
from mart.v_delivery_state d
where d.delivered_orders >= 500
order by d.delivered_orders desc, d.customer_state;

select '=== 7. Доставка по штатам (от 500 заказов) ===' as answer;
select * from mart.answer_q7;

-- Контроль к вопросу 7: сколько штатов прошло порог и какую часть
-- доставленных заказов они покрывают.
select count(*)     as states,
       sum(orders)  as orders_in_report,
       (select sum(delivered_orders) from mart.v_delivery_state) as orders_all_states
from mart.answer_q7;


-- ---------------------------------------------------------------------
-- 8. Воронка статусов.
--
--    Сколько заказов в каждом статусе, их доля и сколько из них без
--    единой позиции.
--
--    Откуда берутся цифры:
--      mart.v_order_status — core.dim_order_status left join
--      core.fact_order. Здесь все заказы, в любом статусе: воронка про
--      заказы, а не про выручку. Заказы без позиций есть в fact_order
--      с items_count = 0 (их 775), поэтому они не теряются.
--
--    Колонки:
--      order_status         — статус;
--      orders               — заказов в статусе;
--      share_pct            — доля от всех заказов, в процентах;
--      orders_without_items — из них без единой позиции.
--
--    Порядок — по числу заказов: так видно, что воронка почти вся
--    в delivered, а без позиций остаются в основном unavailable и canceled.
-- ---------------------------------------------------------------------
create table mart.answer_q8 as
select s.order_status,
       s.orders,
       round(100.0 * s.orders / t.total_orders, 2) as share_pct,
       s.orders_without_items
from mart.v_order_status s
cross join (select sum(orders) as total_orders from mart.v_order_status) t
order by s.orders desc, s.order_status;

select '=== 8. Воронка статусов ===' as answer;
select * from mart.answer_q8;

-- Контроль к вопросу 8: заказов столько же, сколько в raw (99 441),
-- без позиций — 775, доли в сумме ~100%.
select sum(orders)               as orders_expected_99441,
       sum(orders_without_items) as without_items_expected_775,
       round(sum(share_pct), 1)  as shares_sum_pct
from mart.answer_q8;


-- ---------------------------------------------------------------------
-- 9. Способы оплаты и рассрочка.
--
--    Две таблицы: по штатам покупателя за 2018 год и по способам оплаты
--    за весь период.
--
--    Откуда берутся цифры:
--      core.fact_payment — одна строка = один способ оплаты одного заказа,
--      поэтому «число платежей» — это число строк, а не заказов: заказ,
--      оплаченный картой и ваучером, даёт два платежа.
--      Штат — из core.fact_order, на момент заказа. Год — по дате покупки.
--      Платежи берём только по заказам с is_revenue, как и всю выручку
--      в модели: деньги отменённых заказов вернулись покупателю.
--
--    Колонки (по штатам):
--      customer_state   — штат покупателя;
--      payments         — число платежей;
--      paid             — сумма payment_value (то, что заплатил покупатель,
--                         вместе с доставкой);
--      avg_installments — средний срок рассрочки, в платежах.
--    Колонки (по способам): payment_type, payments, avg_installments.
--
--    Рассрочка бывает только у карты, у boleto и ваучера она всегда 1,
--    поэтому средний срок по штату во многом говорит о доле карт.
-- ---------------------------------------------------------------------
create table mart.answer_q9 as
select fo.customer_state,
       count(*)                             as payments,
       round(sum(p.payment_value), 2)       as paid,
       round(avg(p.installments), 2)        as avg_installments
from core.fact_payment p
join core.fact_order fo on fo.order_id = p.order_id
where p.is_revenue
  and p.month_start between date '2018-01-01' and date '2018-12-01'
group by fo.customer_state
order by paid desc, fo.customer_state;

create table mart.answer_q9_type as
select p.payment_type,
       count(*)                             as payments,
       round(avg(p.installments), 2)        as avg_installments
from core.fact_payment p
where p.is_revenue
group by p.payment_type
order by payments desc, p.payment_type;

select '=== 9. Оплата по штатам за 2018 год ===' as answer;
select * from mart.answer_q9;

select '=== 9. Способы оплаты, весь период ===' as answer;
select * from mart.answer_q9_type;

-- Контроль к вопросу 9: сумма по штатам равна всем платежам 2018 года
-- по доставленным заказам (штат не потерялся на join), а число
-- платежей по способам — всем платежам доставленных заказов.
select (select sum(paid) from mart.answer_q9)       as paid_by_states,
       (select round(sum(payment_value), 2)
        from core.fact_payment
        where is_revenue
          and month_start between date '2018-01-01' and date '2018-12-01')
                                                    as paid_2018_total,
       (select sum(payments) from mart.answer_q9_type) as payments_by_type,
       (select count(*) from core.fact_payment where is_revenue)
                                                    as payments_total;


-- ---------------------------------------------------------------------
-- 10. Связь оценки покупателя со сроком доставки.
--
--    Для каждой оценки 1–5 — сколько заказов, средний срок доставки
--    и доля опозданий.
--
--    Откуда берутся цифры:
--      core.fact_review (одна строка = отзыв) + core.fact_order
--      (срок и опоздание считаются на заказ). Только доставленные заказы
--      с датой вручения, как в вопросе 7.
--
--    Уровень: оценка — свойство отзыва, а срок — свойство заказа.
--    Берём пары (заказ, оценка) через distinct: если у заказа два отзыва
--    с одной оценкой, он считается один раз; если оценки разные (бывает
--    у заказов с 2–3 отзывами), заказ попадает в обе строки — его срок
--    действительно связан с обеими оценками. Средний балл заказа
--    (review_score_avg) здесь не годится: 4.5 не попадает ни в одну оценку.
--
--    Колонки:
--      review_score      — оценка 1..5;
--      orders            — заказов с такой оценкой;
--      avg_delivery_days — средний срок доставки, в днях;
--      delayed_pct       — доля опоздавших заказов, в процентах.
-- ---------------------------------------------------------------------
create table mart.answer_q10 as
select r.review_score,
       count(*)                                            as orders,
       round(avg(fo.delivery_days)::numeric, 2)            as avg_delivery_days,
       round(100.0 * count(case when fo.is_delayed then 1 end) / count(*), 2) as delayed_pct
from (select distinct order_id, review_score
      from core.fact_review
      where review_score between 1 and 5) r
join core.fact_order fo on fo.order_id = r.order_id
where fo.is_revenue
  and fo.delivery_days is not null
group by r.review_score
order by r.review_score;

select '=== 10. Оценка и срок доставки ===' as answer;
select * from mart.answer_q10;

-- Контроль к вопросу 10: строк ровно 5, и сколько заказов попало
-- в две оценки сразу (разница между суммой строк и числом заказов).
select count(*)                     as scores_expected_5,
       sum(orders)                  as order_score_pairs,
       (select count(distinct r.order_id)
        from core.fact_review r
        join core.fact_order fo on fo.order_id = r.order_id
        where fo.is_revenue and fo.delivery_days is not null
          and r.review_score between 1 and 5) as orders_distinct
from mart.answer_q10;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 04_checks.sql
-- =====================================================================
--  Проверки модели. Запускаем после 01 и 02, смотрим на колонку ok.
--  Проверки 11–15 — про историю (вброс): адреса и категории версиями.
--  В конце файла — проба изменений в транзакции с откатом.
--
--  Смысл не в том, чтобы один раз увидеть галочки, а в том, чтобы при
--  следующей загрузке данных эти же запросы сразу показали, что сломалось:
--  пропали строки на join, изменилась общая выручка, появился заказ без
--  покупателя.
-- =====================================================================

select '1. сырые строки перенесены без потерь' as check_name,
       (select count(*) from raw.orders)      as raw_orders,
       (select count(*) from core.fact_order) as model_orders,
       (select count(*) from raw.orders)      = (select count(*) from core.fact_order) as ok

union all
select '2. позиции перенесены без потерь',
       (select count(*) from raw.order_items),
       (select count(*) from core.fact_order_item),
       (select count(*) from raw.order_items) = (select count(*) from core.fact_order_item)

union all
select '3. платежи перенесены без потерь',
       (select count(*) from raw.order_payments),
       (select count(*) from core.fact_payment),
       (select count(*) from raw.order_payments) = (select count(*) from core.fact_payment)

union all
select '4. у каждого заказа есть покупатель',
       (select count(*) from core.fact_order),
       (select count(*) from core.fact_order where customer_unique_id is not null),
       (select count(*) from core.fact_order)
         = (select count(*) from core.fact_order where customer_unique_id is not null)

union all
-- самая частая поломка: позиция осталась без категории и выпала из отчёта
select '5. у каждой позиции есть категория',
       (select count(*) from core.fact_order_item),
       (select count(*) from core.fact_order_item where category_id is not null),
       (select count(*) from core.fact_order_item)
         = (select count(*) from core.fact_order_item where category_id is not null)

union all
-- деньги в модели должны совпасть с деньгами, посчитанными прямо из raw
select '6. выручка из модели = выручка из raw',
       (select round(sum(coalesce(goods_total, 0)), 2) from core.fact_order where is_revenue),
       (select round(sum(nullif(btrim(i.price), '')::numeric), 2)
        from raw.order_items i
        join raw.orders o on o.order_id = i.order_id
        where o.order_status = 'delivered'),
       (select round(sum(coalesce(goods_total, 0)), 2) from core.fact_order where is_revenue)
         = (select round(sum(nullif(btrim(i.price), '')::numeric), 2)
            from raw.order_items i
            join raw.orders o on o.order_id = i.order_id
            where o.order_status = 'delivered')

union all
-- сумма по категориям обязана равняться общей выручке, иначе часть товаров
-- потерялась при join с карточками
select '7. категории в сумме дают общую выручку',
       (select round(sum(revenue), 2) from mart.v_category_revenue),
       (select round(sum(goods_total), 2) from core.fact_order where is_revenue),
       (select round(sum(revenue), 2) from mart.v_category_revenue)
         = (select round(sum(goods_total), 2) from core.fact_order where is_revenue)

union all
-- сумма по продавцам тоже обязана равняться общей выручке
select '8. продавцы в сумме дают общую выручку',
       (select round(sum(revenue), 2) from mart.v_seller_revenue),
       (select round(sum(goods_total), 2) from core.fact_order where is_revenue),
       (select round(sum(revenue), 2) from mart.v_seller_revenue)
         = (select round(sum(goods_total), 2) from core.fact_order where is_revenue)

union all
-- календарь покрывает все даты заказов, иначе отчёт по месяцам недоделан
select '9. календарь покрывает все заказы',
       (select count(distinct month_start) from core.fact_order),
       (select count(distinct month_start) from core.dim_calendar),
       (select count(distinct month_start) from core.fact_order)
         <= (select count(distinct month_start) from core.dim_calendar)

union all
-- ключ позиции: order_item_id сам по себе не уникален, уникальна пара
select '10. ключ (order_id, order_item_id) не дублируется',
       (select count(*) from core.fact_order_item),
       (select count(distinct (order_id, order_item_id)) from core.fact_order_item),
       (select count(*) from core.fact_order_item)
         = (select count(distinct (order_id, order_item_id)) from core.fact_order_item)

union all
-- история адресов: каждый заказ привязан к версии адреса
select '11. у каждого заказа есть версия адреса',
       (select count(*) from core.fact_order),
       (select count(*) from core.fact_order where address_sk is not null),
       (select count(*) from core.fact_order)
         = (select count(*) from core.fact_order where address_sk is not null)

union all
-- адрес на момент заказа обязан совпасть с тем, что записан в raw на этот заказ
select '12. адрес в заказе = адрес из raw на этот заказ',
       (select count(*) from core.fact_order),
       (select count(*)
        from core.fact_order fo
        join core.dim_customer cu on cu.customer_id = fo.customer_id
        where fo.customer_city  is not distinct from cu.customer_city
          and fo.customer_state is not distinct from cu.customer_state),
       (select count(*) from core.fact_order)
         = (select count(*)
            from core.fact_order fo
            join core.dim_customer cu on cu.customer_id = fo.customer_id
            where fo.customer_city  is not distinct from cu.customer_city
              and fo.customer_state is not distinct from cu.customer_state)

union all
-- у каждого человека ровно одна текущая версия адреса
select '13. одна текущая версия адреса на человека',
       (select count(distinct customer_unique_id) from core.dim_customer),
       (select count(*) from core.dim_customer_address where is_current),
       (select count(distinct customer_unique_id) from core.dim_customer)
         = (select count(*) from core.dim_customer_address where is_current)

union all
-- у каждого товара ровно одна текущая версия категории
select '14. одна текущая версия категории на товар',
       (select count(*) from core.dim_product),
       (select count(*) from core.dim_product_category_hist where is_current),
       (select count(*) from core.dim_product)
         = (select count(*) from core.dim_product_category_hist where is_current)

union all
-- версии не пересекаются: каждая позиция попадает ровно в одну версию
-- категории своего товара (если бы пересекались, join дал бы дубли)
select '15. позиция попадает ровно в одну версию категории',
       (select count(*) from core.fact_order_item),
       (select count(*)
        from core.fact_order_item i
        join core.dim_product_category_hist h
          on h.product_id = i.product_id
         and i.purchased_at >= h.valid_from
         and i.purchased_at <  h.valid_to),
       (select count(*) from core.fact_order_item)
         = (select count(*)
            from core.fact_order_item i
            join core.dim_product_category_hist h
              on h.product_id = i.product_id
             and i.purchased_at >= h.valid_from
             and i.purchased_at <  h.valid_to)

order by 1;


-- Что потерялось бы при обычном join, если не беречься: считаем честно
select 'заказы без позиций (остались в модели с нулями)' as note,
       count(*) as orders
from core.fact_order
where items_count = 0

union all
select 'заказы без платежей', count(*)
from core.fact_order
where paid_total = 0

union all
select 'заказы без отзыва', count(*)
from core.fact_order
where review_score_avg is null

union all
select 'отзывов с дублирующимся review_id (поэтому ключ не review_id)',
       count(*)
from (select review_id from core.fact_review group by review_id having count(*) > 1) d

union all
select 'заказов с несколькими отзывами', count(*)
from (select order_id from core.fact_review group by order_id having count(*) > 1) r;


-- ---------------------------------------------------------------------
-- Проба вброса: меняем категорию самого продаваемого товара и переселяем
-- самого активного покупателя, смотрим, что прошлые отчёты не сдвинулись,
-- а текущее состояние поменялось. Всё внутри транзакции и откатывается
-- в конце: журнал и модель остаются как были.
-- ---------------------------------------------------------------------
begin;

-- снимок до изменений: выручка по месяцам и категориям, адреса заказов
create temp table probe_before on commit drop as
select month_start, display_category, sum(price) as revenue
from core.fact_order_item
where is_revenue
group by month_start, display_category;

create temp table probe_orders_before on commit drop as
select order_id, customer_city, customer_state
from core.fact_order;

create temp table probe_target on commit drop as
select (select product_id
        from core.fact_order_item
        where is_revenue
        group by product_id
        order by sum(price) desc, product_id
        limit 1) as product_id,
       (select customer_unique_id
        from core.fact_order
        group by customer_unique_id
        order by count(*) desc, customer_unique_id
        limit 1) as customer_unique_id;

select changelog.change_product_category(
           t.product_id,
           (select c.category_id
            from core.dim_category c
            join core.dim_product p on p.product_id = t.product_id
            where c.category_id <> p.category_id
            order by c.category_id
            limit 1),
           timestamp '2018-09-01',
           'проба из 04_checks.sql')
from probe_target t;

select changelog.move_customer(t.customer_unique_id, 'proba', 'XX', '00000', timestamp '2018-11-01')
from probe_target t;

select 'вброс: смена категории' as check_name,
       (select display_category from core.dim_product p join probe_target t using (product_id))
                                                       as current_category,
       (select count(*)
        from (select month_start, display_category, sum(price) as revenue
              from core.fact_order_item
              where is_revenue
              group by month_start, display_category
              except
              select * from probe_before) d)           as changed_report_rows,
       (select count(*)
        from (select month_start, display_category, sum(price) as revenue
              from core.fact_order_item
              where is_revenue
              group by month_start, display_category
              except
              select * from probe_before) d) = 0       as ok

union all
select 'вброс: переезд покупателя',
       (select customer_city || ' / ' || customer_state
        from core.dim_customer_address a
        join probe_target t using (customer_unique_id)
        where a.is_current),
       (select count(*)
        from core.fact_order fo
        join probe_orders_before b using (order_id)
        where fo.customer_city  is distinct from b.customer_city
           or fo.customer_state is distinct from b.customer_state),
       (select count(*)
        from core.fact_order fo
        join probe_orders_before b using (order_id)
        where fo.customer_city  is distinct from b.customer_city
           or fo.customer_state is distinct from b.customer_state) = 0;

rollback;
