\pset footer off

-- цифры для документа по дашборду

-- просрочка по месяцам
select to_char(fo.month_start,'YYYY-MM') as month,
       count(*) as delivered,
       count(*) filter (where fo.is_delayed) as delayed,
       round(100.0 * count(*) filter (where fo.is_delayed) / count(*), 2) as delayed_pct,
       round(avg(fo.review_score_avg), 2) as avg_review
from core.fact_order fo
where fo.is_revenue and fo.is_delayed is not null
group by 1 order by 1;

-- просрочка по штату продавца (только крупные штаты)
select i.seller_state,
       count(distinct i.order_id) as orders,
       count(distinct i.order_id) filter (where fo.is_delayed) as delayed,
       round(100.0 * count(distinct i.order_id) filter (where fo.is_delayed)
             / nullif(count(distinct i.order_id), 0), 2) as delayed_pct,
       round(avg(fo.review_score_avg), 2) as avg_review,
       round(sum(i.price), 2) as revenue
from core.fact_order_item i
join core.fact_order fo using (order_id)
where i.is_revenue and fo.is_delayed is not null
group by 1 having count(distinct i.order_id) > 1000
order by delayed_pct desc;

-- просрочка бьёт по выручке: сколько денег в.Delayed заказах
select case when fo.is_delayed then 'просрочен' else 'вовремя' end as grp,
       count(*) as orders,
       round(sum(fo.goods_total), 2) as revenue,
       round(avg(fo.review_score_avg), 2) as avg_review,
       count(*) filter (where fo.review_score_avg <= 2) as bad_reviews,
       round(100.0 * count(*) filter (where fo.review_score_avg <= 2)
             / nullif(count(*) filter (where fo.review_score_avg is not null), 0), 2) as bad_reviews_pct
from core.fact_order fo
where fo.is_revenue and fo.is_delayed is not null
group by 1;

-- задержка продавца: передали в доставку позже срока отгрузки
with o as (
  select order_id,
         min(shipping_limit_date) as limit_date,
         min(carrier_at) as carrier_at
  from core.fact_order_item i join core.fact_order fo using (order_id)
  where fo.is_revenue
  group by 1
)
select count(*) as orders,
       count(*) filter (where carrier_at is not null and limit_date is not null) as measurable,
       count(*) filter (where carrier_at > limit_date) as seller_late,
       round(100.0 * count(*) filter (where carrier_at > limit_date)
             / nullif(count(*) filter (where carrier_at is not null and limit_date is not null), 0), 2) as seller_late_pct
from o;

-- отклонение от обещанного срока в днях: распределение
select width_bucket(extract(epoch from (delivered_at::date - estimated_delivery_date))/86400,
                   -30, 60, 18) as bucket,
       min(extract(epoch from (delivered_at::date - estimated_delivery_date))/86400)::int as min_days,
       count(*)
from core.fact_order
where is_revenue and delivered_at is not null and estimated_delivery_date is not null
group by 1 order by 1;

-- доля доставки в чеке
select round(sum(freight_total) / sum(goods_total) * 100, 2) as freight_share_of_goods_pct,
       round(sum(freight_total), 2) as freight_total,
       round(sum(goods_total), 2)   as goods_total
from core.fact_order
where is_revenue;

-- доля отзывов 1-2 по месяцам
select to_char(r.month_start,'YYYY-MM') as month,
       round(100.0 * count(*) filter (where r.review_score <= 2) / count(*), 2) as bad_review_pct,
       count(*) as reviews
from core.fact_review r
where r.month_start is not null and r.review_score is not null
group by 1 having count(*) > 200
order by bad_review_pct desc limit 6;
