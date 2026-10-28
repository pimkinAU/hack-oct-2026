# Задание 8. Воронка статусов

## Что спрашивают

Из `docs/tasks.md`:

> Сколько заказов в каждом статусе и какую долю они составляют.
> Отдельной колонкой — сколько из них не содержат ни одного товара.
> **Результат:** статус, число заказов, доля в процентах, из них без позиций.

## В чём ловушка

**Потери на соединении.** Если считать воронку от позиций (`order_items join
orders`), заказы без позиций выпадут сами собой, и колонка «без позиций» всегда
будет нулём. Их 775. В модели они остались в `fact_order` с `items_count = 0`,
потому что позиции подклеены `left join`.

Здесь все заказы, в любом статусе: воронка про заказы, а не про выручку, так что
`is_revenue` не применяем.

## Откуда берутся цифры

```
core.dim_order_status    все 8 статусов
   ↓  left join
core.fact_order          все 99 441 заказ, items_count
   ↓
mart.v_order_status      по статусу: заказов, без позиций
   ↓
mart.answer_q8           + доля от всех заказов
```

## Запрос дословно

Витрина (`model/02_mart.sql`):

```sql
create view mart.v_order_status as
select st.order_status,
       st.status_group,
       st.is_revenue,
       count(fo.order_id)                              as orders,
       count(case when fo.items_count = 0 then 1 end)  as orders_without_items
from core.dim_order_status st
left join core.fact_order fo on fo.order_status = st.order_status
group by st.order_status, st.status_group, st.is_revenue;
```

Ответ (`model/03_answers.sql`):

```sql
create table mart.answer_q8 as
select s.order_status,
       s.orders,
       round(100.0 * s.orders / t.total_orders, 2) as share_pct,
       s.orders_without_items
from mart.v_order_status s
cross join (select sum(orders) as total_orders from mart.v_order_status) t
order by s.orders desc, s.order_status;
```

Разбор по строчкам:

* `from core.dim_order_status st left join core.fact_order` — основа — справочник
  статусов, как календарь в вопросе 1: статус без заказов остался бы строкой с
  нулём, а не исчез;
* `count(fo.order_id)` — по колонке, а не `count(*)`, по той же причине;
* `fo.items_count = 0` — число позиций посчитано в `fact_order` заранее, через
  `left join` к позициям и `coalesce(..., 0)`. Заказ без позиций там есть, с нулём;
* `cross join (select sum(orders) ...) t` — общий итог одной строкой рядом с
  каждым статусом, чтобы поделить; знаменатель — все заказы, а не доставленные;
* `100.0 *` — умножаем на дробное число до деления, иначе целочисленное деление
  дало бы 0 у всех статусов, кроме `delivered`.

## Что получилось

| статус | заказов | доля, % | без позиций |
|---|---:|---:|---:|
| delivered | 96 478 | 97.02 | 0 |
| shipped | 1 107 | 1.11 | 1 |
| canceled | 625 | 0.63 | 164 |
| unavailable | 609 | 0.61 | 603 |
| invoiced | 314 | 0.32 | 2 |
| processing | 301 | 0.30 | 0 |
| created | 5 | 0.01 | 5 |
| approved | 2 | 0.00 | 0 |
| **итого** | **99 441** | **100** | **775** |

## Почему нельзя было иначе

* **от позиций** (`orders join order_items`, `count(distinct order_id)`) —
  98 666 заказов вместо 99 441, статусов 7, а не 8: `created` пропадает целиком,
  `unavailable` сжимается с 609 до 6, `canceled` — с 625 до 461. Колонка «без
  позиций» везде 0 — ровно то, что вопрос просит показать;
* **то же, но `count(*)`** — 112 650: считаются позиции, а не заказы;
* **только доставленные или только `is_revenue`** — воронки не будет, одна строка.

## Что ещё видно из этих чисел

* `unavailable` почти целиком (603 из 609) — заказы без товара: судя по
  названию статуса, товара не оказалось в наличии, и позиции в выгрузку не попали;
* у `canceled` позиций нет у четверти (164 из 625): отмена до сборки заказа;
* 1 `shipped` и 2 `invoiced` без позиций — аномалии данных: отгружать нечего.

## Как перепроверить

```sql
select sum(orders), sum(orders_without_items) from mart.answer_q8;
```

Ожидаем `99441` и `775`.
