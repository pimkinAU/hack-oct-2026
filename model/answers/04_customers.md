# Задание 4. Покупатели и повторные покупки

## Что спрашивают

Из `docs/tasks.md`:

> **Результат:** число покупателей, из них сколько сделали больше одного заказа,
> доля вернувшихся.
> **Контроль:** 96 096 покупателей, доля вернувшихся 3.12%. Число 99 441 —
> неверный ключ счёта.
> **Куда смотреть.** В данных два идентификатора покупателя, и считают нужно
> по человеку, а не по записи о заказе.

## В чём ловушка

В выгрузке у покупателя два id:

* `customer_id` — привязан к заказу. 99 441 значение, и все разные: сколько
  заказов, столько и этих id. Считать по нему — это считать заказы, а не людей.
  Отсюда и «неверный ключ счёта» 99 441;
* `customer_unique_id` — сам человек. Их 96 096, и у 2 997 человек встречается
  несколько `customer_id` — это ровно те, кто покупал больше одного раза.

Проверить это можно одним запросом:

```sql
-- сколько customer_id приходится на одного человека
select count(*)                  as людей,
       count(distinct customer_id) as id_заказа,
       max(kol)                  as максимум_на_человека
from (
  select customer_unique_id,
         count(distinct customer_id) as kol
  from raw.customers
  group by customer_unique_id
) t;
```

Ответ: 96 096 / 99 441 / 17. Один человек успел оформить 17 заказов, и каждый
раз у него был новый `customer_id`.

## Откуда берутся цифры

```
raw.customers (customer_id, customer_unique_id)  +  raw.orders
   ↓  model/01_core.sql
core.dim_customer    один человек = строка: customer_unique_id, город, штат
core.fact_order      одна строка = заказ: customer_id, purchased_at, is_revenue
   ↓  model/02_mart.sql
mart.v_customer_base одна строка = человек: первый/последний заказ,
   ↓                 orders_total, orders_revenue, выручка
mart.answer_q4       одна строка с ответом
```

## Запрос дословно

Витрина (`model/02_mart.sql`):

```sql
create view mart.v_customer_base as
select cu.customer_unique_id,
       min(fo.purchased_at)::date              as first_order_date,
       max(fo.purchased_at)::date              as last_order_date,
       count(distinct fo.order_id)             as orders_total,
       count(distinct case when fo.is_revenue then fo.order_id end) as orders_revenue,
       coalesce(sum(case when fo.is_revenue then fo.goods_total else 0 end), 0) as revenue,
       max(cu.customer_city)                   as customer_city,
       max(cu.customer_state)                  as customer_state
from core.dim_customer cu
join core.fact_order fo on fo.customer_id = cu.customer_id
group by cu.customer_unique_id;
```

Ответ (`model/03_answers.sql`):

```sql
create table mart.answer_q4 as
select count(*)                                     as customers,
       count(case when orders_total > 1 then 1 end) as returned,
       round(100.0 * count(case when orders_total > 1 then 1 end) / count(*), 2) as returned_pct
from mart.v_customer_base;
```

Разбор:

* `group by cu.customer_unique_id` — витрина уже считает «человека», поэтому в
  ответе `count(*)` — это люди, а не заказы;
* `count(distinct fo.order_id)` — `distinct` здесь защищает от раздувания: в
  `dim_customer` у человека может быть несколько строк `customer_id`, и каждый
  из них даёт свой заказ;
* считаем по `orders_total`, а не по `orders_revenue`: «вернулся» = оформил
  второй заказ. Если второй заказ отменили, человек всё равно вернулся, и
  менять это надо осознанно, а не по случайности выбора колонки;
* `100.0`, а не `100` — чтобы деление было дробным: в Postgres `3/96` было бы 0,
  если оба числа целые;
* `count(case when ... then 1 end)` — обычный `count` не считает `null`, поэтому
  невыполненные условия в строку не попадают. Это самый простой способ посчитать
  «сколько с условием» без спецконструкций.

## Что получилось

```
customers | returned | returned_pct
96096     | 2997     | 3.12
```

Как распределены люди по числу заказов:

| заказов | человек |
|---|---|
| 1 | 93 099 |
| 2 | 2 745 |
| 3 | 203 |
| 4 | 30 |
| 5 | 8 |
| 6 | 6 |
| 7 | 3 |
| 9 | 1 |
| 17 | 1 |
| **итого** | **96 096** |

Контроль «не потерялись ли id», который печатает `03_answers.sql`:

```
check_name              | rows  | order_level_ids | humans
customer_id -> unique_id| 99441 | 99441           | 96096
```

`rows` равняется `order_level_ids`, значит у одного `customer_id` ровно один
человек — то есть счёт по `customer_unique_id` корректен: id заказа «приклеен»
к человеку однозначно, и мы не склеиваем разных людей в одного.

## Почему нельзя было иначе

* **по `customer_id`** — 99 441 «покупатель», и доля вернувшихся 0%, потому что
  каждый такой id встречается в данных ровно один раз. Контроль прямо называет
  это неверным ключом;
* **по `orders_revenue > 1`** — меньше вернувшихся: те, чей второй заказ отменён,
  выпадут;
* **inner join в витрине** — безопасен здесь (люди без заказов в
  `dim_customer` из этих же данных), но если позже появятся покупатели без
  заказов, они исчезнут из знаменателя, и доля подпрыгнет.

## Что ещё видно из этих чисел

* 3.12% вернувшихся — почти все покупатели (96.88%) покупают один раз. Для
  маркетплейса это главный аргумент в сторону работы с базой, а не только с
  трафиком;
* число людей с повторными покупками (2 997) в точности равно числу
  `customer_unique_id`, у которых несколько `customer_id` — эти два числа
  совпали, и это независимая проверка: повторная покупка в данных устроена
  именно как новый `customer_id` у того же человека;
* человек с 17 заказами — единственный с таким количеством, в отчёте по штатам
  или по выручке на одного человека он почти не влияет, но в среднем «заказов на
  человека» его видно.

## Как перепроверить

```sql
select count(*)                                             as покупателей,
       count(case when orders_total > 1 then 1 end)         as вернувшихся,
       round(100.0 * count(case when orders_total > 1 then 1 end) / count(*), 2) as доля
from mart.v_customer_base;
```

Ожидаем `96096 / 2997 / 3.12`.
