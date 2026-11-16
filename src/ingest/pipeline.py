"""Pandas implementation of the AgriPulse Medallion pipeline (Bronze -> Silver -> Gold).

The reference implementation is the SQL Server warehouse in sql/. This module
applies the same rules step by step so the mining notebooks can run on any
machine, and so the two Gold layers can be compared row for row.

Run from the project root:
    python -m src.ingest.pipeline
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from src import config as cfg


# ---------------------------------------------------------------------------
# Bronze: raw files as text, nothing parsed (mirrors the NVARCHAR tables)
# ---------------------------------------------------------------------------

BRONZE_FILES = {
    "fao_yield": cfg.SOURCE_DIR / "yield.csv",
    "wb_rainfall": cfg.SOURCE_DIR / "rainfall.csv",
    "wb_temperature": cfg.SOURCE_DIR / "temp.csv",
    "fao_pesticides": cfg.SOURCE_DIR / "pesticides.csv",
    "ref_country": cfg.REFERENCE_DIR / "country_reference.csv",
    "ref_country_alias": cfg.REFERENCE_DIR / "country_aliases.csv",
}

BRONZE_COLUMNS = {
    "fao_yield": ["domain_code", "domain", "area_code", "area", "element_code", "element",
                  "item_code", "item", "year_code", "year", "unit", "value"],
    "wb_rainfall": ["area", "year", "average_rain_fall_mm_per_year"],
    "wb_temperature": ["year", "country", "avg_temp"],
    "fao_pesticides": ["domain", "area", "element", "item", "year", "unit", "value"],
    "ref_country": ["country_name", "iso3", "region"],
    "ref_country_alias": ["source_name", "country_name"],
}


def load_bronze() -> dict[str, pd.DataFrame]:
    """Raw files as text, plus the provenance columns source_file and ingested_at."""
    bronze = {}
    ingested_at = pd.Timestamp.now()
    for name, path in BRONZE_FILES.items():
        df = pd.read_csv(path, dtype=str, keep_default_na=False, encoding="utf-8")
        df.columns = BRONZE_COLUMNS[name]
        df["source_file"] = str(path)
        df["ingested_at"] = ingested_at
        bronze[name] = df
    return bronze


# ---------------------------------------------------------------------------
# Silver: typed, trimmed, conformed country names, de-duplicated
# ---------------------------------------------------------------------------

# Reasons written to the reject log, keyed by (Bronze table, failed column);
# the same texts as silver.reject_log in sql/02_silver.sql.
REJECT_REASONS = {
    ("ref_country", "missing"): "missing country_name",
    ("ref_country", "duplicate"): "duplicate country_name (first row kept)",
    ("ref_country_alias", "missing"): "missing source_name",
    ("ref_country_alias", "duplicate"): "duplicate source_name (first row kept)",
    ("fao_yield", "element"): "not a yield record (element / unit)",
    ("fao_yield", "year"): "missing or invalid year",
    ("fao_yield", "area_code"): "FAO China aggregate (area 351) double counts its parts",
    ("fao_yield", "value"): "missing or zero yield (FAO missing record)",
    ("fao_yield", "area"): "duplicate country x crop x year after name conforming (lowest area code kept)",
    ("wb_rainfall", "year"): "missing or invalid year",
    ("wb_rainfall", "average_rain_fall_mm_per_year"): "missing or non-numeric rainfall (blank or ..)",
    ("wb_rainfall", "negative"): "negative rainfall",
    ("wb_temperature", "year"): "missing or invalid year",
    ("wb_temperature", "avg_temp"): "missing or non-numeric temperature",
    ("fao_pesticides", "item"): "not Use / Pesticides (total)",
    ("fao_pesticides", "year"): "missing or invalid year",
    ("fao_pesticides", "value"): "missing or negative pesticide value",
}
REJECT_COLUMNS = ["source_table", "business_key", "column_name", "raw_value", "reason"]


def _num(s: pd.Series) -> pd.Series:
    """TRY_CAST equivalent: blanks, '..' and 'NA' become NaN."""
    return pd.to_numeric(s.str.strip(), errors="coerce")


def _conform(names: pd.Series, aliases: dict[str, str]) -> pd.Series:
    trimmed = names.str.strip()
    return trimmed.map(aliases).fillna(trimmed)


def _text(bronze: dict[str, pd.DataFrame], name: str) -> pd.DataFrame:
    """The CSV columns of a Bronze table, trimmed (provenance columns left out)."""
    return bronze[name][BRONZE_COLUMNS[name]].apply(lambda c: c.str.strip())


def _rejects(table: str, rows: pd.DataFrame, key: pd.Series, column: pd.Series,
             raw: pd.Series, reason_key: pd.Series | None = None) -> pd.DataFrame:
    """Reject-log rows for `rows`; reason_key defaults to the failed column.

    An empty raw value is stored as missing (NaN), as BULK INSERT loads an
    empty CSV field as NULL.
    """
    reason_key = column if reason_key is None else reason_key
    raw = pd.Series(np.asarray(raw, dtype=object), index=rows.index)
    out = pd.DataFrame({
        "source_table": f"bronze.{table}",
        "business_key": key,
        "column_name": column,
        "raw_value": raw.where(raw != ""),
        "reason": [REJECT_REASONS[(table, k)] for k in reason_key],
    }, index=rows.index)
    return out[REJECT_COLUMNS]


def build_silver(bronze: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    rejects = []

    # --- reference tables (first row wins on duplicates, blanks rejected) ---
    country = _text(bronze, "ref_country")
    blank, dup = country.country_name == "", country.country_name.duplicated() & (country.country_name != "")
    bad = country[blank | dup]
    rejects.append(_rejects("ref_country", bad, bad.country_name, pd.Series("country_name", bad.index),
                            bad.country_name, np.where(blank[bad.index], "missing", "duplicate")))
    country = country[~blank & ~dup]

    alias_df = _text(bronze, "ref_country_alias")
    blank, dup = alias_df.source_name == "", alias_df.source_name.duplicated() & (alias_df.source_name != "")
    bad = alias_df[blank | dup]
    rejects.append(_rejects("ref_country_alias", bad, bad.source_name, pd.Series("source_name", bad.index),
                            bad.source_name, np.where(blank[bad.index], "missing", "duplicate")))
    alias_df = alias_df[~blank & ~dup]
    aliases = dict(zip(alias_df.source_name, alias_df.country_name))

    # --- FAO yield -------------------------------------------------------
    raw = _text(bronze, "fao_yield")
    y = bronze["fao_yield"][BRONZE_COLUMNS["fao_yield"]].copy()
    y["area_code"] = _num(y.area_code)
    y["item_code"] = _num(y.item_code)
    y["year"] = _num(y.year)
    y["yield_hg_ha"] = _num(y.value)
    failed = pd.Series(np.select(
        [(raw.element != "Yield") | (raw.unit != "hg/ha"),
         y.year.isna(),
         y.area_code == cfg.FAO_CHINA_AGGREGATE_CODE,
         ~(y.yield_hg_ha > 0)],  # 0 hg/ha in FAO data marks a missing record
        ["element", "year", "area_code", "value"], default=""), index=y.index)
    y["source_area"] = raw.area
    y["country_name"] = _conform(y.area, aliases)
    y["crop_name"] = raw.item
    y["crop_group"] = y.crop_name.map(cfg.CROP_GROUPS).fillna("Other")
    kept = y[failed == ""].sort_values(["country_name", "crop_name", "year", "area_code"])
    dup_idx = kept.index[kept.duplicated(["country_name", "crop_name", "year"])]
    failed[dup_idx] = "area"
    bad = raw[failed != ""]
    col = failed[bad.index]
    raw_value = np.select(
        [col == "element", col == "year", col == "area_code", col == "value"],
        [bad.element + " / " + bad.unit, bad.year, bad.area_code, bad.value], default=bad.area)
    rejects.append(_rejects("fao_yield", bad, bad.area + " | " + bad.item + " | " + bad.year,
                            col, raw_value))
    y = kept.drop(dup_idx)
    silver_yield = y[["country_name", "source_area", "area_code", "crop_name", "item_code",
                      "crop_group", "year", "yield_hg_ha"]].rename(
        columns={"area_code": "fao_area_code", "item_code": "fao_item_code"})
    silver_yield = silver_yield.astype({"fao_area_code": int, "fao_item_code": int, "year": int})

    # --- World Bank rainfall --------------------------------------------
    raw = _text(bronze, "wb_rainfall")
    r = bronze["wb_rainfall"][BRONZE_COLUMNS["wb_rainfall"]].copy()
    r["country_name"] = _conform(r.area, aliases)
    r["year"] = _num(r.year)
    r["rainfall_mm"] = _num(r.average_rain_fall_mm_per_year)
    ok = r.year.notna() & (r.rainfall_mm >= 0)
    bad, rb = raw[~ok], r[~ok]
    col = np.where(rb.year.isna(), "year", "average_rain_fall_mm_per_year")
    reason = np.where(rb.year.isna(), "year",
                      np.where(rb.rainfall_mm.isna(), "average_rain_fall_mm_per_year", "negative"))
    rejects.append(_rejects("wb_rainfall", bad, bad.area + " | " + bad.year, col,
                            np.where(rb.year.isna(), bad.year, bad.average_rain_fall_mm_per_year), reason))
    r = r[ok]
    r = r.groupby(["country_name", "year"], as_index=False).rainfall_mm.mean()
    # Complete country x year grid; gaps (blank cells, and 1988/2003 which are
    # absent from the file) get the country's long-term mean.
    years = pd.DataFrame({"year": range(cfg.RAINFALL_START_YEAR, cfg.RAINFALL_END_YEAR + 1)})
    grid = pd.DataFrame({"country_name": r.country_name.unique()}).merge(years, how="cross")
    rain = grid.merge(r, on=["country_name", "year"], how="left")
    country_mean = rain.groupby("country_name").rainfall_mm.transform("mean")
    rain["is_imputed"] = rain.rainfall_mm.isna().astype(int)
    rain["rainfall_mm"] = rain.rainfall_mm.fillna(country_mean)
    silver_rain = rain.astype({"year": int})

    # --- Temperature (several city records per country-year) ------------
    raw = _text(bronze, "wb_temperature")
    t = bronze["wb_temperature"][BRONZE_COLUMNS["wb_temperature"]].copy()
    t["country_name"] = _conform(t.country, aliases)
    t["year"] = _num(t.year)
    t["avg_temp"] = _num(t.avg_temp)
    ok = t.year.notna() & t.avg_temp.notna()
    bad, tb = raw[~ok], t[~ok]
    col = np.where(tb.year.isna(), "year", "avg_temp")
    rejects.append(_rejects("wb_temperature", bad, bad.country + " | " + bad.year, col,
                            np.where(tb.year.isna(), bad.year, bad.avg_temp)))
    t = t[ok]
    silver_temp = (t.groupby(["country_name", "year"])
                    .agg(avg_temp_c=("avg_temp", "mean"), n_records=("avg_temp", "size"))
                    .reset_index().astype({"year": int}))

    # --- FAO pesticides --------------------------------------------------
    raw = _text(bronze, "fao_pesticides")
    p = bronze["fao_pesticides"][BRONZE_COLUMNS["fao_pesticides"]].copy()
    p["country_name"] = _conform(p.area, aliases)
    p["year"] = _num(p.year)
    p["pesticides_tonnes"] = _num(p.value)
    not_item = (raw.element != "Use") | (raw.item != "Pesticides (total)")
    ok = ~not_item & p.year.notna() & (p.pesticides_tonnes >= 0)
    bad = raw[~ok]
    col = np.select([not_item[~ok], p.year[~ok].isna()], ["item", "year"], default="value")
    raw_value = np.select([col == "item", col == "year"],
                          [bad.element + " / " + bad.item, bad.year], default=bad.value)
    rejects.append(_rejects("fao_pesticides", bad, bad.area + " | " + bad.year, col, raw_value))
    p = p[ok]
    silver_pest = (p.groupby(["country_name", "year"], as_index=False).pesticides_tonnes.mean()
                    .astype({"year": int}))

    return {
        "country": country.reset_index(drop=True),
        "fao_yield": silver_yield.reset_index(drop=True),
        "wb_rainfall": silver_rain.reset_index(drop=True),
        "wb_temperature": silver_temp,
        "fao_pesticides": silver_pest,
        "reject_log": pd.concat(rejects, ignore_index=True),
    }


# ---------------------------------------------------------------------------
# Gold: star schema (dimensions + crop-year fact) and the flat ML view
# ---------------------------------------------------------------------------

def _band(value: float, bands: list[tuple[str, float, float]]) -> str | None:
    if pd.isna(value):
        return None
    for label, low, high in bands:
        if low <= value < high:
            return label
    return None


def _yield_features(silver_yield: pd.DataFrame) -> pd.DataFrame:
    """LAG / moving-window features over the full yield history (1961+).

    Each country-crop series is first densified to one row per calendar year
    (missing years = NaN), so LAG means "the previous calendar year" and the
    5-row window means "the previous 5 calendar years", even across gaps.
    """
    keys = ["country_name", "crop_name"]
    spans = silver_yield.groupby(keys).year.agg(["min", "max"])
    dense = pd.DataFrame(
        [(c, k, yr) for (c, k), (lo, hi) in spans.iterrows() for yr in range(lo, hi + 1)],
        columns=keys + ["year"],
    )
    y = dense.merge(silver_yield, on=keys + ["year"], how="left")
    y = y.sort_values(keys + ["year"]).reset_index(drop=True)
    g = y.groupby(keys, sort=False)

    y["prev_yield_hg_ha"] = g.yield_hg_ha.shift(1)
    y["yoy_change_pct"] = (y.yield_hg_ha / y.prev_yield_hg_ha - 1) * 100

    # AVG / COUNT(...) OVER (ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING)
    lagged = g.yield_hg_ha.shift(1)
    roll = lagged.groupby([y.country_name, y.crop_name], sort=False).rolling(
        cfg.BASELINE_YEARS, min_periods=1)
    y["baseline_n_years"] = roll.count().reset_index(level=[0, 1], drop=True).fillna(0).astype(int)
    y["baseline_yield_hg_ha"] = roll.mean().reset_index(level=[0, 1], drop=True)
    y.loc[y.baseline_n_years < cfg.MIN_BASELINE_YEARS, "baseline_yield_hg_ha"] = np.nan

    y["yield_dev_pct"] = (y.yield_hg_ha / y.baseline_yield_hg_ha - 1) * 100
    y["is_shock"] = np.where(y.yield_dev_pct.isna(), np.nan,
                             (y.yield_dev_pct <= cfg.SHOCK_THRESHOLD_PCT).astype(float))

    g = y.groupby(keys, sort=False)
    y["prev_yield_dev_pct"] = g.yield_dev_pct.shift(1)
    y["prev_is_shock"] = g.is_shock.shift(1)
    y = y[y.yield_hg_ha.notna()].copy()
    return y.astype({"fao_area_code": int, "fao_item_code": int})


def build_gold(silver: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    country = silver["country"]

    # Climate normals per country
    temp = silver["wb_temperature"]
    normal = temp[temp.year.between(cfg.TEMP_NORMAL_START, cfg.TEMP_NORMAL_END)]
    temp_normal = normal.groupby("country_name").avg_temp_c.agg(["mean", "count"])
    temp_normal = temp_normal[temp_normal["count"] >= 20]["mean"].rename("temp_normal_c")

    rain = silver["wb_rainfall"]
    rain_normal = (rain[rain.is_imputed == 0].groupby("country_name").rainfall_mm.mean()
                   .rename("rainfall_normal_mm"))

    temp_f = temp.merge(temp_normal, on="country_name")
    temp_f["temp_anomaly_c"] = temp_f.avg_temp_c - temp_f.temp_normal_c

    rain_f = rain.merge(rain_normal, on="country_name")
    rain_f["rain_dev_pct"] = (rain_f.rainfall_mm / rain_f.rainfall_normal_mm - 1) * 100
    rain_f.loc[rain_f.rainfall_normal_mm == 0, "rain_dev_pct"] = np.nan

    pest = silver["fao_pesticides"].sort_values(["country_name", "year"]).copy()
    pg = pest.groupby("country_name")
    prev_t = pg.pesticides_tonnes.shift(1).where(pest.year - pg.year.shift(1) == 1)
    pest["pesticide_intensity"] = np.log10(1 + pest.pesticides_tonnes)
    pest["pesticide_yoy_pct"] = np.where(prev_t > 0, (pest.pesticides_tonnes / prev_t - 1) * 100,
                                         np.nan)

    y = _yield_features(silver["fao_yield"])

    fact = (
        y[y.year.between(cfg.ANALYSIS_START_YEAR, cfg.ANALYSIS_END_YEAR) & y.is_shock.notna()]
        .merge(country[["country_name"]], on="country_name")
        .merge(rain_f[["country_name", "year", "rainfall_mm", "is_imputed", "rain_dev_pct",
                       "rainfall_normal_mm"]], on=["country_name", "year"])
        .merge(temp_f[["country_name", "year", "avg_temp_c", "temp_anomaly_c", "temp_normal_c"]],
               on=["country_name", "year"])
        .merge(pest[["country_name", "year", "pesticides_tonnes", "pesticide_intensity",
                     "pesticide_yoy_pct"]], on=["country_name", "year"])
        .rename(columns={"is_imputed": "rain_is_imputed"})
    )

    # --- Dimensions ----------------------------------------------------
    dim_country = (country[country.country_name.isin(fact.country_name)]
                   .merge(temp_normal, left_on="country_name", right_index=True, how="left")
                   .merge(rain_normal, left_on="country_name", right_index=True, how="left")
                   .sort_values("country_name").reset_index(drop=True))
    dim_country.insert(0, "country_key", np.arange(1, len(dim_country) + 1))

    dim_crop = (fact[["crop_name", "fao_item_code", "crop_group"]].drop_duplicates()
                .sort_values("crop_name").reset_index(drop=True))
    dim_crop.insert(0, "crop_key", np.arange(1, len(dim_crop) + 1))

    years = np.arange(cfg.ANALYSIS_START_YEAR, cfg.ANALYSIS_END_YEAR + 1)
    dim_year = pd.DataFrame({
        "year_key": years,
        "year": years,
        "decade": [f"{yr // 10 * 10}s" for yr in years],
        "five_year_period": [f"{yr // 5 * 5}-{yr // 5 * 5 + 4}" for yr in years],
    })

    bands = []
    for t_label, t_low, t_high in cfg.TEMP_BANDS:
        for r_label, r_low, r_high in cfg.RAIN_BANDS:
            bands.append((f"{t_label} / {r_label}", t_label, r_label, t_low, t_high, r_low, r_high))
    dim_band = pd.DataFrame(bands, columns=["climate_band", "temp_band", "rain_band",
                                            "temp_min_c", "temp_max_c", "rain_min_mm", "rain_max_mm"])
    dim_band.insert(0, "climate_band_key", np.arange(1, len(dim_band) + 1))

    # --- Fact ------------------------------------------------------------
    fact["temp_band"] = fact.temp_normal_c.map(lambda v: _band(v, cfg.TEMP_BANDS))
    fact["rain_band"] = fact.rainfall_normal_mm.map(lambda v: _band(v, cfg.RAIN_BANDS))
    fact = (fact
            .merge(dim_country[["country_key", "country_name"]], on="country_name")
            .merge(dim_crop[["crop_key", "crop_name"]], on="crop_name")
            .merge(dim_band[["climate_band_key", "temp_band", "rain_band"]],
                   on=["temp_band", "rain_band"], how="left"))
    fact["year_key"] = fact.year
    fact["is_shock"] = fact.is_shock.astype(int)
    fact["prev_is_shock"] = fact.prev_is_shock.astype("Int64")

    fact_cols = [
        "country_key", "crop_key", "year_key", "climate_band_key",
        "yield_hg_ha", "prev_yield_hg_ha", "yoy_change_pct",
        "baseline_yield_hg_ha", "baseline_n_years", "yield_dev_pct", "is_shock",
        "prev_yield_dev_pct", "prev_is_shock",
        "rainfall_mm", "rain_dev_pct", "rain_is_imputed",
        "avg_temp_c", "temp_anomaly_c",
        "pesticides_tonnes", "pesticide_intensity", "pesticide_yoy_pct",
    ]
    fact = fact[fact_cols].sort_values(["country_key", "crop_key", "year_key"]).reset_index(drop=True)

    return {
        "dim_country": dim_country,
        "dim_crop": dim_crop,
        "dim_year": dim_year,
        "dim_climate_band": dim_band,
        "fact_crop_year": fact,
    }


def ml_dataset(gold: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """Flat analytical table; same columns as the SQL view gold.vw_ml_dataset."""
    f = (gold["fact_crop_year"]
         .merge(gold["dim_country"], on="country_key")
         .merge(gold["dim_crop"], on="crop_key")
         .merge(gold["dim_year"], on="year_key")
         .merge(gold["dim_climate_band"][["climate_band_key", "climate_band", "temp_band", "rain_band"]],
                on="climate_band_key", how="left"))
    cols = [
        "country_name", "iso3", "region", "crop_name", "crop_group", "year", "decade",
        "climate_band", "temp_band", "rain_band",
        "yield_hg_ha", "prev_yield_hg_ha", "yoy_change_pct", "baseline_yield_hg_ha",
        "yield_dev_pct", "is_shock", "prev_yield_dev_pct", "prev_is_shock",
        "rainfall_mm", "rain_dev_pct", "rain_is_imputed", "avg_temp_c", "temp_anomaly_c",
        "pesticides_tonnes", "pesticide_intensity", "pesticide_yoy_pct",
    ]
    return f[cols].sort_values(["country_name", "crop_name", "year"]).reset_index(drop=True)


def run(write: bool = True) -> dict[str, pd.DataFrame]:
    bronze = load_bronze()
    silver = build_silver(bronze)
    gold = build_gold(silver)
    gold["ml_dataset"] = ml_dataset(gold)
    if write:
        cfg.GOLD_DIR.mkdir(parents=True, exist_ok=True)
        for name, df in gold.items():
            df.to_csv(cfg.GOLD_DIR / f"{name}.csv", index=False, encoding="utf-8")
    return {"bronze": bronze, "silver": silver, "gold": gold}


if __name__ == "__main__":
    layers = run()
    for layer, tables in layers.items():
        for name, df in tables.items():
            print(f"{layer}.{name}: {len(df):,} rows")
    ml = layers["gold"]["ml_dataset"]
    print(f"shock rate: {ml.is_shock.mean():.1%}  ({ml.is_shock.sum():,} shocks)")
