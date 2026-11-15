# Data quality findings

Everything below was found while profiling the four source files (`sql/07_quality_checks.sql` and
notebook 01 reproduce the numbers). These findings belong in the limitations section of the paper.

## 1. The rainfall file is a static long-term average (critical)

`rainfall.csv` repeats one value per country for every year from 1985 to 2017. **188 of 192 countries
never change.** The other four change exactly once, which looks like a revision rather than weather: India
(1,940 → 1,083 mm) and Paraguay (3,142 → 1,130 mm) in 1986, Argentina (591 → 562 mm) and Barbados
(1,422 → 618 mm) in 2017. As a result
`rain_dev_pct` is zero for 97.7 % of Gold rows, and no model or association rule can learn
anything from rainfall *deviation*.

Rainfall still works as a static aridity attribute (`rainfall_mm`, rain band of `dim_climate_band`),
and that version is informative: semi-arid countries have 17.2 % shocks against 6.9 % in very humid ones.

**Fix for a follow-up study:** replace the file with a real annual precipitation series, for example the
CRU TS country averages published on the World Bank Climate Change Knowledge Portal. The pipeline only
needs a new Bronze file with the same three columns.

## 2. Temperature has many records per country-year

`temp.csv` has 71,311 rows but only 27,479 country-years: up to 52 records for one country-year
(United States). The records look like city or station series (the file goes back to 1743). Silver averages
them. The Kaggle file `yield_df.csv`, which many published notebooks use, joins without averaging, so its
rows are duplicated. The record count per country-year also changes over time, which adds noise to the
anomaly. The proposal credits the World Bank, as the Kaggle page does; the record structure suggests a
station-based source, so the provenance should be checked before publication.

## 3. FAO double counting and missing values

* `China` (FAO area 351) is the sum of mainland China, Hong Kong, Macao and Taiwan, which are also
  listed separately. The aggregate was dropped (448 rows) and `China, mainland` became `China`.
* 8 yield values are 0 hg/ha. In FAO data that marks a missing record, so they were dropped.
* 50 country-crop series skip one or more years. The Gold window functions run on a densified
  calendar, so a gap never shifts LAG or the five-year baseline.

## 4. Country names differ across sources

41 spellings were mapped to one conformed name (`datasets/reference/country_aliases.csv`). Examples:

| FAO | World Bank rainfall | temperature file | conformed |
|---|---|---|---|
| Viet Nam | Vietnam | Vietnam | Vietnam |
| Democratic Republic of the Congo | Congo, Dem. Rep. | Congo (Democratic Republic Of The) | DR Congo |
| Côte d'Ivoire | Cote d'Ivoire | Côte D'Ivoire | Côte d'Ivoire |
| Iran (Islamic Republic of) | Iran | Iran | Iran |
| Republic of Korea | South Korea␠ (trailing space) | South Korea | South Korea |
| United States of America | United States | United States | United States |

## 5. Missing values

| source | issue | handling |
|---|---|---|
| rainfall | 774 blank cells and 6 `..` markers; years 1988 and 2003 absent from the file | the 780 cells go to `silver.reject_log`; complete 1985-2017 grid, gaps filled with the country mean, `is_imputed = 1` (389 country-years; 703 Gold rows) |
| rainfall | some territories have no value at all (e.g. American Samoa) | country dropped |
| temperature | 2,547 blank cells | written to `silver.reject_log` and left out of the city average; no country-year in 1990-2013 is left empty |
| pesticides | first year (1990) has no previous year | `pesticide_yoy_pct` is NULL (611 Gold rows); models impute the training median |
| yield history | first year of a series has no LAG | `prev_*` NULL (118 Gold rows); models impute the training median |

## 6. Coverage: who drops out of Gold

Of the 209 FAO entities with yields in 1990-2013, **119 countries remain** in Gold. The 90 that drop out
lack at least one source:

* **no pesticide data:** Afghanistan, Bosnia and Herzegovina, DR Congo, Gabon, Georgia, Liberia, Mongolia,
  Nigeria, Philippines, Serbia, Sierra Leone, Somalia, United Arab Emirates, Uzbekistan, among others
* **no temperature data:** Chad, Costa Rica, Ethiopia, Israel, Myanmar, Panama, Paraguay, Togo, Yemen,
  many small island states, among others
* **no rainfall data:** Hong Kong, Taiwan
* **historical entities:** USSR, Yugoslav SFR, Czechoslovakia, Serbia and Montenegro, Belgium-Luxembourg

Several food-insecure countries (Ethiopia, Nigeria, Chad, Yemen, Somalia) are therefore missing, which
limits how far the results generalise to the places where an early warning matters most.

## 7. Heavy tails

`yield_dev_pct` reaches +678 % and `pesticide_yoy_pct` +36,571 %, because of tiny starting values and
series revisions. The classifiers are tree-based or scaled, so they tolerate this. The linear
regression target is winsorised at the 1st and 99th training percentiles.

## 8. Rejected rows and reconciliation

Silver keeps every Bronze row it does not use in `silver.reject_log`, with the source table, the
source's own key, the failing column, the raw value and the rule. The pandas pipeline builds the same
log (`pipeline.build_silver()["reject_log"]`) and `tests/test_sql.py` checks that the two match row
for row.

| source | rule | rows |
|---|---|---|
| `bronze.fao_yield` | FAO China aggregate (area 351) double counts its parts | 448 |
| `bronze.fao_yield` | missing or zero yield (FAO missing record) | 8 |
| `bronze.wb_rainfall` | missing or non-numeric rainfall (blank or `..`) | 780 |
| `bronze.wb_temperature` | missing or non-numeric temperature | 2,547 |
| pesticides, country reference, aliases | – | 0 |

The check `bronze_rows_equal_kept_rows_plus_rejects` (`sql/07_quality_checks.sql`) proves that no row
is lost silently: for every source, Bronze rows = rows kept in Silver + rejected rows. For rainfall the
kept rows are the observed (not imputed) cells; for temperature they are the city records that were
averaged. Every load also writes one row per table to `audit.load_log` (rows loaded, rows rejected,
SUCCESS or FAILED).
