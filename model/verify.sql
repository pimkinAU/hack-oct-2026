\pset footer off

-- Гипотеза: выручка = сумма price (без доставки) по заказам status='delivered'

-- 1. Помесячно с календарём-спайном (24 месяца)
with months as (
  select generate_series(date '2016-09-01', date '2018-08-01', interval '1 month')::date as m
),
o as (
  select order_id, btrim(order_purchase_timestamp)::timestamp as purchased
  from raw.orders
  where order_status = 'delivered'
),
rev as (
  select order_id, sum(nullif(btrim(price),'')::numeric) as goods
  from raw.order_items group by order_id
)
select to_char(mm.m,'YYYY-MM') as month,
       count(o.order_id) as orders,
       round(coalesce(sum(r.goods),0), 2) as revenue
from months mm
left join o on date_trunc('month', o.purchased) = mm.m::timestamp
left join rev r using (order_id)
group by mm.m
order by mm.m;

-- 2. Итого по спайну и просто группировкой (сколько строк без календаря)
with o as (
  select order_id, btrim(order_purchase_timestamp)::timestamp as purchased
  from raw.orders where order_status = 'delivered'
),
rev as (select order_id, sum(nullif(btrim(price),'')::numeric) as goods from raw.order_items group by order_id)
select count(distinct to_char(purchased,'YYYY-MM')) as months_in_data,
       round(sum(r.goods),2) as total
from o join rev r using (order_id)
where purchased >= date '2016-09-01' and purchased < date '2018-09-01';

-- 3. Топ-10 продавцов (выручка = price, delivered)
with it as (
  select i.order_id, i.seller_id, nullif(btrim(i.price),'')::numeric as price
  from raw.order_items i join raw.orders o using (order_id)
  where o.order_status = 'delivered'
)
select seller_id,
       count(distinct order_id) as orders,
       count(*) as units,
       round(sum(price),2) as revenue
from it group by seller_id order by revenue desc limit 10;

-- 4. Средний чек: товар+доставка и только товар, по delivered
with o as (select order_id from raw.orders where order_status = 'delivered'),
it as (
  select i.order_id,
         sum(nullif(btrim(i.price),'')::numeric) as goods,
         sum(nullif(btrim(i.price),'')::numeric + nullif(btrim(i.freight_value),'')::numeric) as full_check,
         count(*) as lines
  from raw.order_items i join o using (order_id)
  group by i.order_id
)
select count(*) as orders,
       round(avg(full_check),2) as avg_full_check,
       round(avg(goods),2) as avg_goods_check,
       round(avg(lines),2) as avg_lines,
       round(avg(lines),2) as avg_units
from it;

-- 5. Контроль "неверных" ответов 123.75 и 139.97: уровень позиции
select round(sum(nullif(btrim(i.price),'')::numeric) / count(*), 2) as per_item_goods,
       round(sum(nullif(btrim(i.price),'')::numeric + nullif(btrim(i.freight_value),'')::numeric) / count(*), 2) as per_item_full,
       count(*) as items
from raw.order_items i join raw.orders o using (order_id)
where o.order_status = 'delivered';

-- 6. Категории: 74 строки, крупнейшая, сумма
with it as (
  select coalesce(nullif(btrim(t.product_category_name_english),''),
                  nullif(btrim(p.product_category_name),''),
                  'not_available') as cat,
         nullif(btrim(i.price),'')::numeric as price
  from raw.order_items i
  join raw.orders o using (order_id)
  left join raw.products p using (product_id)
  left join raw.product_category_translation t using (product_category_name)
  where o.order_status = 'delivered'
)
select cat, round(sum(price),2) as revenue
from it group by cat order by revenue desc limit 5;

with it as (
  select coalesce(nullif(btrim(t.product_category_name_english),''),
                  nullif(btrim(p.product_category_name),''),
                  'not_available') as cat,
         nullif(btrim(i.price),'')::numeric as price
  from raw.order_items i
  join raw.orders o using (order_id)
  left join raw.products p using (product_id)
  left join raw.product_category_translation t using (product_category_name)
  where o.order_status = 'delivered'
)
select count(distinct cat) as n_cats, round(sum(price),2) as total from it;

-- сколько даст группировка, если переводить в один 'not_available'
with it as (
  select coalesce(nullif(btrim(t.product_category_name_english),''), 'not_available') as cat,
         nullif(btrim(i.price),'')::numeric as price
  from raw.order_items i
  join raw.orders o using (order_id)
  left join raw.products p using (product_id)
  left join raw.product_category_translation t using (product_category_name)
  where o.order_status = 'delivered'
)
select count(distinct cat) as n_cats_if_collapsed from it;

-- 7. Покупатели
select count(distinct customer_unique_id) as uniq,
       count(distinct customer_id) as per_order_ids
from raw.customers;

select round(avg(lines),4) as avg_lines, round(avg(units),4) as avg_units from (
  select o.order_id, count(*) as lines, count(*) as units
  from raw.orders o join raw.order_items i using (order_id)
  where o.order_status = 'delivered' group by 1
) x;

-- 8. Сентябрь и декабрь 2016 поштучно
select order_id, order_status, order_purchase_timestamp, order_delivered_customer_date
from raw.orders
where btrim(order_purchase_timestamp)::timestamp < date '2017-01-01'
order by order_purchase_timestamp;

-- 9. Есть ли заказы с датой доставки вне месяца покупки (для спайна важно)
select count(*) as delivered_total,
       count(*) filter (where btrim(order_delivered_customer_date)::timestamp >= date '2018-09-01') as late_delivery
from raw.orders where order_status = 'delivered';
