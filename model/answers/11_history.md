# Вброс. История категорий и адресов

## Что спрашивают

Из `docs/tasks.md`:

> - Продавец может сменить категорию товара, но отчёты за прошлые периоды должны
>   остаться прежними: доработайте модель так, чтобы она хранила историю изменений.
> - Покупатели переезжают: доработайте модель так, чтобы для любого заказа был
>   виден адрес покупателя на момент заказа, а не текущий.

## В чём ловушка

**Модель пересобирается с нуля.** `01_core.sql` удаляет и заново создаёт всё
в `core` из `raw`. Если хранить историю только в `core`, первая же пересборка её
сотрёт. А в `raw` изменений нет: это снимок на момент выгрузки.

Поэтому изменения живут в отдельной схеме `changelog`, которую пересборка
не трогает (`create table if not exists`, без `drop`). `core` при каждой сборке
строит версии из `raw` + журнала, и результат всегда один и тот же.

**Переезды в данных уже есть.** Адрес в `raw.customers` записан на каждый
`customer_id`, то есть на каждый заказ. У 252 человек (`customer_unique_id`)
адрес между заказами меняется — это настоящие переезды, и история строится
из них ещё до журнала.

## Как устроено

```
raw.products ─────────────┐          raw.customers + raw.orders ──┐
changelog.product_         │          changelog.customer_move ─────┤
  category_change ─────────┤                                       │
                           ▼                                       ▼
core.dim_product_category_hist       core.dim_customer_address
  product_id, version,                 address_sk, customer_unique_id,
  category_id, valid_from,             version, city, state, zip,
  valid_to, is_current                 valid_from, valid_to, is_current
          │                                       │
          ▼ по purchased_at                       ▼ по address_sk
core.fact_order_item.category_id     core.fact_order.customer_city / _state
core.dim_product (текущая версия)     mart.v_customer_base (текущий адрес)
```

**Категория (SCD2).** Первая версия — категория из `raw`, действует с
`-infinity`. Каждое изменение закрывает текущую версию (`valid_to` = момент
изменения) и открывает новую до `infinity`. Позиция заказа берёт версию, в
интервал которой попало `purchased_at`: прошлые продажи остаются в старой
категории, отчёт за прошлые месяцы не меняется. `dim_product` хранит текущую
категорию — для каталога, а не для отчётов.

**Адрес (SCD2).** События «заказ с таким-то адресом» и «переезд из журнала»
сортируются по времени, подряд идущие одинаковые адреса склеиваются в одну
версию. Заказ получает `address_sk` своей версии, а город и штат на момент заказа
лежат прямо в `fact_order` — отчётам по штатам (вопросы 7, 9) лишний join не нужен.
Всего 96 355 версий на 96 096 человек.

## Запрос дословно

Позиция заказа берёт ту версию категории, в интервал которой попало время
покупки (`model/01_core.sql`, сборка `fact_order_item`):

```sql
left join core.dim_product_category_hist h
       on h.product_id = i.product_id
      and nullif(btrim(o.order_purchase_timestamp), '')::timestamp >= h.valid_from
      and nullif(btrim(o.order_purchase_timestamp), '')::timestamp <  h.valid_to
```

Интервал — полуинтервал `[valid_from, valid_to)`: момент смены относится уже к
новой версии, и позиция попадает ровно в одну (проверка 15).

Версии категорий — первая из `raw`, остальные из журнала:

```sql
insert into core.dim_product_category_hist
select e.product_id,
       row_number() over w,
       e.category_id,
       coalesce(c.display_name, e.category_id),
       e.valid_from,
       coalesce(lead(e.valid_from) over w, timestamp 'infinity'),
       lead(e.valid_from) over w is null
from (
    select pr.product_id,
           coalesce(nullif(btrim(pr.product_category_name), ''), 'not_available') as category_id,
           timestamp '-infinity' as valid_from,
           0::bigint             as change_id
    from raw.products pr
    union all
    select ch.product_id, ch.category_id, ch.changed_at, ch.change_id
    from changelog.product_category_change ch
    where exists (select 1 from raw.products pr where pr.product_id = ch.product_id)
) e
left join core.dim_category c on c.category_id = e.category_id
window w as (partition by e.product_id order by e.valid_from, e.change_id);
```

* `valid_to` = начало следующей версии (`lead`), у последней — `infinity`;
* `is_current` = следующей версии нет.

Версии адреса — из ленты событий. Главное в ней — признак «адрес сменился»:

```sql
case when row_number() over w = 1 then 1
     when customer_city   is not distinct from lag(customer_city)   over w
      and customer_state  is not distinct from lag(customer_state)  over w
      and zip_code_prefix is not distinct from lag(zip_code_prefix) over w
     then 0 else 1
end as is_new
...
window w as (partition by customer_unique_id order by event_at, order_id, move_id)
```

а номер версии — нарастающая сумма этого признака:

```sql
sum(is_new) over (partition by customer_unique_id order by rn)::integer as version
```

* `is not distinct from` вместо `=` — пустой индекс у двух заказов подряд это
  тот же адрес, а `null = null` дал бы новую версию;
* `order by event_at, order_id, move_id` — у 290 человек по два заказа в одну
  секунду; без второго ключа номер версии зависел бы от случая;
* версия — `min(event_at)` её событий, а заказ привязан к версии по
  `(customer_unique_id, version)`, а не по датам: так он не промахнётся даже
  мимо версии нулевой длины.

## Почему нельзя было иначе

* **перезаписать категорию в `dim_product`** — все прошлые продажи товара
  переезжают в новую категорию. Для самого продаваемого товара
  (`bb50f2e2…`, beleza_saude) это 63 560.00 выручки и 194 единицы за все месяцы
  сразу: вопрос 5 за прошлые периоды поменялся бы задним числом;
* **держать историю в `core`** — пересборка (`01_core.sql` делает `drop`) её
  стирает; поэтому журнал в `changelog`, а `core` — производное от `raw` + журнала;
* **адрес по `customer_id`, как в `raw`** — работает только пока каждый заказ
  приходит со своим адресом. Переезд, который пришёл отдельным событием, а не
  с заказом, так не записать, и у человека нет «текущего адреса»;
* **адрес по текущей версии** — 43 заказа 39 человек уже сейчас оказались бы
  в чужом штате (см. вопрос 7);
* **версия по дате, а не по ключу** — заказ, оформленный в ту же секунду, что и
  переезд, мог бы получить не ту версию.

## Как вносить изменения

```sql
select changelog.change_product_category('<product_id>', '<категория>', '2018-09-01');
select changelog.move_customer('<customer_unique_id>', 'rio de janeiro', 'RJ', '20000', '2018-09-01');
```

Функции пишут событие в журнал и сразу обновляют версии в `core`, пересобирать
модель не нужно. Пересборка проиграет тот же журнал и придёт к тем же версиям
(проверено: после изменения и пересборки `except` между состояниями пустой).

Отказы:

* категории нет в `dim_category`, товара или покупателя нет;
* изменение задним числом — раньше начала текущей версии: оно переписало бы
  уже сданную историю. Для адреса это заодно гарантирует, что после переезда
  нет заказов;
* «переезд» на тот же адрес — пересборка склеила бы его с текущей версией.

## Как проверено

`04_checks.sql`, проверки 11–15:

| проверка | ожидаем |
|---|---|
| у каждого заказа есть версия адреса | 99 441 из 99 441 |
| адрес в заказе = адрес из `raw` на этот заказ | 99 441 из 99 441 |
| одна текущая версия адреса на человека | 96 096 |
| одна текущая версия категории на товар | 32 951 |
| позиция попадает ровно в одну версию категории | 112 650 из 112 650 |

В конце `04_checks.sql` — проба в транзакции с откатом: меняем категорию самого
продаваемого товара и переселяем самого активного покупателя, после чего сравниваем
выручку по месяцам и категориям и адреса всех заказов со снимком «до». Ожидаем
0 изменившихся строк, при этом текущая категория и текущий адрес уже новые.
После `rollback` журнал и модель как были.

## Чего здесь нет

* история продавцов (город, штат) — в задании не просили, а сделать её можно
  тем же способом: журнал + версии + город на момент заказа в `fact_order_item`;
* правка журнала задним числом через функцию — только руками и пересборкой.
