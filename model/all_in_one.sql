-- =====================================================================
--  Модель данных Capibara целиком, одним файлом.
--
--  Файл собран скриптом model/make_all_in_one.ps1 (.sh) из семи шагов:
--    01_core.sql     -> схема core (факты и измерения) из raw
--    02_mart.sql     -> представления mart
--    03_answers.sql  -> ответы на 5 вопросов блока А
--    04_checks.sql   -> 10 проверок целостности
--    05_history.sql  -> история адресов покупателей, продавцов и категорий
--    06_block_b.sql  -> ответы на 5 вопросов блока Б
--    07_checks_b.sql -> 12 проверок истории и блока Б
--
--  Запуск:  psql -f model/all_in_one.sql
--           или docker compose exec -T postgres psql -U hack -d marketplace < model/all_in_one.sql
--  Перед каждым шагом свои таблицы удаляются, поэтому запуск можно
--  повторять, результат каждый раз один и тот же.
--
--  Этот файл — шапка для all_in_one.sql, его читают оба скрипта сборки.
--  Текст держим здесь, а не внутри .ps1: Windows PowerShell 5.1 читает
--  исходники .ps1 не в UTF-8, и кириллица в самом скрипте превращается в
--  кракозябры. Файл ниже всегда читается явно с -Encoding UTF8.
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 05_history.sql
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
drop table if exists core.tmp_customer_address;
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
--    встречаются в один день: человек физически не может жить в двух городах,
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

-- Сколько версий отбросил выбор «лучшего» адреса на дату: 14 адресов из 96 352
-- появились в один день с другим адресом того же человека. Показываем замеры
-- прямо здесь, чтобы приём не был невидимым. Колонки названы по-английски:
-- кириллический алиас без кавычек ломает запрос, если файл в psql приходит не в
-- UTF-8 (проверки и ответы при этом живут в строковых литералах и не ломаются).
select '=== история адресов: замеры ===' as demo,
       (select count(distinct (customer_unique_id, first_seen)) from core.tmp_customer_address) as versions_in_data,
       (select count(*) from core.dim_customer_history) as versions_in_history,
       (select count(distinct customer_unique_id) from core.dim_customer_history) as people,
       (select count(*) from (select customer_unique_id
                                from core.dim_customer_history
                               group by customer_unique_id
                              having count(*) > 1) t) as people_with_two_addresses;

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
       count(distinct customer_unique_id)         as people,
       count(*)                                   as versions,
       count(case when is_current then 1 end)     as current_versions
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 06_block_b.sql
-- =====================================================================
--  Блок Б из docs/tasks.md: вопросы 6, 7, 8, 9, 10.
--
--  Как и в 03_answers.sql, каждый ответ кладём в таблицу mart.answer_qN,
--  чтобы цифру можно было перепроверить обычным select, а затем печатаем
--  её на экран вместе с контрольным запросом.
--
--  Ответов шесть таблиц, а не пять: у вопроса 9 два результата — по штатам
--  и отдельно по способам оплаты.
--
--  Контрольных чисел в задании блока Б нет, поэтому контролем по внутренним
--  сверкам: суммы должны сходиться с тем, что уже посчитано в блоке А,
--  а число заказов — с числом строк в источнике. Всё это собрано
--  в 07_checks_b.sql.
-- =====================================================================

drop table if exists mart.answer_q6;
drop table if exists mart.answer_q6_product;
drop table if exists mart.answer_q7;
drop table if exists mart.answer_q8;
drop table if exists mart.answer_q9_state;
drop table if exists mart.answer_q9_type;
drop table if exists mart.answer_q10;


-- ---------------------------------------------------------------------
-- 6. Как менялась цена одного товара.
--
--    Сначала выбираем сам товар: у кого больше всего разных цен.
--    Считаем по всем позициям (и по доставленным тоже 31 цена — результат
--    не зависит от статуса, проверено).
--
--    Сортировка с тремя колонками, чтобы при одинаковом числе цен выбор был
--    одинаковым между запусками: сначала больше продаж, затем id товара.
-- ---------------------------------------------------------------------
create table mart.answer_q6_product as
select i.product_id,
       max(i.display_category)           as category,
       count(distinct i.price)           as price_variants,
       count(*)                          as units,
       min(i.price)                      as min_price,
       max(i.price)                      as max_price,
       min(fo.purchased_at)::date        as first_sale,
       max(fo.purchased_at)::date        as last_sale,
       count(distinct i.seller_id)       as sellers
from core.fact_order_item i
join core.fact_order fo on fo.order_id = i.order_id
where i.product_id is not null
group by i.product_id
order by count(distinct i.price) desc, count(*) desc, i.product_id
limit 1;

-- История цены этого товара: дата, цена, сколько единиц так продали.
-- Единицы = число строк позиции: колонки количества в выгрузке нет.
create table mart.answer_q6 as
select fo.purchased_at::date as sale_date,
       i.price,
       count(*)              as units
from core.fact_order_item i
join core.fact_order fo on fo.order_id = i.order_id
where i.product_id = (select product_id from mart.answer_q6_product)
group by fo.purchased_at::date, i.price
order by fo.purchased_at::date, i.price;

select '=== 6. Товар с максимумом разных цен ===' as answer;
select * from mart.answer_q6_product;

select 'история цены (первые 20 строк из ' ||
       (select count(*)::text from mart.answer_q6) || ')' as answer;
select * from mart.answer_q6 limit 20;

-- Контроль: у выбранного товара действительно максимум разных цен.
select 'control' as check_name,
       (select price_variants from mart.answer_q6_product) as chosen_variant_count,
       (select max(k) from (
            select count(distinct price) as k
            from core.fact_order_item
            where product_id is not null
            group by product_id
        ) t) as maximum_in_data;


-- ---------------------------------------------------------------------
-- 7. Доставка по штатам покупателя.
--
--    Берём доставленные заказы, у которых есть фактическая дата доставки:
--    без неё и среднее число дней, и признак опоздания посчитать нельзя.
--    Порог «не меньше 500 заказов» стоит в having, чтобы не показывать
--    штаты с десятками заказов, где среднее скачет от одной посылки.
--
--    Опоздание — уже посчитанный в модели флаг is_delayed: дата доставки
--    позже обещанной (order_estimated_delivery_date).
-- ---------------------------------------------------------------------
create table mart.answer_q7 as
select cu.customer_state             as state,
       count(*)                      as orders,
       round(avg(fo.delivery_days), 2) as avg_delivery_days,
       round(100.0 * count(case when fo.is_delayed then 1 end) / count(*), 2) as delayed_pct
from core.fact_order fo
join core.dim_customer cu on cu.customer_id = fo.customer_id
where fo.is_revenue
  and fo.delivery_days is not null
group by cu.customer_state
having count(*) >= 500
order by avg_delivery_days desc;

select '=== 7. Доставка по штатам покупателя (от 500 заказов) ===' as answer;
select * from mart.answer_q7;

-- Контроль: сколько заказов вошло в таблицу и сколько штатов не прошли порог.
select 'control' as check_name,
       (select sum(orders) from mart.answer_q7)                          as orders_in_answer,
       (select count(*) from core.fact_order where is_revenue and delivery_days is not null) as delivered_with_date,
       (select count(*) from (
            select cu.customer_state
            from core.fact_order fo
            join core.dim_customer cu on cu.customer_id = fo.customer_id
            where fo.is_revenue and fo.delivery_days is not null
            group by cu.customer_state
            having count(*) < 500
        ) t) as states_below_500;


-- ---------------------------------------------------------------------
-- 8. Воронка статусов.
--
--    Здесь нужны ВСЕ заказы, а не только доставленные: вопрос именно про
--    распределение статусов. Знаменатель доли — общее число заказов,
--    берём его подзапросом и приклеиваем cross join (одна строка).
--
--    Колонка «без позиций» отвечает на практический вопрос: часть заказов
--    в данных вообще не содержит товаров (775 штук, в основном unavailable
--    и canceled), и в воронке их видно отдельной цифрой.
-- ---------------------------------------------------------------------
create table mart.answer_q8 as
select fo.order_status                 as status,
       count(*)                        as orders,
       round(100.0 * count(*) / t.total, 2) as share_pct,
       count(case when fo.items_count = 0 then 1 end) as orders_without_items
from core.fact_order fo
cross join (select count(*)::numeric as total from core.fact_order) t
group by fo.order_status, t.total
order by count(*) desc;

select '=== 8. Воронка статусов ===' as answer;
select * from mart.answer_q8;

select 'control' as check_name,
       (select sum(orders) from mart.answer_q8)                     as orders_in_answer,
       (select count(*) from core.fact_order)                       as orders_in_data,
       (select count(case when items_count = 0 then 1 end) from core.fact_order) as without_items_in_data,
       (select sum(orders_without_items) from mart.answer_q8)       as without_items_in_answer;


-- ---------------------------------------------------------------------
-- 9. Способы оплаты и рассрочка.
--
--    2018 год = заказы, оформленные с 1 января 2018 по 31 декабря 2018.
--    Статусы не отсекаем: вопрос про то, как платили, а платили и за
--    отменённые заказы тоже (для сравнения: только доставленные заказы
--    дают 54 748 платежей на 8 452 975.20 вместо 56 015 на 8 699 763.05).
--
--    Про рассрочку важно: в колонке installments стоит 1 у обычного
--    платежа, 2..24 у рассрочки, а 0 встречается всего в 2 строках из 103 886
--    (незаполненные данные, на среднее не влияют). Среднее по всем платежам —
--    2.85 (за 2018 — 2.73), а среднее по платежам с реальной рассрочкой
--    (больше 1) — 4.75 (за 2018 — 4.60). В ответе лежит первое, как и просили;
--    второе показываем отдельной колонкой в разрезе по способам оплаты, чтобы
--    цифру нельзя было прочитать неверно.
-- ---------------------------------------------------------------------
create table mart.answer_q9_state as
select cu.customer_state        as state,
       count(*)                 as payments,
       round(sum(p.payment_value), 2) as paid,
       round(avg(p.installments), 2)  as avg_installments
from core.fact_payment p
join core.fact_order fo     on fo.order_id = p.order_id
join core.dim_customer cu   on cu.customer_id = fo.customer_id
where fo.purchased_at >= date '2018-01-01'
  and fo.purchased_at <  date '2019-01-01'
group by cu.customer_state
order by sum(p.payment_value) desc;

create table mart.answer_q9_type as
select p.payment_type                  as payment_type,
       count(*)                        as payments,
       round(sum(p.payment_value), 2)  as paid,
       round(avg(p.installments), 2)   as avg_installments,
       count(case when p.installments > 1 then 1 end) as payments_in_installments,
       round(avg(case when p.installments > 1 then p.installments end), 2) as avg_term_when_installments
from core.fact_payment p
group by p.payment_type
order by count(*) desc;

select '=== 9. Оплата по штатам за 2018 ===' as answer;
select * from mart.answer_q9_state;

select '=== 9. Способы оплаты целиком ===' as answer;
select * from mart.answer_q9_type;

select 'control' as check_name,
       (select sum(payments) from mart.answer_q9_state)              as payments_2018,
       (select count(*) from core.fact_payment p
        join core.fact_order fo on fo.order_id = p.order_id
        where fo.purchased_at >= date '2018-01-01'
          and fo.purchased_at <  date '2019-01-01')                  as payments_2018_in_data,
       (select round(sum(paid), 2) from mart.answer_q9_state)        as paid_2018,
       (select count(*) from mart.answer_q9_type)                    as payment_types;


-- ---------------------------------------------------------------------
-- 10. Связь оценки покупателя со сроком доставки.
--
--    Один заказ может иметь несколько отзывов (547 таких), поэтому сначала
--    собираем по заказу одну строку: худшая оценка, срок доставки, факт
--    опоздания. И уже по этим строкам считаем среднее. Иначе заказы
--    с двумя отзывами посчитались бы дважды.
--
--    Берём только заказы с известным сроком доставки: без фактической даты
--    сравнивать не с чем.
-- ---------------------------------------------------------------------
create table mart.answer_q10 as
select s.score                         as review_score,
       count(*)                        as orders,
       round(avg(s.delivery_days), 2)  as avg_delivery_days,
       round(100.0 * sum(s.is_delayed) / count(*), 2) as delayed_pct
from (
        select r.order_id,
               -- если отзывов несколько, берём худший: он и есть переживание покупателя
               min(r.review_score) as score,
               min(fo.delivery_days) as delivery_days,
               max(case when fo.is_delayed then 1 else 0 end) as is_delayed
        from core.fact_review r
        join core.fact_order fo on fo.order_id = r.order_id
        where r.review_score between 1 and 5
          and fo.delivery_days is not null
        group by r.order_id
     ) s
group by s.score
order by s.score;

select '=== 10. Оценка и срок доставки ===' as answer;
select * from mart.answer_q10;

select 'control' as check_name,
       (select sum(orders) from mart.answer_q10)                     as orders_in_answer,
       (select count(distinct r.order_id)
        from core.fact_review r
        join core.fact_order fo on fo.order_id = r.order_id
        where r.review_score between 1 and 5
          and fo.delivery_days is not null)                          as orders_in_data,
       (select count(distinct review_score) from mart.answer_q10)    as scores;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>> 07_checks_b.sql
-- =====================================================================
--  Проверки блока Б и истории (05_history.sql, 06_block_b.sql).
--
--  Как и в 04_checks.sql, смотрим на колонку ok: везде должно быть t.
--  Смысл тот же — это не украшение, а способ при следующей загрузке
--  сразу увидеть, что сломалось: версия измерения нашла не каждый заказ,
--  ответ по статусам перестал сходиться с числом заказов, в отчёт по
--  штатам попали штаты ниже порога.
-- =====================================================================

-- В контейнере Docker маленький /dev/shm (64 МБ по умолчанию), а проверки
-- ниже делают большие хеш-соединения. Параллельный план просит общую память
-- и падает с «No space left on device», поэтому для этого файла параллельность
-- выключена. На результат это не влияет, только на скорость.
set max_parallel_workers_per_gather = 0;

select '1. у каждого человека ровно одна действующая версия адреса' as check_name,
       (select count(distinct customer_unique_id)::text from core.dim_customer_history) as expected,
       (select count(case when is_current then 1 end)::text from core.dim_customer_history) as actual,
       (select count(distinct customer_unique_id) from core.dim_customer_history)
         = (select count(case when is_current then 1 end) from core.dim_customer_history) as ok

union all
-- интервалы версий не должны пересекаться: иначе заказ получил бы два адреса
select '2. версии адресов не пересекаются',
       '0',
       ((select count(*)
           from core.dim_customer_history a
           join core.dim_customer_history b
             on  b.customer_unique_id = a.customer_unique_id
            and b.valid_from > a.valid_from
            and b.valid_from <= a.valid_to)::text),
       (select count(*)
          from core.dim_customer_history a
          join core.dim_customer_history b
            on  b.customer_unique_id = a.customer_unique_id
           and b.valid_from > a.valid_from
           and b.valid_from <= a.valid_to) = 0

union all
-- каждый заказ должен получить ровно одну версию адреса на свою дату
select '3. каждый заказ получил один адрес на дату заказа',
       ((select count(*) from core.fact_order where purchased_at is not null)::text),
       ((select count(*) from core.v_order_customer_address)::text),
       (select count(*) from core.fact_order where purchased_at is not null)
         = (select count(*) from core.v_order_customer_address)

union all
-- категория на дату заказа должна найтись для каждой позиции
select '4. каждая позиция получила категорию на дату заказа',
       ((select count(*) from core.fact_order_item)::text),
       ((select count(*) from core.v_item_category_as_ordered)::text),
       (select count(*) from core.fact_order_item)
         = (select count(*) from core.v_item_category_as_ordered)

union all
-- деньги, посчитанные через историю категорий, равны выручке блока А
select '5. выручка через историю = выручка блока А',
       '13221498.11',
       ((select round(sum(i.price), 2)::text
           from core.fact_order_item i
           join core.fact_order fo on fo.order_id = i.order_id
           join core.dim_product_category_history h
             on  h.product_id = i.product_id
            and fo.purchased_at::date between h.valid_from and h.valid_to
          where i.is_revenue)::text),
       (select round(sum(i.price), 2)
          from core.fact_order_item i
          join core.fact_order fo on fo.order_id = i.order_id
          join core.dim_product_category_history h
            on  h.product_id = i.product_id
           and fo.purchased_at::date between h.valid_from and h.valid_to
         where i.is_revenue) = 13221498.11::numeric

union all
select '6. у продавца одна версия адреса (снимок один)',
       ((select count(*) from core.dim_seller)::text),
       ((select count(*) from core.dim_seller_history)::text),
       (select count(*) from core.dim_seller) = (select count(*) from core.dim_seller_history)

union all
-- 6: выбранный товар действительно лидер по числу разных цен
select '7. q6: у товара максимум разных цен в данных',
       ((select max(k)::text from (
             select count(distinct price) as k
               from core.fact_order_item
              where product_id is not null
              group by product_id) t)::text),
       ((select price_variants::text from mart.answer_q6_product)::text),
       (select max(k) from (
             select count(distinct price) as k
               from core.fact_order_item
              where product_id is not null
              group by product_id) t)
         = (select price_variants from mart.answer_q6_product)

union all
-- 7: порог 500 соблюдён у каждой строки и ни один годный штат не потерян
select '8. q7: порог 500 и все годные штаты',
       ((select count(*) from (
             select cu.customer_state
               from core.fact_order fo
               join core.dim_customer cu on cu.customer_id = fo.customer_id
              where fo.is_revenue and fo.delivery_days is not null
              group by cu.customer_state
             having count(*) >= 500) t)::text),
       ((select count(*)::text from mart.answer_q7)::text),
       (select count(*) from (
             select cu.customer_state
               from core.fact_order fo
               join core.dim_customer cu on cu.customer_id = fo.customer_id
              where fo.is_revenue and fo.delivery_days is not null
              group by cu.customer_state
             having count(*) >= 500) t)
         = (select count(*) from mart.answer_q7)
     and (select min(orders) from mart.answer_q7) >= 500

union all
-- 8: воронка статусов обязана покрыть все заказы
select '9. q8: статусы покрывают все заказы',
       ((select count(*)::text from core.fact_order)::text),
       ((select sum(orders)::text from mart.answer_q8)::text),
       (select count(*) from core.fact_order) = (select sum(orders) from mart.answer_q8)
     and (select abs(sum(share_pct) - 100.0) from mart.answer_q8) < 0.1
     and (select sum(orders_without_items) from mart.answer_q8)
         = (select count(case when items_count = 0 then 1 end) from core.fact_order)

union all
-- 9: платежи 2018 по штатам равны всем платежам 2018
select '10. q9: платежи 2018 по штатам = платежи 2018',
       ((select count(*)::text
           from core.fact_payment p
           join core.fact_order fo on fo.order_id = p.order_id
          where fo.purchased_at >= date '2018-01-01'
            and fo.purchased_at <  date '2019-01-01')::text),
       ((select sum(payments)::text from mart.answer_q9_state)::text),
       (select count(*)
          from core.fact_payment p
          join core.fact_order fo on fo.order_id = p.order_id
         where fo.purchased_at >= date '2018-01-01'
           and fo.purchased_at <  date '2019-01-01')
         = (select sum(payments) from mart.answer_q9_state)

union all
-- 9: разрез по способам оплаты покрывает все платежи, включая 3 not_defined
select '11. q9: способы оплаты покрывают все платежи',
       ((select count(*)::text from core.fact_payment)::text),
       ((select sum(payments)::text from mart.answer_q9_type)::text),
       (select count(*) from core.fact_payment)
         = (select sum(payments) from mart.answer_q9_type)

union all
-- 10: пять оценок и все заказы с отзывом и известной датой доставки
select '12. q10: оценки 1..5 покрывают все такие заказы',
       ((select count(distinct r.order_id)::text
           from core.fact_review r
           join core.fact_order fo on fo.order_id = r.order_id
          where r.review_score between 1 and 5
            and fo.delivery_days is not null)::text),
       ((select sum(orders)::text from mart.answer_q10)::text),
       (select count(distinct r.order_id)
          from core.fact_review r
          join core.fact_order fo on fo.order_id = r.order_id
         where r.review_score between 1 and 5
           and fo.delivery_days is not null)
         = (select sum(orders) from mart.answer_q10)
     and (select count(*) from mart.answer_q10) = 5;
