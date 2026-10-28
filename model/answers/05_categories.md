# Задание 5. Выручка по категориям с долей

## Что спрашивают

Из `docs/tasks.md`:

> **Результат:** категория, выручка, доля в выручке.
> **Контроль:** 74 категории, крупнейшая — 1 233 131.72, сумма по всем
> категориям 13 221 498.11.
> **Куда смотреть.** У части товаров категории нет, а названия категорий в
> данных на португальском и переводятся таблицей переводов.

## В чём ловушка

Три ловушки в одном вопросе.

**1. Категории на португальском.** В `raw.products` поле `category_name` —
португальское, а рядом лежит таблица `raw.product_category_translation` (71
строка) с переводом на английский. Не переведём — отчёт будет на португальском
и часть категорий сольётся с переводными по смыслу, но разными по написанию.

**2. Товары без категории.** У 610 товаров `category_name` пустой. Если
группировать как есть, они либо слипнутся в `null`-строку, либо вообще выпадут
из отчёта через `inner join`. Их выручка — 170 726.63, это 1.29% общей: потерять
их значит не сойтись с контролем 13 221 498.11. Поэтому у нас для них стоит
значение `not_available`, и оно отдельной строкой живёт в отчёте.

**3. Категории без перевода.** Две категории есть в товарах, но их нет в таблице
переводов: `pc_gamer` и `portateis_cozinha_e_preparadores_de_alimentos`. Их мы
оставляем под португальским именем (вместе это 5 240.58 выручки). Если бы мы
«в наказании» слили их в общую корзину, категорий стало бы 73 вместо 74, и
контроль бы не сошёлся.

Итого 74 строки: 73 настоящие категории с продажами + `not_available`.

## Откуда берутся цифры

```
raw.products (category_name)  +  raw.product_category_translation
   ↓  model/01_core.sql
core.dim_category             category_name → display_category (перевод либо
   ↓                          португальское имя, пустое → not_available)
core.fact_order_item          у каждой позиции уже проставлен display_category
   ↓  model/02_mart.sql
mart.v_category_revenue       одна строка = категория: заказы, единицы, выручка
   ↓  model/03_answers.sql
mart.answer_q5                категория, выручка, доля
```

## Запрос дословно

Витрина (`model/02_mart.sql`):

```sql
create view mart.v_category_revenue as
select i.display_category,
       count(distinct i.order_id) as orders,
       count(*)                   as units,
       sum(i.price)               as revenue
from core.fact_order_item i
where i.is_revenue
group by i.display_category;
```

Ответ (`model/03_answers.sql`):

```sql
create table mart.answer_q5 as
select c.display_category,
       round(c.revenue, 2) as revenue,
       round(100.0 * c.revenue / t.total_revenue, 2) as share_pct
from mart.v_category_revenue c
cross join (select sum(revenue) as total_revenue from mart.v_category_revenue) t
order by c.revenue desc;
```

Разбор:

* `where i.is_revenue` — только позиции доставленных заказов, то есть те же
  деньги, что и в первом вопросе. Поэтому сумма по категориям обязана равняться
  13 221 498.11 — если не равна, значит часть позиций потерялась по дороге;
* `cross join (select sum(...) ...)` — знаменатель доли считаем по той же
  витрине и приклеиваем к каждой строке. У подзапроса ровно одна строка, так
  что `cross join` не раздувает результат, зато числитель и знаменатель
  гарантированно про один и тот же набор позиций. Округление каждой доли до
  сотых даёт сумму 99.96 вместо 100 — это не ошибка, это цена округления
  каждой строки отдельно;
* `order by c.revenue desc` — в таблице ответа лежат все 74 строки, а на экран
  файл печатает только первые 15, чтобы вывод не растягивался на три экрана.

## Что получилось: все 74 категории

| категория | выручка | доля, % |
|---|---|---|
| health_beauty | 1233131.72 | 9.33 |
| watches_gifts | 1166176.98 | 8.82 |
| bed_bath_table | 1023434.76 | 7.74 |
| sports_leisure | 954852.55 | 7.22 |
| computers_accessories | 888724.61 | 6.72 |
| furniture_decor | 711927.69 | 5.38 |
| housewares | 615628.69 | 4.66 |
| cool_stuff | 610204.10 | 4.62 |
| auto | 578966.65 | 4.38 |
| toys | 471286.48 | 3.56 |
| garden_tools | 470495.28 | 3.56 |
| baby | 400421.84 | 3.03 |
| perfumery | 390144.65 | 2.95 |
| telephony | 309860.23 | 2.34 |
| office_furniture | 268154.31 | 2.03 |
| stationery | 223788.69 | 1.69 |
| computers | 218684.14 | 1.65 |
| pet_shop | 211695.64 | 1.60 |
| musical_instruments | 184315.74 | 1.39 |
| small_appliances | 182754.12 | 1.38 |
| not_available | 170726.63 | 1.29 |
| electronics | 155043.93 | 1.17 |
| fashion_bags_accessories | 149329.39 | 1.13 |
| consoles_games | 148003.37 | 1.12 |
| construction_tools_construction | 142108.49 | 1.07 |
| luggage_accessories | 138701.63 | 1.05 |
| home_appliances_2 | 107953.95 | 0.82 |
| home_construction | 81407.57 | 0.62 |
| home_appliances | 78832.48 | 0.60 |
| agro_industry_and_commerce | 70566.10 | 0.53 |
| furniture_living_room | 67350.70 | 0.51 |
| home_confort | 58008.45 | 0.44 |
| fixed_telephony | 55315.21 | 0.42 |
| air_conditioning | 53323.56 | 0.40 |
| audio | 50570.60 | 0.38 |
| small_appliances_home_oven_and_coffee | 46589.56 | 0.35 |
| kitchen_dining_laundry_garden_furniture | 45531.98 | 0.34 |
| books_general_interest | 45302.15 | 0.34 |
| construction_tools_lights | 39957.00 | 0.30 |
| construction_tools_safety | 38773.22 | 0.29 |
| industry_commerce_and_business | 38498.81 | 0.29 |
| food | 28731.15 | 0.22 |
| market_place | 27795.77 | 0.21 |
| costruction_tools_garden | 25096.28 | 0.19 |
| art | 23657.30 | 0.18 |
| fashion_shoes | 23001.46 | 0.17 |
| drinks | 21529.84 | 0.16 |
| signaling_and_security | 21315.05 | 0.16 |
| furniture_bedroom | 19051.80 | 0.14 |
| books_technical | 18702.23 | 0.14 |
| costruction_tools_tools | 15903.95 | 0.12 |
| food_drink | 14942.88 | 0.11 |
| fashion_male_clothing | 10452.33 | 0.08 |
| fashion_underwear_beach | 9305.95 | 0.07 |
| christmas_supplies | 8737.84 | 0.07 |
| tablets_printing_image | 7528.41 | 0.06 |
| cine_photo | 6674.47 | 0.05 |
| music | 6034.35 | 0.05 |
| dvds_blu_ray | 4542.59 | 0.03 |
| party_supplies | 4465.19 | 0.03 |
| books_imported | 4418.86 | 0.03 |
| furniture_mattress_and_upholstery | 4323.38 | 0.03 |
| portateis_cozinha_e_preparadores_de_alimentos | 3933.63 | 0.03 |
| fashio_female_clothing | 2634.94 | 0.02 |
| fashion_sport | 2094.52 | 0.02 |
| la_cuisine | 2054.99 | 0.02 |
| arts_and_craftmanship | 1814.01 | 0.01 |
| diapers_and_hygiene | 1500.79 | 0.01 |
| pc_gamer | 1306.95 | 0.01 |
| flowers | 1110.04 | 0.01 |
| home_comfort_2 | 760.27 | 0.01 |
| cds_dvds_musicals | 730.00 | 0.01 |
| fashion_childrens_clothes | 519.95 | 0.00 |
| security_and_services | 283.29 | 0.00 |
| **итого** | **13 221 498.11** | **99.96** |

Контрольный запрос из того же файла печатает:

```
check_name | categories_expected_74 | total_13221498_11 | shares_sum_pct
control    | 74                     | 13221498.11       | 100.0
```

## Почему нельзя было иначе

* **взять `category_name` без перевода** — отчёт на португальском, и «крупнейшая
  категория» в контроле не находится по имени;
* **`inner join` к справочнику категорий** — 610 товаров без категории и их
  170 726.63 исчезают, сумма не сходится с 13 221 498.11;
* **слить непереведённые в `not_available`** — 73 строки вместо 74;
* **доля от суммы заказов, а не от выручки** — знаменатель из другой таблицы, и
  сумма долей уедет далеко от 100;
* **выручка с доставкой** — 15 424 463.65, контроль не сходится.

## Что ещё видно из этих чисел

* выручка распределена ровно: топ-10 категорий — это 62.43% всей выручки, а 21
  категория приносит меньше 10 000 каждая, самая мелкая
  (`security_and_services`) — 283.29;
* `not_available` (1.29%) стоит в середине списка — между `small_appliances` и
  `electronics`. Таких товаров в справочнике 610, из них хоть раз продавались
  584 товара на 1 537 позиций. Если делать отчёт «по направлениям бизнеса», эту
  строку надо либо расшифровать по `product_id`, либо объяснить отдельной
  сноской, но не молча выкидывать;
* «число заказов» по категориям складывается в 97 276, хотя доставленных заказов
  96 478: 780 заказов содержат товары из двух и более категорий. Доли по выручке
  складываются в 100%, а «число заказов» по категориям — в 100.8%, и это нормальное
  свойство неаддитивной метрики, о котором стоит сказать вслух, если спросили
  «почему у вас заказы не суммируются»;
* опечатки в данных — это данные: `costruction_tools_garden`,
  `costruction_tools_tools` (с пропущенной `n`), `fashio_female_clothing`,
  `home_confort` и `home_comfort_2` — все они настоящие значения из выгрузки, и
  мы их не «чиним», иначе перестанем сходиться с источником.

## Как перепроверить

```sql
select count(*)               as категорий,
       round(sum(revenue), 2) as итог,
       max(revenue)           as крупнейшая
from mart.answer_q5;

-- сколько позиций ушло в not_available
select count(*) as позиций, count(distinct product_id) as товаров
from core.fact_order_item
where is_revenue and display_category = 'not_available';
```

Ожидаем `74 / 13221498.11 / 1233131.72` и `1537 / 584`.
