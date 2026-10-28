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
