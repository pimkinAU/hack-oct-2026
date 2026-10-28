-- =====================================================================
--  РњРѕРґРµР»СЊ РґР°РЅРЅС‹С… Capibara С†РµР»РёРєРѕРј, РѕРґРЅРёРј С„Р°Р№Р»РѕРј.
--
--  Р¤Р°Р№Р» СЃРѕР±СЂР°РЅ СЃРєСЂРёРїС‚РѕРј model/make_all_in_one.ps1 (.sh) РёР· С‡РµС‚С‹СЂС‘С… С€Р°РіРѕРІ:
--    01_core.sql     -> СЃС…РµРјР° core (С„Р°РєС‚С‹ Рё РёР·РјРµСЂРµРЅРёСЏ) РёР· raw
--    02_mart.sql     -> РїСЂРµРґСЃС‚Р°РІР»РµРЅРёСЏ mart
--    03_answers.sql  -> РѕС‚РІРµС‚С‹ РЅР° 5 РІРѕРїСЂРѕСЃРѕРІ Р±Р»РѕРєР° Рђ
--    04_checks.sql   -> 10 РїСЂРѕРІРµСЂРѕРє С†РµР»РѕСЃС‚РЅРѕСЃС‚Рё
--
--  Р—Р°РїСѓСЃРє:  psql -f model/all_in_one.sql
--  РџРµСЂРµРґ РєР°Р¶РґС‹Рј С€Р°РіРѕРј СЃРІРѕРё С‚Р°Р±Р»РёС†С‹ СѓРґР°Р»СЏСЋС‚СЃСЏ, РїРѕСЌС‚РѕРјСѓ Р·Р°РїСѓСЃРє РјРѕР¶РЅРѕ
--  РїРѕРІС‚РѕСЂСЏС‚СЊ, СЂРµР·СѓР»СЊС‚Р°С‚ РєР°Р¶РґС‹Р№ СЂР°Р· РѕРґРёРЅ Рё С‚РѕС‚ Р¶Рµ.
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
-- =====================================================================

drop table if exists core.fact_order_item cascade;
drop table if exists core.fact_payment cascade;
drop table if exists core.fact_review cascade;
drop table if exists core.fact_order cascade;
drop table if exists core.dim_calendar cascade;
drop table if exists core.dim_category cascade;
drop table if exists core.dim_product cascade;
drop table if exists core.dim_seller cascade;
drop table if exists core.dim_customer cascade;
drop table if exists core.dim_order_status cascade;

-- схемы создаём здесь, чтобы файл работал и на базе, где их ещё нет
-- (обычно их делает scripts/load_raw.py, но нам важно запускаться самим)
create schema if not exists core;
create schema if not exists mart;


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
-- dim_product — карточка товара.
--
-- Категории может не быть, тогда ведём товар в категорию not_available,
-- чтобы он не потерялся из отчёта по категориям.
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
       coalesce(nullif(btrim(pr.product_category_name), ''), 'not_available'),
       coalesce(t.product_category_name_english,
                nullif(btrim(pr.product_category_name), ''),
                'not_available'),
       nullif(btrim(pr.product_photos_qty), '')::integer,
       nullif(btrim(pr.product_weight_g), '')::numeric,
       nullif(btrim(pr.product_length_cm), '')::numeric,
       nullif(btrim(pr.product_height_cm), '')::numeric,
       nullif(btrim(pr.product_width_cm), '')::numeric
from raw.products pr
left join raw.product_category_translation t
       on t.product_category_name = pr.product_category_name;


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
-- ---------------------------------------------------------------------
create table core.fact_order (
    order_id            text primary key,
    customer_id         text,
    customer_unique_id  text,
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
       coalesce(nullif(btrim(p.product_category_name), ''), 'not_available'),
       coalesce(t.product_category_name_english,
                nullif(btrim(p.product_category_name), ''),
                'not_available'),
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
left join raw.products p      on p.product_id = i.product_id
left join raw.sellers s       on s.seller_id = i.seller_id
left join raw.product_category_translation t on t.product_category_name = p.product_category_name
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

analyze core.fact_order;
analyze core.fact_order_item;
analyze core.fact_payment;
analyze core.fact_review;
analyze core.dim_customer;
analyze core.dim_product;
analyze core.dim_calendar;

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
       max(cu.customer_city)                   as customer_city,
       max(cu.customer_state)                  as customer_state
from core.dim_customer cu
join core.fact_order fo on fo.customer_id = cu.customer_id
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 03_answers.sql
-- =====================================================================
--  Ответы на пять вопросов из docs/tasks.md (блок А).
--
--  Все запросы идут через схему core и витрины mart, напрямую к raw
--  ни один ответ не обращается. Ответы заодно сохраняем в таблицы
--  mart.answer_q1 ... answer_q5, чтобы цифры можно было перепроверить
--  и сравнить между запусками.
--
--  Общие правила для всех пяти ответов:
--    * выручка = сумма price по позициям, без доставки (freight);
--    * в выручку идут только заказы с is_revenue = true. Этот флаг
--      выставлен один раз в core.dim_order_status (сейчас это только
--      статус delivered) и дальше копируется в fact_order и
--      fact_order_item, так что список статусов здесь не повторяется;
--    * у каждого ответа есть контрольный select: он сверяет результат
--      с контрольными цифрами из задания (24 месяца, 13 221 498.11,
--      159.88, 96 096 / 3.12%, 74 категории).
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 04_checks.sql
-- =====================================================================
--  Проверки модели. Запускаем после 01 и 02, смотрим на колонку ok.
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
