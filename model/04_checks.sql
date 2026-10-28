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
