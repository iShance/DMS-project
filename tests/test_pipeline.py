"""Pandas pipeline (Bronze -> Silver -> Gold): schema, reconciliation, integrity, ranges.

No database needed. The same rules run in SQL Server; tests/test_sql.py checks
that both implementations agree.
"""

import io
from pathlib import Path

import numpy as np
import pandas as pd

from src import config as cfg
from src.ingest import pipeline

KEYS = ["country_name", "crop_name", "year"]


# --- reproducibility --------------------------------------------------------

def test_gold_reproduces_committed_csv_files(layers):
    for name, df in layers["gold"].items():
        committed = pd.read_csv(cfg.GOLD_DIR / f"{name}.csv", encoding="utf-8")
        fresh = pd.read_csv(io.StringIO(df.to_csv(index=False)))
        pd.testing.assert_frame_equal(fresh, committed, check_exact=False, rtol=1e-9, atol=1e-9,
                                      obj=name)


def test_headline_numbers(ml):
    assert len(ml) == 16_339
    assert ml.is_shock.sum() == 1_667
    assert ml.country_name.nunique() == 119 and ml.crop_name.nunique() == 10


# --- Bronze -------------------------------------------------------------------

def test_bronze_keeps_every_source_row_with_provenance(layers):
    for name, df in layers["bronze"].items():
        path = Path(df.source_file.iloc[0])
        raw_rows = sum(1 for _ in path.open(encoding="utf-8")) - 1  # minus header
        assert len(df) == raw_rows, name
        assert df.source_file.notna().all() and df.ingested_at.notna().all(), name
        assert list(df.columns[:-2]) == pipeline.BRONZE_COLUMNS[name], name


# --- Silver -------------------------------------------------------------------

def test_bronze_rows_equal_kept_rows_plus_rejects(layers):
    bronze, silver = layers["bronze"], layers["silver"]
    rejected = silver["reject_log"].source_table.value_counts()
    kept = {
        "fao_yield": len(silver["fao_yield"]),
        "wb_rainfall": int((silver["wb_rainfall"].is_imputed == 0).sum()),  # observed cells
        "wb_temperature": int(silver["wb_temperature"].n_records.sum()),     # records averaged
        "fao_pesticides": len(silver["fao_pesticides"]),
        "ref_country": len(silver["country"]),
    }
    for name, n_kept in kept.items():
        assert len(bronze[name]) == n_kept + rejected.get(f"bronze.{name}", 0), name


def test_reject_log_documents_the_known_source_issues(layers):
    log = layers["silver"]["reject_log"]
    assert set(log.reason) <= set(pipeline.REJECT_REASONS.values())
    counts = log.groupby("reason").size().to_dict()
    assert counts == {
        "FAO China aggregate (area 351) double counts its parts": 448,
        "missing or zero yield (FAO missing record)": 8,
        "missing or non-numeric rainfall (blank or ..)": 780,
        "missing or non-numeric temperature": 2547,
    }
    assert log.business_key.notna().all()


def test_silver_natural_keys_unique(layers):
    s = layers["silver"]
    assert not s["fao_yield"].duplicated(KEYS).any()
    assert not s["wb_rainfall"].duplicated(["country_name", "year"]).any()
    assert not s["wb_temperature"].duplicated(["country_name", "year"]).any()
    assert not s["fao_pesticides"].duplicated(["country_name", "year"]).any()
    assert not s["country"].duplicated("country_name").any()


def test_silver_accepted_ranges(layers):
    s = layers["silver"]
    assert (s["fao_yield"].yield_hg_ha > 0).all()
    assert s["wb_temperature"].avg_temp_c.between(-30, 45).all()
    assert (s["fao_pesticides"].pesticides_tonnes >= 0).all()
    assert (s["wb_rainfall"].rainfall_mm >= 0).all()


def test_rainfall_grid_is_complete(layers):
    rain = layers["silver"]["wb_rainfall"]
    n_years = cfg.RAINFALL_END_YEAR - cfg.RAINFALL_START_YEAR + 1
    assert (rain.groupby("country_name").size() == n_years).all()


def test_yield_countries_are_in_the_reference(layers):
    s = layers["silver"]
    assert set(s["fao_yield"].country_name) <= set(s["country"].country_name)


# --- Gold ---------------------------------------------------------------------

def test_fact_grain_is_unique(layers):
    fact = layers["gold"]["fact_crop_year"]
    assert not fact.duplicated(["country_key", "crop_key", "year_key"]).any()


def test_fact_keys_exist_in_dimensions(layers):
    g = layers["gold"]
    fact = g["fact_crop_year"]
    assert fact.country_key.isin(g["dim_country"].country_key).all()
    assert fact.crop_key.isin(g["dim_crop"].crop_key).all()
    assert fact.year_key.isin(g["dim_year"].year_key).all()
    assert fact.climate_band_key.notna().all()
    assert fact.climate_band_key.isin(g["dim_climate_band"].climate_band_key).all()


def test_label_matches_threshold(ml):
    expected = (ml.yield_dev_pct <= cfg.SHOCK_THRESHOLD_PCT).astype(int)
    assert (ml.is_shock == expected).all()


def test_gold_accepted_ranges(layers, ml):
    fact = layers["gold"]["fact_crop_year"]
    assert ml.year.between(cfg.ANALYSIS_START_YEAR, cfg.ANALYSIS_END_YEAR).all()
    assert fact.baseline_n_years.between(cfg.MIN_BASELINE_YEARS, cfg.BASELINE_YEARS).all()
    assert set(ml.is_shock.unique()) <= {0, 1}
    assert set(ml.prev_is_shock.dropna().unique()) <= {0, 1}
    assert (ml.pesticide_intensity >= 0).all()


def test_baseline_uses_only_the_five_previous_years(layers, ml):
    """Recompute every baseline from Silver yields: no information from the same or later years."""
    y = layers["silver"]["fao_yield"].set_index(KEYS).yield_hg_ha
    lagged = []
    for k in range(1, cfg.BASELINE_YEARS + 1):
        idx = pd.MultiIndex.from_arrays([ml.country_name, ml.crop_name, ml.year - k])
        lagged.append(y.reindex(idx).to_numpy())
    baseline = np.nanmean(np.vstack(lagged), axis=0)
    np.testing.assert_allclose(baseline, ml.baseline_yield_hg_ha, rtol=1e-9)


def test_previous_year_features_come_from_the_previous_year(ml):
    prev = ml[KEYS + ["yield_dev_pct", "is_shock"]].assign(year=ml.year + 1)
    both = ml.merge(prev, on=KEYS, suffixes=("", "_last_year"))
    assert len(both) > 10_000
    np.testing.assert_allclose(both.prev_yield_dev_pct, both.yield_dev_pct_last_year, rtol=1e-9)
    assert (both.prev_is_shock == both.is_shock_last_year).all()
