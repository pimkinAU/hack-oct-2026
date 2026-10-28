\pset footer off

-- 1. Распределение заказов по месяцам
select to_char(btrim(order_purchase_timestamp)::timestamp, 'YYYY-MM') as m, count(*)
from raw.orders group by 1 order by 1;

-- 2. Диапазон дат и странные значения
select min(btrim(order_purchase_timestamp)) as min_raw,
       max(btrim(order_purchase_timestamp)) as max_raw,
       count(*) filter (where order_purchase_timestamp ~ '^\d{4}-\d{2}-\d{2}') as looks_like_date,
       count(*) as total
from raw.orders;

-- 3. Сетка вариантов выручки
with it as (
  select order_id,
         sum(nullif(btrim(price),'')::numeric) as goods,
         sum(nullif(btrim(freight_value),'')::numeric) as freight
  from raw.order_items group by order_id
),
pay as (
  select order_id, sum(nullif(btrim(payment_value),'')::numeric) as paid
  from raw.order_payments group by order_id
),
o as (
  select order_id, order_status,
         btrim(order_purchase_timestamp)::timestamp as purchased
  from raw.orders
),
j as (
  select o.order_id, o.order_status, o.purchased,
         coalesce(it.goods,0) as goods,
         coalesce(it.freight,0) as freight,
         coalesce(pay.paid,0) as paid
  from o
  left join it using (order_id)
  left join pay using (order_id)
  where purchased >= date '2016-09-01' and purchased < date '2018-09-01'
)
select 'goods only' as measure, 'all' as filt, round(sum(goods),2) from j
union all select 'goods only', 'not cancel/unavail', round(sum(goods),2) from j where order_status not in ('canceled','unavailable')
union all select 'goods only', 'delivered', round(sum(goods),2) from j where order_status = 'delivered'
union all select 'goods+freight', 'all', round(sum(goods+freight),2) from j
union all select 'goods+freight', 'not cancel/unavail', round(sum(goods+freight),2) from j where order_status not in ('canceled','unavailable')
union all select 'goods+freight', 'delivered', round(sum(goods+freight),2) from j where order_status = 'delivered'
union all select 'payments', 'all', round(sum(paid),2) from j
union all select 'payments', 'not cancel/unavail', round(sum(paid),2) from j where order_status not in ('canceled','unavailable')
union all select 'payments', 'delivered', round(sum(paid),2) from j where order_status = 'delivered'
order by 1,2;

-- 4. Те же варианты без ограничения по периоду (вся база)
with it as (
  select order_id,
         sum(nullif(btrim(price),'')::numeric) as goods,
         sum(nullif(btrim(freight_value),'')::numeric) as freight
  from raw.order_items group by order_id
),
o as (select order_id, order_status from raw.orders)
select 'items goods' as measure, 'all' as filt, round(sum(it.goods),2) as v, count(*) from it join o using(order_id)
union all select 'items goods', 'not cancel/unavail', round(sum(it.goods),2), count(*) from it join o using(order_id) where o.order_status not in ('canceled','unavailable')
union all select 'items goods+freight', 'not cancel/unavail', round(sum(it.goods+it.freight),2), count(*) from it join o using(order_id) where o.order_status not in ('canceled','unavailable')
union all select 'payments all statuses', 'all', round(sum(nullif(btrim(payment_value),'')::numeric),2), count(distinct order_id) from raw.order_payments
union all select 'payments of not-cancel orders', 'not cancel/unavail', round(sum(p.paid),2), count(*) from (select order_id, sum(nullif(btrim(payment_value),'')::numeric) paid from raw.order_payments group by 1) p join o using(order_id) where o.order_status not in ('canceled','unavailable');

-- 5. Контроль 226987.93: топ продавцов по variant goods+freight, not cancel/unavail
with it as (
  select order_id, seller_id,
         sum(nullif(btrim(price),'')::numeric + nullif(btrim(freight_value),'')::numeric) as rev
  from raw.order_items group by 1,2
)
select i.seller_id, round(sum(i.rev),2) as rev
from it i join raw.orders o using (order_id)
where o.order_status not in ('canceled','unavailable')
group by 1 order by 2 desc limit 3;

-- 6. Топ категорий по goods+freight
with it as (
  select i.order_id, coalesce(nullif(btrim(p.product_category_name),''),'unknown') as cat,
         sum(nullif(btrim(i.price),'')::numeric + nullif(btrim(i.freight_value),'')::numeric) as rev
  from raw.order_items i left join raw.products p using (product_id)
  group by 1,2
)
select cat, round(sum(it.rev),2) as rev
from it join raw.orders o using (order_id)
where o.order_status not in ('canceled','unavailable')
group by 1 order by 2 desc limit 3;

-- 7. Дубли в отзывах
select count(*) as rows, count(distinct review_id) as uniq_ids,
       count(distinct (review_id, order_id)) as uniq_id_order
from raw.order_reviews;

select review_id, count(*) from raw.order_reviews group by review_id having count(*) > 1 limit 3;

-- 8. Заказы без позиций и позиции у несуществующих заказов
select count(*) as orders_without_items
from raw.orders o left join (select distinct order_id from raw.order_items) i using (order_id)
where i.order_id is null;

select order_status, count(*) from raw.orders o
left join (select distinct order_id from raw.order_items) i using (order_id)
where i.order_id is null group by 1 order by 2 desc;

-- 9. Средний чек по вариантам (все заказы с позициями)
with it as (
  select order_id,
         sum(nullif(btrim(price),'')::numeric) as goods,
         sum(nullif(btrim(freight_value),'')::numeric) as freight,
         count(*) as lines
  from raw.order_items group by order_id
)
select round(sum(goods)/count(*),2) as avg_goods_check,
       round(sum(goods+freight)/count(*),2) as avg_full_check,
       round(avg(lines),4) as avg_lines,
       count(*) as orders
from it;
