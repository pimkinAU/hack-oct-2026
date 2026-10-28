-- Разведка: ключи, пропуски, статусы, гипотезы по выручке

\pset footer off

-- 1. Ключи: что однозначно определяет строку
select 'orders: rows/distinct order_id' as chk,
       count(*)::text || ' / ' || count(distinct order_id)::text as val
from raw.orders
union all
select 'order_items: rows/distinct(order_id,item_id)',
       count(*)::text || ' / ' || count(distinct (order_id, order_item_id))::text
from raw.order_items
union all
select 'order_items: distinct order_id', count(distinct order_id)::text from raw.order_items
union all
select 'payments: rows/distinct(order_id,seq)',
       count(*)::text || ' / ' || count(distinct (order_id, payment_sequential))::text
from raw.order_payments
union all
select 'reviews: rows/distinct review_id',
       count(*)::text || ' / ' || count(distinct review_id)::text
from raw.order_reviews
union all
select 'reviews: distinct order_id', count(distinct order_id)::text from raw.order_reviews
union all
select 'customers: rows/customer_id/unique_id',
       count(*)::text || ' / ' || count(distinct customer_id)::text || ' / ' || count(distinct customer_unique_id)::text
from raw.customers
union all
select 'products: rows/distinct', count(*)::text || ' / ' || count(distinct product_id)::text from raw.products
union all
select 'sellers: rows/distinct', count(*)::text || ' / ' || count(distinct seller_id)::text from raw.sellers
union all
select 'translation: rows/distinct name',
       count(*)::text || ' / ' || count(distinct product_category_name)::text
from raw.product_category_translation;

-- 2. Статусы заказов
select order_status, count(*) as cnt,
       min(order_purchase_timestamp) as min_ts,
       max(order_purchase_timestamp) as max_ts
from raw.orders
group by 1 order by 2 desc;

-- 3. Гипотезы по выручке за сен-2016 .. авг-2018 (сумма price+freight по позициям)
with items as (
  select order_id,
         sum(nullif(btrim(price),'')::numeric + nullif(btrim(freight_value),'')::numeric) as total
  from raw.order_items
  group by order_id
),
o as (
  select order_id, order_status,
         btrim(order_purchase_timestamp)::timestamp as purchased
  from raw.orders
)
select 'A: все статусы' as variant, round(sum(i.total),2) as revenue, count(distinct o.order_id) as orders
from o join items i using (order_id)
where o.purchased >= date '2016-09-01' and o.purchased < date '2018-09-01'
union all
select 'B: без canceled/unavailable', sum(i.total), count(distinct o.order_id)
from o join items i using (order_id)
where o.order_status not in ('canceled','unavailable')
  and o.purchased >= date '2016-09-01' and o.purchased < date '2018-09-01'
union all
select 'C: только delivered', sum(i.total), count(distinct o.order_id)
from o join items i using (order_id)
where o.order_status = 'delivered'
  and o.purchased >= date '2016-09-01' and o.purchased < date '2018-09-01'
union all
select 'D: без unavailable', sum(i.total), count(distinct o.order_id)
from o join items i using (order_id)
where o.order_status <> 'unavailable'
  and o.purchased >= date '2016-09-01' and o.purchased < date '2018-09-01';

-- 4. Проверка контрольных цифр по варианту B: средний чек
with items as (
  select order_id,
         sum(nullif(btrim(price),'')::numeric + nullif(btrim(freight_value),'')::numeric) as total,
         count(*) as lines,
         count(*) as units
  from raw.order_items
  group by order_id
)
select round(sum(i.total) / count(*), 2) as avg_check,
       round(avg(i.lines), 3) as avg_lines,
       round(avg(i.units), 3) as avg_units
from raw.orders o join items i using (order_id)
where o.order_status not in ('canceled','unavailable');

-- 5. Месяцы: есть ли пустой месяц
select date_trunc('month', btrim(order_purchase_timestamp)::timestamp) as m,
       count(*) as orders_all,
       count(*) filter (where order_status not in ('canceled','unavailable')) as orders_revenue
from raw.orders
group by 1
having count(*) filter (where order_status not in ('canceled','unavailable')) = 0
    or count(*) < 100
order by 1;

-- 6. Пропуски в важных полях
select
  count(*) filter (where btrim(order_approved_at) = '' or order_approved_at is null) as no_approved,
  count(*) filter (where btrim(order_delivered_customer_date) = '' or order_delivered_customer_date is null) as no_delivered,
  count(*) filter (where btrim(order_delivered_carrier_date) = '' or order_delivered_carrier_date is null) as no_carrier
from raw.orders;

select count(*) filter (where btrim(product_category_name) = '' or product_category_name is null) as no_category,
       count(*) as products_total
from raw.products;

select count(*) filter (where btrim(freight_value) = '' or freight_value is null
                          or btrim(price) = '' or price is null) as bad_money
from raw.order_items;

-- 7. Категории: сколько и есть ли без перевода
select count(distinct p.product_category_name) as cats_in_products
from raw.products p;

select count(distinct coalesce(nullif(btrim(p.product_category_name),''), '__MISSING__')) as cats_in_items
from raw.order_items i
join raw.products p using (product_id);

select p.product_category_name as missing_in_translation
from raw.products p
left join raw.product_category_translation t using (product_category_name)
where nullif(btrim(p.product_category_name),'') is not null
  and t.product_category_name is null
group by 1;

-- 8. Потери на соединениях
select count(*) as items_total,
       count(i.product_id) as with_product,
       count(p.product_id) as matched_product,
       count(s.seller_id) as matched_seller,
       count(c.customer_id) as matched_customer
from raw.order_items i
left join raw.products p using (product_id)
left join raw.sellers s using (seller_id)
left join raw.orders o using (order_id)
left join raw.customers c on c.customer_id = o.customer_id;

select count(*) as orders_total,
       count(i.order_id) as orders_with_items,
       count(pay.order_id) as orders_with_payments
from raw.orders o
left join (select distinct order_id from raw.order_items) i using (order_id)
left join (select distinct order_id from raw.order_payments) pay using (order_id);

-- 9. Повторные покупки по обоим ключам
select count(distinct customer_unique_id) as uniq_customers,
       count(distinct customer_id) as order_level_customers
from raw.customers;

with c as (
  select c.customer_unique_id, count(distinct o.order_id) as orders
  from raw.customers c join raw.orders o using (customer_id)
  group by 1
)
select count(*) as total,
       count(*) filter (where orders > 1) as returned,
       round(100.0 * count(*) filter (where orders > 1) / count(*), 2) as pct
from c;

-- 10. Дубли customer_unique_id в customers (бывает ли один unique_id на нескольких customer_id)
select customer_unique_id, count(*) as n
from raw.customers
group by 1 having count(*) > 1
order by n desc limit 5;

-- 11. Отзывы: один отзыв на заказ?
select n_reviews, count(*) as orders from (
  select order_id, count(*) as n_reviews from raw.order_reviews group by 1
) x group by 1 order by 1;

-- 12. Платежи: суммы против цены+доставка
with pay as (
  select order_id, sum(nullif(btrim(payment_value),'')::numeric) as paid
  from raw.order_payments group by 1
),
it as (
  select order_id, sum(nullif(btrim(price),'')::numeric + nullif(btrim(freight_value),'')::numeric) as goods
  from raw.order_items group by 1
)
select count(*) as orders_both,
       count(*) filter (where abs(coalesce(p.paid,0) - coalesce(i.goods,0)) < 0.01) as matches,
       count(*) filter (where abs(coalesce(p.paid,0) - coalesce(i.goods,0)) >= 0.01) as differs
from pay p full join it i using (order_id);
