# AgriPulse: results summary

*AgriPulse: A Lakehouse-Driven Data Mining Framework for Early Detection of Climate-Induced Crop Yield
Shocks*. These are the numbers and findings for the paper. Every value comes from the executed
notebooks (`notebooks/01-03`); the tables are in `reports/tables/` and the figures in `reports/figures/`.

## 1. Data and label

| item | value |
|---|---|
| sources | FAO yield (56,717 rows), World Bank rainfall (6,727), temperature (71,311), FAO pesticides (4,349) |
| Gold grain | country x crop x year, 1990-2013 |
| Gold rows | **16,339** crop-years, 119 countries, 10 crops |
| label | `is_shock = 1` if yield ≤ 85 % of the mean of the previous 5 years (same country and crop) |
| class balance | 1,667 shocks = **10.2 %** (train 10.5 %, test 9.3 %) |

Data-quality findings that shape every result (details in `docs/data_quality.md`):

1. **The rainfall source is static.** 188 of 192 countries repeat one value every year, so the
   rainfall deviation is zero for 97.7 % of rows. Rainfall can only be used as a static aridity level.
2. The temperature file has up to 52 records per country-year. They are averaged in Silver; the Kaggle
   `yield_df.csv` does not do this and duplicates rows.
3. FAO's "China" aggregate double-counts its parts and is dropped. Zero yields are treated as missing.
4. 90 of 209 yield entities drop out for lack of climate or pesticide data, including Ethiopia, Nigeria,
   Chad, Yemen and Somalia.

## 2. EDA and OLAP (notebook 01, `sql/06_analytics.sql`)

* Shock rate **by crop**: sorghum 18.3 %, soybeans 12.6 %, wheat 11.6 %, maize 10.7 % … sweet potatoes
  7.1 %, potatoes 6.8 %, plantains 6.1 %, yams 5.0 %.
* **By region**: Sub-Saharan Africa 14.5 %, Europe & Central Asia 11.5 %, Middle East & North Africa
  11.5 %, Latin America 7.3 %, North America 5.7 %, East Asia & Pacific 4.3 %, South Asia 2.6 %.
  Highest cell: Sub-Saharan cereals at 18.7 %.
* **By climate band (aridity)**: semi-arid 17.2 %, arid 12.1 %, sub-humid 10.8 %, humid 9.0 %, very
  humid 6.9 %.
* **Temperature**: the hottest anomaly quintile has 12.5 % shocks against 9.0-10.0 % in the others.
  For Sub-Saharan cereals, years more than +1 °C above the 1961-1990 normal have 28.4 % shocks against
  18.0 %.
* **Pesticides**: 12.5 % shocks in the lowest-use tercile against 7.2 % in the highest, probably a proxy
  for low-input farming systems.
* **Persistence**: P(shock | shock last year) = 38.6 % against 6.9 %.
* Shocks became slightly less frequent over time (1990s 11.0 %, 2000s 9.8 %, 2010s 9.4 %). The worst
  year was 1992 (15.6 %).

## 3. Classification (notebook 02)

Protocol: train 1990-2007 and test 2008-2013. Forward-chaining CV inside the training years (four
two-year validation blocks). The decision threshold is chosen on the out-of-fold CV predictions
(maximum F1). All features are known before the predicted harvest.

### 3.1 Ablation: test ROC-AUC

| model | A. climate only | B. + crop, region, rainfall level | C. + last year's yield |
|---|---|---|---|
| Decision Tree | 0.521 | 0.625 | 0.738 |
| Naive Bayes | 0.565 | 0.654 | 0.722 |
| k-NN | 0.542 | 0.615 | 0.738 |
| Bagging | 0.550 | 0.656 | 0.764 |
| AdaBoost | 0.551 | 0.661 | **0.765** |

### 3.2 Full feature set (C)

| model | threshold | CV ROC-AUC | Accuracy | Precision | Recall | F1 | ROC-AUC | PR-AUC |
|---|---|---|---|---|---|---|---|---|
| Decision Tree | 0.75 | 0.752 | 0.886 | 0.380 | 0.368 | 0.374 | 0.738 | 0.319 |
| Naive Bayes | 0.96 | 0.734 | 0.857 | 0.294 | 0.381 | 0.331 | 0.722 | 0.254 |
| k-NN | 0.22 | 0.760 | 0.854 | 0.304 | 0.442 | 0.360 | 0.738 | 0.306 |
| **Bagging** (best CV) | 0.55 | **0.775** | 0.865 | 0.330 | 0.442 | 0.377 | 0.764 | **0.338** |
| AdaBoost | 0.33 | 0.769 | 0.869 | 0.338 | 0.426 | 0.377 | 0.765 | 0.306 |
| Rule: "shock if last year was a shock" | – | – | 0.880 | 0.360 | 0.378 | 0.369 | 0.655 | 0.194 |

Accuracy, precision, recall, F1, ROC-AUC and PR-AUC are on the test years 2008-2013. Bagging's CV ROC-AUC
per fold is 0.783, 0.746, 0.781 and 0.800. In the test years it detects 174 of 394 shocks (44 %) and
raises 354 false alarms out of 3,851 normal crop-years (9 %).

### 3.3 IF-THEN rules (shallow Decision Tree)

| rule | train shock rate | lift | test shock rate |
|---|---|---|---|
| last year's deviation ≤ −26.6 % AND pesticide intensity ≤ 2.22 | 59.7 % | 5.7 | 71.4 % |
| −26.6 % < last year's deviation ≤ −19.7 % AND region = Sub-Saharan Africa | 44.1 % | 4.2 | 28.0 % |
| last year's deviation ≤ −26.6 % AND pesticide intensity > 2.22 | 44.0 % | 4.2 | 40.0 % |
| last year's deviation > −8.6 % AND rainfall ≤ 1,216 mm AND pesticide ≤ 4.33 AND crop = sorghum | 18.9 % | 1.8 | 20.6 % |
| *climate only:* 0.91 < temperature anomaly ≤ 1.26 °C AND pesticide intensity ≤ 4.15 | 19.5 % | 1.8 | **10.3 %** |

The climate-only rule does not hold in the test years. Warming shifts the whole anomaly distribution,
so a fixed cut-off learned in the 1990s marks many ordinary years in the 2010s.

### 3.4 Drivers and subgroups

* Permutation importance (drop in test ROC-AUC): last year's deviation 0.170, rainfall level 0.034,
  crop 0.031, pesticide intensity 0.025, region 0.007, temperature anomaly 0.005, rainfall deviation 0.
* Test ROC-AUC by crop runs from 0.63 (wheat) to 0.85 (cassava). By region it runs from 0.66
  (Europe & Central Asia) to 0.79 (Sub-Saharan Africa, East Asia & Pacific); South Asia's 0.96 rests on
  7 shocks.

### 3.5 Regression baseline (linear regression on `yield_dev_pct`, winsorised)

| features | R² | MAE (pp) | RMSE (pp) | ROC-AUC as shock score |
|---|---|---|---|---|
| A. climate only | −0.009 | 13.31 | 20.34 | 0.526 |
| B. + crop, region, rainfall | −0.005 | 13.24 | 20.29 | 0.550 |
| C. + last year's yield | 0.143 | 11.89 | 18.73 | 0.678 |
| naive (training mean) | −0.001 | 13.24 | 20.25 | 0.500 |

Temperature coefficient: −1.0 percentage points of yield deviation per standard deviation of anomaly.
Thresholded at −15 %, the regression detects only 5.6 % of shocks, so classification is the better
framing.

## 4. Association rules: shock recipes (notebook 03)

Apriori and FP-growth return the same 3,271 frequent itemsets (minimum support 0.5 %). There are 203
rules with consequent SHOCK and lift > 1.

* The **strongest rules all contain `last_year=shock`** (lift 4.3-4.9, confidence 45-50 %), with low
  pesticide use, Sub-Saharan Africa, humid climate or roots & tubers.
* **Climate and input recipes**: semi-arid + low pesticide use → 20-22 % shocks (lift 2.0-2.2);
  arid + low pesticide use → 17.8 % (1.75); medium pesticide use + anomaly above +1 °C → 16.8 % (1.64);
  pesticide use cut by more than 20 % → 13.5 % (1.33); anomaly above +1 °C alone → 13.0 % (1.27).
* **The recipe differs by crop**: cereals respond to aridity with low inputs (lift 2.4-2.9), oilseeds to
  heat above +1 °C (1.7-2.1), and roots & tubers show only weak patterns (≤ 1.9).
* **The recipe differs by region**: Sub-Saharan Africa, sub-humid with low pesticide use (30-34 % shocks,
  lift 2.0-2.4); Europe & Central Asia and the Middle East & North Africa, semi-arid (1.8-1.9);
  Latin America, pesticide cuts (2.1); East Asia & Pacific, no recipe (1.06).

## 5. Answer to the research questions

1. **Can a yield shock be detected in advance from rainfall deviation, temperature anomaly and pesticide
   intensity?** Not from these three national annual features alone: test ROC-AUC 0.52-0.57. With
   crop, region, aridity and last year's yield outcome, an ensemble ranks risk usefully (ROC-AUC 0.76,
   PR-AUC 0.34 against a 9 % base rate) and catches 44 % of shocks at a 9 % false-alarm rate. Most of
   that skill comes from shock persistence and structural vulnerability, not from the year's climate
   anomaly.
2. **Which combinations of climate stress produce shocks?** Aridity combined with low input use is the
   most consistent recipe (lift ~2). Heat above +1 °C matters mostly for soybeans and for cereals in
   Sub-Saharan Africa. Rainfall deviation could not be tested with this source.
3. **Do the patterns differ by crop and region?** Yes. Shock rates range from 5 % (yams) to 18 % (sorghum)
   and from 2.6 % (South Asia) to 14.5 % (Sub-Saharan Africa), and the best recipe changes by crop group
   and by region (section 4).

## 6. Comparison with recent studies

| study | data and task | reported result | relation to AgriPulse |
|---|---|---|---|
| Gupta et al., *Innovations in Agricultural Forecasting: A Multivariate Regression Study on Global Crop Yield Prediction*, arXiv:2312.02254 (2023, v2 2024) | FAO yields + World Bank climate data, 196 countries; regression of the yield *level* (six models) | Random Forest R² = 0.94 | Predicting the level is easy because levels differ by crop and country (5th-95th percentile 7,001-229,245 hg/ha in our data). Our target is the deviation from each series' own baseline, where linear R² is 0.14. The abstract does not state the split; a random split would let future years inform the past. |
| Anderson et al., *Preseason maize and wheat yield forecasts for early warning of crop failure*, Nature Communications 15 (2024), doi:10.1038/s41467-024-51555-8 | gridded, sub-national climate forecasts | skilful up to a year ahead for 15 % (maize) and 30 % (wheat) of harvested areas | Even with gridded seasonal data, skill is limited to part of the cropland. This supports our finding that national annual means carry little shock signal. |
| Hobbs & Anttila-Hughes, *Scalable Country-Level Crop Yield Modeling for Food Security and Risk Mitigation*, NeurIPS 2025 Workshop on Tackling Climate Change with ML | country-level models from coarse data (LSMS-ISA countries) | proposal stage, no metrics reported | Same motivation (country-scale early warning from coarse data). |

> **To do before submission:** these three references were checked against their abstract pages only.
> Read the full papers before quoting them, and add more 2024-2026 studies from Scopus or Google Scholar
> (search terms: "crop yield anomaly", "crop failure early warning", "yield shock machine learning").

## 7. Limitations

* Rainfall deviation is empty in this source (section 1). Replacing it with a real annual series, such
  as CRU TS from the World Bank Climate Change Knowledge Portal, is the most valuable next step.
* National annual averages hide growing-season and sub-national extremes.
* Pesticide use is a country total in tonnes. Without cropland area it measures the scale of input use,
  not the rate per hectare.
* The temperature file's provenance should be verified (station-like records back to 1743).
* Food-insecure countries without pesticide or temperature data are missing from Gold.
* The label is relative to a moving 5-year baseline, so last year's yield enters both the feature
  `prev_yield_dev_pct` and this year's baseline. The history features therefore partly capture how the
  label is built (a bumper year raises next year's baseline, for example), not only real persistence.
