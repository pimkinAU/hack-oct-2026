\pset footer off

-- нулевые и отрицательные деньги
select count(*) filter (where price = 0)      as items_price_zero,
       count(*) filter (where price < 0)      as items_price_negative,
       count(*) filter (where freight_value = 0) as items_freight_zero,
       count(*) filter (where item_total < 0) as items_negative
from core.fact_order_item;

-- где именно нулевые позиции: есть ли среди них выручка
select fo.order_status, count(*) as items, round(sum(i.price),2) as price_sum
from core.fact_order_item i join core.fact_order fo using (order_id)
where i.price = 0
group by 1 order by 2 desc;

-- 4 заказа без платежей и 775 без позиций: какие статусы
select fo.order_status, count(*)
from core.fact_order fo where fo.paid_total = 0 group by 1;

-- 1412 заказа, где оплата не равна сумма+доставка: насколько расходятся
with d as (
  select fo.order_id, fo.order_status, fo.paid_total - fo.order_total as diff
  from core.fact_order fo
  where fo.items_count > 0 and abs(fo.paid_total - fo.order_total) > 0.01
)
select count(*) as orders_differ,
       round(sum(diff) ,2) as sum_diff,
       round(min(diff),2) as min_diff,
       round(max(diff),2) as max_diff,
       count(*) filter (where abs(diff) > 1) as differ_over_1
from d;

-- доставка: сроки и просрочки по модели
select count(*) as delivered,
       count(*) filter (where is_delayed) as delayed,
       round(100.0 * count(*) filter (where is_delayed) / count(*), 2) as delayed_pct,
       round(avg(delivery_days)::numeric, 2) as avg_days,
       percentile_cont(0.5) within group (order by delivery_days) as median_days
from core.fact_order
where is_revenue and delivered_at is not null;

-- просрочка и средняя оценка: связано ли
select fo.is_delayed,
       count(*) as orders,
       round(avg(fo.review_score_avg), 2) as avg_review
from core.fact_order fo
where fo.is_revenue and fo.is_delayed is not null and fo.review_score_avg is not null
group by 1 order by 1;

-- распределение оценок
select r.review_score, count(*) as reviews,
       round(100.0 * count(*) / sum(count(*)) over (), 2) as pct
from core.fact_review r
where r.review_score is not null
group by 1 order by 1;

-- попытки объяснить 123.75 из условия задачи
select round(sum(price) / count(*), 2) as all_items_goods,
       round(sum(price) filter (where is_revenue) / count(*) filter (where is_revenue), 2) as delivered_items_goods,
       round(sum(item_total) / count(*), 2) as all_items_full,
       count(*) as items
from core.fact_order_item;

-- заказы, у которых покупатели «повторные»: сколько у них заказов
with c as (
  select customer_unique_id, count(*) as orders
  from core.dim_customer group by 1
)
select orders, count(*) as customers from c group by 1 order by 1;

-- города покупателей и продавцов: топ-5 по выручке
select fo.month_start is not null as ok, coalesce(cu.customer_state, '?') as state,
       round(sum(fo.goods_total),2) as revenue
from core.fact_order fo join core.dim_customer cu using (customer_id)
where fo.is_revenue
group by 2 order by 3 desc limit 5;

-- отзывы раньше доставки? логика дат
select count(*) as reviews_before_delivery
from core.fact_review r join core.fact_order fo using (order_id)
where fo.delivered_at is not null and r.created_at < fo.delivered_at;

select count(*) as orders_no_delivered_at_but_status_delivered
from core.fact_order where is_revenue and delivered_at is null;

select count(*) as orders_delivered_at_but_not_delivered_status
from core.fact_order where not is_revenue and delivered_at is not null;
