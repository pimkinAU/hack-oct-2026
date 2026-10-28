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
drop view if exists mart.v_order_status;
drop view if exists mart.v_delivery_state;


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
       max(ad.customer_city)                   as customer_city,
       max(ad.customer_state)                  as customer_state
from core.dim_customer cu
join core.fact_order fo on fo.customer_id = cu.customer_id
-- город и штат — ТЕКУЩИЙ адрес человека (последняя версия), а не
-- случайный из его заказов: адрес на момент заказа лежит в fact_order
left join core.dim_customer_address ad
       on ad.customer_unique_id = cu.customer_unique_id
      and ad.is_current
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


-- Воронка статусов: все заказы, в любом статусе. Сколько из них
-- без единой позиции — отдельной колонкой (это в основном unavailable
-- и canceled: заказ создан, а товара так и не оказалось).
create view mart.v_order_status as
select st.order_status,
       st.status_group,
       st.is_revenue,
       count(fo.order_id)                              as orders,
       count(case when fo.items_count = 0 then 1 end)  as orders_without_items
from core.dim_order_status st
left join core.fact_order fo on fo.order_status = st.order_status
group by st.order_status, st.status_group, st.is_revenue;


-- Доставка по штату покупателя. Штат — на момент заказа (из fact_order),
-- а не текущий: если человек переехал, его старые заказы остаются
-- в том штате, куда их везли. Только доставленные заказы, у которых
-- есть дата вручения, иначе срок доставки не посчитать.
create view mart.v_delivery_state as
select fo.customer_state,
       count(*)                                            as delivered_orders,
       count(case when fo.is_delayed then 1 end)           as delayed_orders,
       round(100.0 * count(case when fo.is_delayed then 1 end) / count(*), 2) as delayed_pct,
       round(avg(fo.delivery_days)::numeric, 2)            as avg_delivery_days
from core.fact_order fo
where fo.is_revenue
  and fo.delivery_days is not null
group by fo.customer_state;
