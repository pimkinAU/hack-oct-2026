-- =====================================================================
--  Проверки модели. Запускаем после 01 и 02, смотрим на колонку ok.
--
--  Смысл не в том, чтобы один раз увидеть галочки, а в том, чтобы при
--  следующей загрузке данных эти же запросы сразу показали, что сломалось:
--  пропали строки на join, изменилась общая выручка, появился заказ без
--  покупателя.
-- =====================================================================

\pset footer off

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
