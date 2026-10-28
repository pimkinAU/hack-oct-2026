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
