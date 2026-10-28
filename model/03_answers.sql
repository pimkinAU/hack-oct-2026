-- =====================================================================
--  Ответы на пять вопросов из docs/tasks.md (блок А).
--
--  Все запросы идут через схему core и витрины mart, напрямую к raw
--  ни один ответ не обращается. Ответы заодно сохраняем в таблицы
--  mart.answer_q1 ... answer_q5, чтобы цифры можно было перепроверить
--  и сравнить между запусками.
-- =====================================================================

drop table if exists mart.answer_q1;
drop table if exists mart.answer_q2;
drop table if exists mart.answer_q3;
drop table if exists mart.answer_q4;
drop table if exists mart.answer_q5;

\pset footer off


-- ---------------------------------------------------------------------
-- 1. Выручка и число заказов по месяцам, сентябрь 2016 — август 2018.
--
--    Идём от календаря, поэтому ноябрь 2016 никуда не пропадает: заказов
--    в том месяце не было вовсе, и обычная группировка orders дала бы
--    23 строки вместо 24.
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

select count(*)                as rows_expected_24,
       count(case when revenue = 0 then 1 end) as zero_months,
       round(sum(revenue), 2)  as total_expected_13221498_11
from mart.answer_q1;


-- ---------------------------------------------------------------------
-- 2. Топ-10 продавцов по выручке с городом и штатом.
--    Считаем по позициям: в заказе могут быть товары нескольких продавцов,
--    поэтому выручка продавца — это сумма цен только его товаров.
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

-- для сравнения: те же деньги, посчитанные по позиции (неверный уровень)
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
-- ---------------------------------------------------------------------
create table mart.answer_q4 as
select count(*)                                            as customers,
       count(case when orders_total > 1 then 1 end)        as returned,
       round(100.0 * count(case when orders_total > 1 then 1 end) / count(*), 2) as returned_pct
from mart.v_customer_base;

select '=== 4. Покупатели и возвраты ===' as answer;
select * from mart.answer_q4;

-- проверка, что unique_id не «гуляет»: у одного customer_unique_id
-- может быть несколько customer_id (это и есть повторные покупки),
-- но у одного customer_id только один unique_id
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
-- ---------------------------------------------------------------------
create table mart.answer_q5 as
select c.display_category,
       round(c.revenue, 2) as revenue,
       round(100.0 * c.revenue / t.total_revenue, 2) as share_pct
from mart.v_category_revenue c
cross join (select sum(revenue) as total_revenue from mart.v_category_revenue) t
order by c.revenue desc;

select '=== 5. Выручка по категориям (топ-15 из 74) ===' as answer;
select * from mart.answer_q5 limit 15;

select 'control' as check_name,
       count(*)                    as categories_expected_74,
       round(sum(revenue), 2)      as total_13221498_11,
       round(sum(share_pct), 1)    as shares_sum_pct
from mart.answer_q5;
