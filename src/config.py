"""Shared constants for the AgriPulse pipeline and mining notebooks.

Every value here has a twin in the SQL scripts (sql/02_silver.sql and
sql/03_gold.sql). Change both together, otherwise the SQL Gold layer
and the pandas Gold layer stop matching.
"""

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_ROOT / "data"
SOURCE_DIR = DATA_DIR / "raw"            # the four source files
REFERENCE_DIR = DATA_DIR / "reference"  # seed tables written for the project
GOLD_DIR = DATA_DIR / "exports"         # Gold layer exported by src.ingest.pipeline
FIGURES_DIR = PROJECT_ROOT / "reports" / "figures"

# Gold fact window: the years where all four sources overlap
# (temperature ends in 2013, pesticides start in 1990).
ANALYSIS_START_YEAR = 1990
ANALYSIS_END_YEAR = 2013

# Yield shock label: yield at least SHOCK_THRESHOLD_PCT below the mean of the
# previous BASELINE_YEARS years of the same country and crop.
BASELINE_YEARS = 5
MIN_BASELINE_YEARS = 3
SHOCK_THRESHOLD_PCT = -15.0

# Temperature anomaly is measured against the WMO 1961-1990 climate normal.
TEMP_NORMAL_START = 1961
TEMP_NORMAL_END = 1990

# Rainfall grid built in Silver (missing years are imputed with the country mean).
RAINFALL_START_YEAR = 1985
RAINFALL_END_YEAR = 2017

# FAO area code of the "China" aggregate (mainland + Hong Kong + Macao + Taiwan),
# dropped so that China is not counted twice.
FAO_CHINA_AGGREGATE_CODE = 351

CROP_GROUPS = {
    "Maize": "Cereals",
    "Wheat": "Cereals",
    "Rice, paddy": "Cereals",
    "Sorghum": "Cereals",
    "Potatoes": "Roots & Tubers",
    "Sweet potatoes": "Roots & Tubers",
    "Cassava": "Roots & Tubers",
    "Yams": "Roots & Tubers",
    "Soybeans": "Oilseeds",
    "Plantains and others": "Starchy Fruits",
}

# Climate bands: (label, lower bound inclusive, upper bound exclusive).
TEMP_BANDS = [
    ("Cold", -100.0, 10.0),
    ("Temperate", 10.0, 20.0),
    ("Warm", 20.0, 25.0),
    ("Hot", 25.0, 100.0),
]
RAIN_BANDS = [
    ("Arid", 0.0, 250.0),
    ("Semi-arid", 250.0, 500.0),
    ("Sub-humid", 500.0, 1000.0),
    ("Humid", 1000.0, 2000.0),
    ("Very humid", 2000.0, 100000.0),
]

# Time-ordered evaluation split used by the notebooks.
TRAIN_END_YEAR = 2007  # train 1990-2007, test 2008-2013
RANDOM_STATE = 42
