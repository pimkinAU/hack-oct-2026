-- =====================================================================
--  Проверки блока Б и истории (05_history.sql, 06_block_b.sql).
--
--  Как и в 04_checks.sql, смотрим на колонку ok: везде должно быть t.
--  Смысл тот же — это не украшение, а способ при следующей загрузке
--  сразу увидеть, что сломалось: версия измерения нашла не каждый заказ,
--  ответ по статусам перестал сходиться с числом заказов, в отчёт по
--  штатам попали штаты ниже порога.
-- =====================================================================

-- В контейнере Docker маленький /dev/shm (64 МБ по умолчанию), а проверки
-- ниже делают большие хеш-соединения. Параллельный план просит общую память
-- и падает с «No space left on device», поэтому для этого файла параллельность
-- выключена. На результат это не влияет, только на скорость.
set max_parallel_workers_per_gather = 0;

select '1. у каждого человека ровно одна действующая версия адреса' as check_name,
       (select count(distinct customer_unique_id)::text from core.dim_customer_history) as expected,
       (select count(case when is_current then 1 end)::text from core.dim_customer_history) as actual,
       (select count(distinct customer_unique_id) from core.dim_customer_history)
         = (select count(case when is_current then 1 end) from core.dim_customer_history) as ok

union all
-- интервалы версий не должны пересекаться: иначе заказ получил бы два адреса
select '2. версии адресов не пересекаются',
       '0',
       ((select count(*)
           from core.dim_customer_history a
           join core.dim_customer_history b
             on  b.customer_unique_id = a.customer_unique_id
            and b.valid_from > a.valid_from
            and b.valid_from <= a.valid_to)::text),
       (select count(*)
          from core.dim_customer_history a
          join core.dim_customer_history b
            on  b.customer_unique_id = a.customer_unique_id
           and b.valid_from > a.valid_from
           and b.valid_from <= a.valid_to) = 0

union all
-- каждый заказ должен получить ровно одну версию адреса на свою дату
select '3. каждый заказ получил один адрес на дату заказа',
       ((select count(*) from core.fact_order where purchased_at is not null)::text),
       ((select count(*) from core.v_order_customer_address)::text),
       (select count(*) from core.fact_order where purchased_at is not null)
         = (select count(*) from core.v_order_customer_address)

union all
-- категория на дату заказа должна найтись для каждой позиции
select '4. каждая позиция получила категорию на дату заказа',
       ((select count(*) from core.fact_order_item)::text),
       ((select count(*) from core.v_item_category_as_ordered)::text),
       (select count(*) from core.fact_order_item)
         = (select count(*) from core.v_item_category_as_ordered)

union all
-- деньги, посчитанные через историю категорий, равны выручке блока А
select '5. выручка через историю = выручка блока А',
       '13221498.11',
       ((select round(sum(i.price), 2)::text
           from core.fact_order_item i
           join core.fact_order fo on fo.order_id = i.order_id
           join core.dim_product_category_history h
             on  h.product_id = i.product_id
            and fo.purchased_at::date between h.valid_from and h.valid_to
          where i.is_revenue)::text),
       (select round(sum(i.price), 2)
          from core.fact_order_item i
          join core.fact_order fo on fo.order_id = i.order_id
          join core.dim_product_category_history h
            on  h.product_id = i.product_id
           and fo.purchased_at::date between h.valid_from and h.valid_to
         where i.is_revenue) = 13221498.11::numeric

union all
select '6. у продавца одна версия адреса (снимок один)',
       ((select count(*) from core.dim_seller)::text),
       ((select count(*) from core.dim_seller_history)::text),
       (select count(*) from core.dim_seller) = (select count(*) from core.dim_seller_history)

union all
-- 6: выбранный товар действительно лидер по числу разных цен
select '7. q6: у товара максимум разных цен в данных',
       ((select max(k)::text from (
             select count(distinct price) as k
               from core.fact_order_item
              where product_id is not null
              group by product_id) t)::text),
       ((select price_variants::text from mart.answer_q6_product)::text),
       (select max(k) from (
             select count(distinct price) as k
               from core.fact_order_item
              where product_id is not null
              group by product_id) t)
         = (select price_variants from mart.answer_q6_product)

union all
-- 7: порог 500 соблюдён у каждой строки и ни один годный штат не потерян
select '8. q7: порог 500 и все годные штаты',
       ((select count(*) from (
             select cu.customer_state
               from core.fact_order fo
               join core.dim_customer cu on cu.customer_id = fo.customer_id
              where fo.is_revenue and fo.delivery_days is not null
              group by cu.customer_state
             having count(*) >= 500) t)::text),
       ((select count(*)::text from mart.answer_q7)::text),
       (select count(*) from (
             select cu.customer_state
               from core.fact_order fo
               join core.dim_customer cu on cu.customer_id = fo.customer_id
              where fo.is_revenue and fo.delivery_days is not null
              group by cu.customer_state
             having count(*) >= 500) t)
         = (select count(*) from mart.answer_q7)
     and (select min(orders) from mart.answer_q7) >= 500

union all
-- 8: воронка статусов обязана покрыть все заказы
select '9. q8: статусы покрывают все заказы',
       ((select count(*)::text from core.fact_order)::text),
       ((select sum(orders)::text from mart.answer_q8)::text),
       (select count(*) from core.fact_order) = (select sum(orders) from mart.answer_q8)
     and (select abs(sum(share_pct) - 100.0) from mart.answer_q8) < 0.1
     and (select sum(orders_without_items) from mart.answer_q8)
         = (select count(case when items_count = 0 then 1 end) from core.fact_order)

union all
-- 9: платежи 2018 по штатам равны всем платежам 2018
select '10. q9: платежи 2018 по штатам = платежи 2018',
       ((select count(*)::text
           from core.fact_payment p
           join core.fact_order fo on fo.order_id = p.order_id
          where fo.purchased_at >= date '2018-01-01'
            and fo.purchased_at <  date '2019-01-01')::text),
       ((select sum(payments)::text from mart.answer_q9_state)::text),
       (select count(*)
          from core.fact_payment p
          join core.fact_order fo on fo.order_id = p.order_id
         where fo.purchased_at >= date '2018-01-01'
           and fo.purchased_at <  date '2019-01-01')
         = (select sum(payments) from mart.answer_q9_state)

union all
-- 9: разрез по способам оплаты покрывает все платежи, включая 3 not_defined
select '11. q9: способы оплаты покрывают все платежи',
       ((select count(*)::text from core.fact_payment)::text),
       ((select sum(payments)::text from mart.answer_q9_type)::text),
       (select count(*) from core.fact_payment)
         = (select sum(payments) from mart.answer_q9_type)

union all
-- 10: пять оценок и все заказы с отзывом и известной датой доставки
select '12. q10: оценки 1..5 покрывают все такие заказы',
       ((select count(distinct r.order_id)::text
           from core.fact_review r
           join core.fact_order fo on fo.order_id = r.order_id
          where r.review_score between 1 and 5
            and fo.delivery_days is not null)::text),
       ((select sum(orders)::text from mart.answer_q10)::text),
       (select count(distinct r.order_id)
          from core.fact_review r
          join core.fact_order fo on fo.order_id = r.order_id
         where r.review_score between 1 and 5
           and fo.delivery_days is not null)
         = (select sum(orders) from mart.answer_q10)
     and (select count(*) from mart.answer_q10) = 5;
