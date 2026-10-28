-- =====================================================================
--  Ответы на десять вопросов из docs/tasks.md (блоки А и Б).
--
--  Все запросы идут через схему core и витрины mart, напрямую к raw
--  ни один ответ не обращается. Ответы заодно сохраняем в таблицы
--  mart.answer_q1 ... answer_q10, чтобы цифры можно было перепроверить
--  и сравнить между запусками.
--
--  Общие правила для всех ответов:
--    * выручка = сумма price по позициям, без доставки (freight);
--    * в выручку идут только заказы с is_revenue = true. Этот флаг
--      выставлен один раз в core.dim_order_status (сейчас это только
--      статус delivered) и дальше копируется в fact_order и
--      fact_order_item, так что список статусов здесь не повторяется;
--    * у каждого ответа есть контрольный select: он сверяет результат
--      с контрольными цифрами из задания (24 месяца, 13 221 498.11,
--      159.88, 96 096 / 3.12%, 74 категории). У блока Б контрольных
--      цифр в задании нет, там контрольный select сверяет ответ с
--      итогами модели (все заказы, все платежи и т.п.);
--    * штат покупателя (вопросы 7 и 9) — на момент заказа, из
--      core.fact_order, а не текущий адрес человека.
--
--  Порядок блока в каждом вопросе один и тот же:
--    1) create table mart.answer_qN — сам ответ;
--    2) select-заголовок '=== N ... ===', чтобы в выводе psql было
--       видно, где какой ответ;
--    3) select * из таблицы ответа;
--    4) контрольный запрос (если он есть).
-- =====================================================================

-- Таблицы ответов пересоздаём на каждом запуске: так файл можно гонять
-- сколько угодно раз подряд, и результат всегда считается заново
-- из текущего состояния core/mart, а не берётся из старого прогона.
drop table if exists mart.answer_q1;
drop table if exists mart.answer_q2;
drop table if exists mart.answer_q3;
drop table if exists mart.answer_q4;
drop table if exists mart.answer_q5;
drop table if exists mart.answer_q6;
drop table if exists mart.answer_q7;
drop table if exists mart.answer_q8;
drop table if exists mart.answer_q9;
drop table if exists mart.answer_q9_type;
drop table if exists mart.answer_q10;


-- ---------------------------------------------------------------------
-- 1. Выручка и число заказов по месяцам, сентябрь 2016 — август 2018.
--
--    Идём от календаря, поэтому ноябрь 2016 никуда не пропадает: заказов
--    в том месяце не было вовсе, и обычная группировка orders дала бы
--    23 строки вместо 24.
--
--    Откуда берутся цифры:
--      mart.v_monthly_revenue — это core.dim_calendar (все месяцы
--      подряд) left join core.fact_order по month_start, только
--      заказы с is_revenue. Пустой месяц получает orders = 0
--      (count по null даёт 0) и revenue = 0 (через coalesce).
--
--    Колонки:
--      month   — месяц в виде 'YYYY-MM', чтобы было удобно читать
--                и сортировать как текст;
--      orders  — число доставленных заказов, оформленных в этом месяце
--                (месяц считаем по дате покупки, purchased_at);
--      revenue — сумма goods_total этих заказов, то есть только товары
--                без доставки, округлено до копеек.
--
--    Фильтр between берёт ровно 24 месяца. Календарь тянется до последней
--    даты заказа, поэтому в нём есть ещё 2018-09 и 2018-10 (20 заказов,
--    ни одного доставленного). По заданию в отчёт они не входят.
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

-- Контроль к вопросу 1:
--   rows_expected_24            — строк должно быть ровно 24 (по одной
--                                 на месяц, включая пустой ноябрь 2016);
--   zero_months                 — месяцев с нулевой выручкой, ожидаем 1
--                                 (это и есть 2016-11);
--   total_expected_13221498_11  — итог за весь период, должен совпасть
--                                 с общей выручкой 13 221 498.11.
--   Если строк 23, значит календарь потерялся и отчёт построен
--   от заказов, а не от месяцев.
select count(*)                as rows_expected_24,
       count(case when revenue = 0 then 1 end) as zero_months,
       round(sum(revenue), 2)  as total_expected_13221498_11
from mart.answer_q1;


-- ---------------------------------------------------------------------
-- 2. Топ-10 продавцов по выручке с городом и штатом.
--    Считаем по позициям: в заказе могут быть товары нескольких продавцов,
--    поэтому выручка продавца — это сумма цен только его товаров.
--
--    Почему не по fact_order: у заказа нет одного продавца. Если бы мы
--    приписали весь goods_total заказа каждому его продавцу, выручка
--    многопродавцовых заказов посчиталась бы несколько раз, и сумма
--    по продавцам оказалась бы больше общей выручки.
--
--    Откуда берутся цифры:
--      mart.v_seller_revenue — core.fact_order_item (только is_revenue),
--      сгруппированный по seller_id, с городом и штатом из
--      core.dim_seller (left join: продавец без карточки не выпадает,
--      просто будет без города).
--
--    Колонки:
--      orders  — в скольких разных заказах были товары продавца
--                (count distinct order_id);
--      units   — сколько позиций он продал; одна строка позиции =
--                одна единица товара, колонки количества в выгрузке нет;
--      revenue — сумма price его позиций, без доставки.
--
--    Сортировка: по выручке по убыванию, а при равной выручке — по
--    seller_id, чтобы десятка не менялась от запуска к запуску.
--    Контроль из задания: у первого продавца 226 987.93.
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
--
--    Колонки:
--      avg_check                 — средний order_total (товары + доставка)
--                                  по доставленным заказам, ответ: 159.88;
--      avg_lines                 — в среднем позиций (строк) в заказе;
--      avg_units                 — в среднем единиц товара в заказе.
--                                  Считается из того же items_count, что
--                                  и avg_lines, — см. пояснение про qty
--                                  выше; колонка оставлена отдельно, чтобы
--                                  ответ совпадал по форме с заданием;
--      avg_check_without_freight — средний goods_total, то есть чек без
--                                  доставки (137.04), для сравнения;
--      orders                    — сколько заказов вошло в среднее.
--
--    Заказы без позиций (их 775, в основном отменённые) сюда не
--    попадают: у них is_revenue = false, так что нулевые чеки
--    среднее не занижают.
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

-- Для сравнения: те же деньги, посчитанные по позиции (неверный уровень).
-- Здесь сумма делится на число строк позиций, а не на число заказов,
-- поэтому получается средняя стоимость одной позиции, а не чек:
--   goods_per_item — средняя цена товара в позиции (119.98);
--   full_per_item  — средняя позиция вместе с доставкой (139.97) —
--                    это ровно тот неверный ответ, о котором
--                    предупреждает задание.
-- Разница с 159.88 и есть те ~1.14 позиции на заказ.
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
--
--    Откуда берутся цифры:
--      mart.v_customer_base — одна строка на человека
--      (customer_unique_id), собранная из core.dim_customer и
--      core.fact_order. orders_total — все его заказы, в любом статусе.
--
--    Колонки:
--      customers    — сколько всего разных людей (строк в витрине),
--                     ответ: 96 096;
--      returned     — сколько из них сделали больше одного заказа;
--      returned_pct — доля вернувшихся в процентах, ответ: 3.12%.
--
--    «Вернулся» понимаем как «оформил второй заказ», поэтому берём
--    orders_total, а не orders_revenue: повторная покупка — это факт
--    оформления заказа, даже если его потом отменили. 100.0 в формуле
--    стоит для того, чтобы деление было дробным, а не целочисленным.
-- ---------------------------------------------------------------------
create table mart.answer_q4 as
select count(*)                                            as customers,
       count(case when orders_total > 1 then 1 end)        as returned,
       round(100.0 * count(case when orders_total > 1 then 1 end) / count(*), 2) as returned_pct
from mart.v_customer_base;

select '=== 4. Покупатели и возвраты ===' as answer;
select * from mart.answer_q4;

-- Проверка, что unique_id не «гуляет»: у одного customer_unique_id
-- может быть несколько customer_id (это и есть повторные покупки),
-- но у одного customer_id только один unique_id.
-- Ожидаем:
--   rows            = order_level_ids = 99 441 — customer_id уникален,
--                     одна строка на одну запись «покупатель в заказе»;
--   humans          = 96 096 — столько же, сколько customers в ответе.
-- Если бы rows был больше order_level_ids, у какого-то customer_id
-- оказалось бы несколько людей, и счёт по unique_id был бы неверным.
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
--
--    Откуда берутся цифры:
--      mart.v_category_revenue — core.fact_order_item (только is_revenue),
--      сгруппированный по display_category. display_category — это
--      английское название, если перевод есть, иначе португальское,
--      а для пустой категории — not_available.
--
--    Колонки:
--      display_category — название категории для отчёта;
--      revenue          — сумма price позиций этой категории;
--      share_pct        — доля категории в общей выручке, в процентах.
--
--    Знаменатель доли считаем подзапросом t по той же витрине и
--    подклеиваем его к каждой строке через cross join (у t ровно одна
--    строка). Так числитель и знаменатель гарантированно посчитаны
--    по одному набору позиций, и доли в сумме дают 100%.
-- ---------------------------------------------------------------------
create table mart.answer_q5 as
select c.display_category,
       round(c.revenue, 2) as revenue,
       round(100.0 * c.revenue / t.total_revenue, 2) as share_pct
from mart.v_category_revenue c
cross join (select sum(revenue) as total_revenue from mart.v_category_revenue) t
order by c.revenue desc;

-- В таблице ответа лежат все 74 категории, а на экран выводим
-- только первые 15 по выручке, чтобы вывод не растягивался.
select '=== 5. Выручка по категориям (топ-15 из 74) ===' as answer;
select * from mart.answer_q5 limit 15;

-- Контроль к вопросу 5:
--   categories_expected_74 — 73 категории с продажами + not_available;
--   total_13221498_11      — сумма по категориям равна общей выручке,
--                            то есть ни одна позиция не потерялась;
--   shares_sum_pct         — сумма долей, ожидаем 100.0 (возможна
--                            разница в сотые из-за округления каждой
--                            доли до двух знаков).
select 'control' as check_name,
       count(*)                    as categories_expected_74,
       round(sum(revenue), 2)      as total_13221498_11,
       round(sum(share_pct), 1)    as shares_sum_pct
from mart.answer_q5;


-- =====================================================================
--  Блок Б.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 6. Как менялась цена одного товара.
--
--    Берём товар, который продавался по наибольшему числу разных цен,
--    и показываем, по какой цене и сколько его продали в каждый день.
--
--    Откуда берутся цифры:
--      core.fact_order_item, только is_revenue: «продавался» понимаем
--      так же, как выручку, — заказ дошёл до покупателя. Цена — price
--      позиции, без доставки. Дата — день покупки (purchased_at).
--
--    Выбор товара: count(distinct price) по товару, при равенстве —
--    меньший product_id, чтобы ответ не менялся от запуска к запуску.
--    Подзапрос p — ровно одна строка, к позициям он цепляется join-ом.
--
--    Колонки:
--      sale_date  — день покупки;
--      price      — цена позиции;
--      units_sold — сколько единиц продано в этот день по этой цене
--                   (одна строка позиции = одна единица, как и в вопросе 2).
--    Если в один день товар уходил по двум ценам, строк за день будет две.
-- ---------------------------------------------------------------------
create table mart.answer_q6 as
select i.purchased_at::date as sale_date,
       i.price,
       count(*)             as units_sold
from core.fact_order_item i
join (
    select product_id
    from core.fact_order_item
    where is_revenue
    group by product_id
    order by count(distinct price) desc, product_id
    limit 1
) p on p.product_id = i.product_id
where i.is_revenue
group by i.purchased_at::date, i.price
order by sale_date, price;

select '=== 6. История цены товара ===' as answer;

-- какой товар выбран и сколько у него разных цен
select i.product_id,
       max(i.display_category)  as category,
       count(distinct i.price)  as distinct_prices,
       min(i.price)             as min_price,
       max(i.price)             as max_price,
       count(*)                 as units_sold
from core.fact_order_item i
where i.is_revenue
group by i.product_id
order by count(distinct i.price) desc, i.product_id
limit 1;

select * from mart.answer_q6;

-- Контроль к вопросу 6: число разных цен в ответе равно максимуму
-- по всем товарам, единицы в сумме равны продажам товара.
select count(distinct price) as distinct_prices,
       sum(units_sold)       as units_total
from mart.answer_q6;


-- ---------------------------------------------------------------------
-- 7. Доставка по штатам покупателя.
--
--    Только штаты, где не меньше 500 заказов.
--
--    Откуда берутся цифры:
--      mart.v_delivery_state — core.fact_order, доставленные заказы
--      (is_revenue) с известной датой вручения, по штату покупателя.
--      Штат — на момент заказа: заказ везли туда, где человек жил тогда,
--      и переезд после заказа не должен перекидывать его в другой штат.
--
--    Колонки:
--      customer_state    — штат покупателя;
--      orders            — доставленных заказов, по ним же и порог 500;
--      avg_delivery_days — средний срок от покупки до вручения, в днях
--                          (разница дат, без часов);
--      delayed_pct       — доля заказов, привезённых позже обещанной даты
--                          (estimated_delivery_date), в процентах.
--
--    8 доставленных заказов без даты вручения сюда не входят: срок
--    для них не посчитать. Порог считаем по тем же заказам, что и средние,
--    чтобы 500 значило «500 заказов в среднем», а не «500 заказов вообще».
-- ---------------------------------------------------------------------
create table mart.answer_q7 as
select d.customer_state,
       d.delivered_orders as orders,
       d.avg_delivery_days,
       d.delayed_pct
from mart.v_delivery_state d
where d.delivered_orders >= 500
order by d.delivered_orders desc, d.customer_state;

select '=== 7. Доставка по штатам (от 500 заказов) ===' as answer;
select * from mart.answer_q7;

-- Контроль к вопросу 7: сколько штатов прошло порог и какую часть
-- доставленных заказов они покрывают.
select count(*)     as states,
       sum(orders)  as orders_in_report,
       (select sum(delivered_orders) from mart.v_delivery_state) as orders_all_states
from mart.answer_q7;


-- ---------------------------------------------------------------------
-- 8. Воронка статусов.
--
--    Сколько заказов в каждом статусе, их доля и сколько из них без
--    единой позиции.
--
--    Откуда берутся цифры:
--      mart.v_order_status — core.dim_order_status left join
--      core.fact_order. Здесь все заказы, в любом статусе: воронка про
--      заказы, а не про выручку. Заказы без позиций есть в fact_order
--      с items_count = 0 (их 775), поэтому они не теряются.
--
--    Колонки:
--      order_status         — статус;
--      orders               — заказов в статусе;
--      share_pct            — доля от всех заказов, в процентах;
--      orders_without_items — из них без единой позиции.
--
--    Порядок — по числу заказов: так видно, что воронка почти вся
--    в delivered, а без позиций остаются в основном unavailable и canceled.
-- ---------------------------------------------------------------------
create table mart.answer_q8 as
select s.order_status,
       s.orders,
       round(100.0 * s.orders / t.total_orders, 2) as share_pct,
       s.orders_without_items
from mart.v_order_status s
cross join (select sum(orders) as total_orders from mart.v_order_status) t
order by s.orders desc, s.order_status;

select '=== 8. Воронка статусов ===' as answer;
select * from mart.answer_q8;

-- Контроль к вопросу 8: заказов столько же, сколько в raw (99 441),
-- без позиций — 775, доли в сумме ~100%.
select sum(orders)               as orders_expected_99441,
       sum(orders_without_items) as without_items_expected_775,
       round(sum(share_pct), 1)  as shares_sum_pct
from mart.answer_q8;


-- ---------------------------------------------------------------------
-- 9. Способы оплаты и рассрочка.
--
--    Две таблицы: по штатам покупателя за 2018 год и по способам оплаты
--    за весь период.
--
--    Откуда берутся цифры:
--      core.fact_payment — одна строка = один способ оплаты одного заказа,
--      поэтому «число платежей» — это число строк, а не заказов: заказ,
--      оплаченный картой и ваучером, даёт два платежа.
--      Штат — из core.fact_order, на момент заказа. Год — по дате покупки.
--      Платежи берём только по заказам с is_revenue, как и всю выручку
--      в модели: деньги отменённых заказов вернулись покупателю.
--
--    Колонки (по штатам):
--      customer_state   — штат покупателя;
--      payments         — число платежей;
--      paid             — сумма payment_value (то, что заплатил покупатель,
--                         вместе с доставкой);
--      avg_installments — средний срок рассрочки, в платежах.
--    Колонки (по способам): payment_type, payments, avg_installments.
--
--    Рассрочка бывает только у карты, у boleto и ваучера она всегда 1,
--    поэтому средний срок по штату во многом говорит о доле карт.
-- ---------------------------------------------------------------------
create table mart.answer_q9 as
select fo.customer_state,
       count(*)                             as payments,
       round(sum(p.payment_value), 2)       as paid,
       round(avg(p.installments), 2)        as avg_installments
from core.fact_payment p
join core.fact_order fo on fo.order_id = p.order_id
where p.is_revenue
  and p.month_start between date '2018-01-01' and date '2018-12-01'
group by fo.customer_state
order by paid desc, fo.customer_state;

create table mart.answer_q9_type as
select p.payment_type,
       count(*)                             as payments,
       round(avg(p.installments), 2)        as avg_installments
from core.fact_payment p
where p.is_revenue
group by p.payment_type
order by payments desc, p.payment_type;

select '=== 9. Оплата по штатам за 2018 год ===' as answer;
select * from mart.answer_q9;

select '=== 9. Способы оплаты, весь период ===' as answer;
select * from mart.answer_q9_type;

-- Контроль к вопросу 9: сумма по штатам равна всем платежам 2018 года
-- по доставленным заказам (штат не потерялся на join), а число
-- платежей по способам — всем платежам доставленных заказов.
select (select sum(paid) from mart.answer_q9)       as paid_by_states,
       (select round(sum(payment_value), 2)
        from core.fact_payment
        where is_revenue
          and month_start between date '2018-01-01' and date '2018-12-01')
                                                    as paid_2018_total,
       (select sum(payments) from mart.answer_q9_type) as payments_by_type,
       (select count(*) from core.fact_payment where is_revenue)
                                                    as payments_total;


-- ---------------------------------------------------------------------
-- 10. Связь оценки покупателя со сроком доставки.
--
--    Для каждой оценки 1–5 — сколько заказов, средний срок доставки
--    и доля опозданий.
--
--    Откуда берутся цифры:
--      core.fact_review (одна строка = отзыв) + core.fact_order
--      (срок и опоздание считаются на заказ). Только доставленные заказы
--      с датой вручения, как в вопросе 7.
--
--    Уровень: оценка — свойство отзыва, а срок — свойство заказа.
--    Берём пары (заказ, оценка) через distinct: если у заказа два отзыва
--    с одной оценкой, он считается один раз; если оценки разные (бывает
--    у заказов с 2–3 отзывами), заказ попадает в обе строки — его срок
--    действительно связан с обеими оценками. Средний балл заказа
--    (review_score_avg) здесь не годится: 4.5 не попадает ни в одну оценку.
--
--    Колонки:
--      review_score      — оценка 1..5;
--      orders            — заказов с такой оценкой;
--      avg_delivery_days — средний срок доставки, в днях;
--      delayed_pct       — доля опоздавших заказов, в процентах.
-- ---------------------------------------------------------------------
create table mart.answer_q10 as
select r.review_score,
       count(*)                                            as orders,
       round(avg(fo.delivery_days)::numeric, 2)            as avg_delivery_days,
       round(100.0 * count(case when fo.is_delayed then 1 end) / count(*), 2) as delayed_pct
from (select distinct order_id, review_score
      from core.fact_review
      where review_score between 1 and 5) r
join core.fact_order fo on fo.order_id = r.order_id
where fo.is_revenue
  and fo.delivery_days is not null
group by r.review_score
order by r.review_score;

select '=== 10. Оценка и срок доставки ===' as answer;
select * from mart.answer_q10;

-- Контроль к вопросу 10: строк ровно 5, и сколько заказов попало
-- в две оценки сразу (разница между суммой строк и числом заказов).
select count(*)                     as scores_expected_5,
       sum(orders)                  as order_score_pairs,
       (select count(distinct r.order_id)
        from core.fact_review r
        join core.fact_order fo on fo.order_id = r.order_id
        where fo.is_revenue and fo.delivery_days is not null
          and r.review_score between 1 and 5) as orders_distinct
from mart.answer_q10;
