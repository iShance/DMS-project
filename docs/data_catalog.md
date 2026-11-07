# Gold data catalog

The Gold layer exists in SQL Server (`gold.*`) and as CSV files in `datasets/gold/` (written by
`agripulse.pipeline`). `ml_dataset.csv` / `gold.vw_ml_dataset` is the flat table used for mining.

## gold.fact_crop_year: one row per country x crop x year (1990-2013)

| column | type | description |
|---|---|---|
| country_key | INT | → dim_country |
| crop_key | INT | → dim_crop |
| year_key | INT | → dim_year (= calendar year) |
| climate_band_key | INT | → dim_climate_band (from the country's climate normals) |
| yield_hg_ha | FLOAT | yield, hectograms per hectare (10 hg/ha = 1 kg/ha) |
| prev_yield_hg_ha | FLOAT | yield of the previous calendar year (NULL if that year is missing) |
| yoy_change_pct | FLOAT | yield / previous yield - 1, in % |
| baseline_yield_hg_ha | FLOAT | mean yield of the previous 5 calendar years (at least 3 present) |
| baseline_n_years | INT | number of years present in that window (3-5) |
| yield_dev_pct | FLOAT | yield / baseline - 1, in % |
| **is_shock** | TINYINT | **label**: 1 if yield_dev_pct ≤ −15 |
| prev_yield_dev_pct | FLOAT | last year's yield_dev_pct |
| prev_is_shock | TINYINT | last year's label |
| rainfall_mm | FLOAT | annual rainfall (static long-term value in this source, see data_quality.md) |
| rain_dev_pct | FLOAT | rainfall / country long-term mean - 1, in % |
| rain_is_imputed | TINYINT | 1 if the rainfall value was filled with the country mean |
| avg_temp_c | FLOAT | annual mean temperature (°C), mean of the source records |
| temp_anomaly_c | FLOAT | avg_temp_c minus the country's 1961-1990 mean |
| pesticides_tonnes | FLOAT | pesticide use, tonnes of active ingredients (country total) |
| pesticide_intensity | FLOAT | log10(1 + pesticides_tonnes) |
| pesticide_yoy_pct | FLOAT | pesticide use / last year's use - 1, in % |

## gold.dim_country

| column | description |
|---|---|
| country_key | surrogate key (ROW_NUMBER over the name) |
| country_name | conformed name (`datasets/reference/country_reference.csv`) |
| iso3 | ISO 3166-1 alpha-3 (historical codes for former states, e.g. SUN, YUG) |
| region | World Bank region (7 regions) |
| temp_normal_c | mean annual temperature 1961-1990 |
| rainfall_normal_mm | long-term mean annual rainfall |

## gold.dim_crop

| column | description |
|---|---|
| crop_key | surrogate key |
| crop_name | FAO item name (Cassava, Maize, Plantains and others, Potatoes, Rice paddy, Sorghum, Soybeans, Sweet potatoes, Wheat, Yams) |
| fao_item_code | FAO item code |
| crop_group | Cereals, Roots & Tubers, Oilseeds, Starchy Fruits |

## gold.dim_year

| column | description |
|---|---|
| year_key / year | calendar year 1990-2013 |
| decade | 1990s, 2000s, 2010s |
| five_year_period | 1990-1994 ... 2010-2014 |

## gold.dim_climate_band

Temperature band (from `temp_normal_c`) x rainfall band (from `rainfall_normal_mm`); the lower bound is
inclusive and the upper bound exclusive.

| temperature band | range (°C) | | rainfall band | range (mm/yr) |
|---|---|---|---|---|
| Cold | < 10 | | Arid | < 250 |
| Temperate | 10-20 | | Semi-arid | 250-500 |
| Warm | 20-25 | | Sub-humid | 500-1,000 |
| Hot | ≥ 25 | | Humid | 1,000-2,000 |
| | | | Very humid | ≥ 2,000 |

## gold.vw_ml_dataset / datasets/gold/ml_dataset.csv

All fact measures plus the descriptive attributes `country_name, iso3, region, crop_name, crop_group,
year, decade, climate_band, temp_band, rain_band`. 16,339 rows, 10.2 % shocks.
