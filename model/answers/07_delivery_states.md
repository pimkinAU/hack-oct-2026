# Задание 7. Доставка по штатам покупателя

## Что спрашивают

Из `docs/tasks.md`:

> Среднее время доставки и доля опозданий, только для штатов,
> где было не меньше 500 заказов.
> **Результат:** штат, число заказов, среднее число дней доставки, доля опозданий.

## В чём ловушка

* **Какой штат.** После вброса покупатели переезжают. Заказ везли туда, где
  человек жил в момент заказа, поэтому штат берём из `fact_order` (адрес на момент
  заказа), а не текущий адрес из `dim_customer_address`.
* **Какие заказы.** Срок доставки есть только у заказа с датой вручения. Берём
  доставленные (`is_revenue`) с `delivery_days is not null` — 96 470 заказов
  (у 8 доставленных даты вручения нет).
* **Порог по тем же заказам.** 500 считаем по заказам, из которых получено
  среднее, а не по всем заказам штата: иначе штат мог бы пройти порог за счёт
  отменённых.

## Откуда берутся цифры

```
core.fact_order          customer_state (на момент заказа), delivery_days,
   ↓                     is_delayed = вручили позже estimated_delivery_date
mart.v_delivery_state    по штату: заказов, опозданий, средний срок
   ↓
mart.answer_q7           только штаты от 500 заказов
```

`delivery_days` — разница дат вручения и покупки, без часов. `is_delayed` —
дата вручения позже обещанной.

## Запрос дословно

Срок и опоздание считаются один раз, при сборке `fact_order` (`model/01_core.sql`):

```sql
case when nullif(btrim(o.order_delivered_customer_date), '')::timestamp is not null
     then nullif(btrim(o.order_delivered_customer_date), '')::timestamp::date
          - nullif(btrim(o.order_purchase_timestamp), '')::timestamp::date
end,                                               -- delivery_days
case when nullif(btrim(o.order_delivered_customer_date), '')::timestamp is not null
          and nullif(btrim(o.order_estimated_delivery_date), '')::date is not null
     then (nullif(btrim(o.order_delivered_customer_date), '')::timestamp)::date
          > nullif(btrim(o.order_estimated_delivery_date), '')::date
end                                                -- is_delayed
```

Витрина (`model/02_mart.sql`):

```sql
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
```

Ответ (`model/03_answers.sql`):

```sql
create table mart.answer_q7 as
select d.customer_state,
       d.delivered_orders as orders,
       d.avg_delivery_days,
       d.delayed_pct
from mart.v_delivery_state d
where d.delivered_orders >= 500
order by d.delivered_orders desc, d.customer_state;
```

Разбор по строчкам:

* `::date - ::date` — срок в целых днях календаря: заказ, оформленный вечером и
  привезённый утром через день, — 2 дня. Так же устроена и обещанная дата —
  она в данных без времени;
* `is_delayed` сравнивает **дату** вручения с обещанной датой, а не момент
  вручения: привезли в обещанный день в 15:00 — это вовремя;
* `where fo.is_revenue and fo.delivery_days is not null` — одни и те же заказы
  и в среднем, и в доле, и в пороге: знаменатель у всех трёх показателей общий;
* `count(case when ... then 1 end)` — опоздания; `null` в `is_delayed` в выборку
  не попадает, потому что `delivery_days is not null` уже отсеял недоставленные;
* `where d.delivered_orders >= 500` — порог на уровне ответа, а не витрины:
  витрина хранит все 27 штатов, и порог можно поменять, не трогая модель.

## Что получилось

17 штатов из 27, в них 93 938 из 96 470 доставленных заказов (97%).

| штат | заказов | дней в среднем | опозданий, % |
|---|---:|---:|---:|
| SP | 40 494 | 8.70 | 4.49 |
| RJ | 12 350 | 15.24 | 12.11 |
| MG | 11 354 | 11.94 | 4.57 |
| RS | 5 344 | 15.25 | 6.08 |
| PR | 4 923 | 11.94 | 4.04 |
| SC | 3 546 | 14.90 | 8.21 |
| BA | 3 256 | 19.28 | 12.16 |
| DF | 2 080 | 12.90 | 5.67 |
| ES | 1 995 | 15.72 | 10.73 |
| GO | 1 957 | 15.54 | 6.54 |
| PE | 1 593 | 18.40 | 9.60 |
| CE | 1 279 | 21.20 | 13.76 |
| PA | 946 | 23.73 | 11.21 |
| MT | 886 | 18.00 | 5.98 |
| MA | 717 | 21.51 | 17.43 |
| MS | 701 | 15.54 | 9.70 |
| PB | 517 | 20.39 | 10.44 |

## Почему нельзя было иначе

* **опоздание по моменту, а не по дате** (`delivered_at > estimated_delivery_date`) —
  обещанная дата приводится к полуночи, и любой заказ, привезённый в обещанный
  день, становится опозданием: 7 826 опозданий вместо 6 534, у MA 19.67% вместо 17.43%;
* **срок по часам** (`delivered_at - purchased_at` в долях дня) — у SP 8.76 вместо
  8.70. Вопрос спрашивает «число дней», а обещанная дата — тоже целые дни;
* **доля от всех заказов штата** — в знаменателе окажутся отменённые и не
  доставленные заказы, которые опоздать не могли: у MA 16.73% вместо 17.43%;
* **штат по текущему адресу** — 43 заказа 39 человек оказались бы не в том штате,
  куда их везли. На средних по крупным штатам это почти не видно, но это ошибка
  определения, а не округление, и после реальных переездов она только растёт.

Порог 500 на этих данных даёт 17 штатов и по всем заказам, и по доставленным, —
но считать его надо по тем же заказам, что и среднее.

## Что ещё видно из этих чисел

* срок растёт с расстоянием от Сан-Паулу: SP 8.7 дня, север и северо-восток
  (PA, CE, MA) — больше 20;
* опоздания от срока не зависят напрямую: RJ возят на 3.3 дня дольше, чем MG,
  а опаздывают в 2.6 раза чаще. Обещанный срок в RJ занижен сильнее;
* худший по опозданиям — MA, 17.43%.

## Как перепроверить

```sql
select count(*), sum(orders) from mart.answer_q7;
```

Ожидаем `17` и `93938`.
