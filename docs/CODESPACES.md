# AgriPulse in the browser (GitHub Codespaces)

A real SQL Server 2022 runs next to this editor. When the codespace starts, it builds the
whole warehouse by itself (`setup/build_on_linux.py`): Bronze, Silver and Gold, and runs the 13 checks.

## الخطوات (بالعربي)

1. **استنى دقيقة** بعد ما الصفحة تفتح. البرنامج بيبني قاعدة البيانات لوحده.
   لما يخلص، هيتعمل ملف اسمه `.codespace/STATUS.txt` آخر سطر فيه:
   `13/13 quality checks passed` و `READY`.
2. **اعرض الجداول (زي SSMS):** في الشريط الشمال دوس على أيقونة **SQL Server** (شكلها أسطوانة).
   هتلاقي اتصال اسمه **AgriPulse (Codespace)**، دوس عليه وبعدين **Connect**.
   افتح **Databases ← AgriPulse ← Tables** وهتلاقي جداول `bronze` و `silver` و `gold`.
   لو طلب password اكتب: `AgriPulse!2026`
3. **شغّل أمر:** افتح `sql/demo_queries.sql`، وعلّم بالإصبع على أمر واحد (من `SELECT` لحد `;`)،
   ودوس زرار **▷ Execute Query** فوق على اليمين. أول مرة هيسألك على الاتصال: اختار **AgriPulse (Codespace)**.
   النتيجة هتظهر في جدول تحت أو جنب الكود.
4. **السكريبتات** مفتوحة قدامك: `sql/01_bronze.sql` و `sql/02_silver.sql` و `sql/03_gold.sql`.
5. **كل ملفات العرض مفتوحة فوق في tabs**، بترتيب طلبات الدكتور:
   الفكرة `PROJECT_SPEC.md`، المصادر `data_source_register.csv`، وبعدين لكل طبقة السكريبت والتقرير:
   `01_bronze.sql` + `bronze_report.pdf`، `02_silver.sql` + `silver_report.pdf`، `03_gold.sql` + `gold_report.pdf`،
   وفي الآخر `demo_queries.sql`. التقارير هنا PDF (نفس محتوى ملفات الـ Word بالظبط).
   الداتا نفسها في فولدر `data/raw` في شريط الملفات الشمال.

لو حاجة وقعت، افتح Terminal (القايمة ☰ ← Terminal ← New Terminal) واكتب:

```
python setup/build_on_linux.py
```

## Steps (English)

1. Wait about a minute: the warehouse builds itself. `.codespace/STATUS.txt` ends with
   `13/13 quality checks passed` and `READY` when it is done.
2. **Browse the tables:** click the **SQL Server** icon in the left bar, then the connection
   **AgriPulse (Codespace)**, then **Connect**. Open **Databases > AgriPulse > Tables**.
   If asked for a password: `AgriPulse!2026` (it only protects this private, throw-away container).
3. **Run a query:** open `sql/demo_queries.sql`, select one statement and click **Execute Query** (▷, top right).
   Pick the connection **AgriPulse (Codespace)** the first time.
4. Every file for the presentation is already open as a tab, in the instructor's order: `PROJECT_SPEC.md`,
   `data_source_register.csv`, then for each layer its script and its report (PDF copies of the Word reports),
   and `demo_queries.sql`.
5. Rebuild at any time from a terminal: `python setup/build_on_linux.py`.

The only difference from SQL Server on Windows: SQL Server for Linux has no `CODEPAGE` option for
`BULK INSERT`, so the build script feeds it UTF-16 copies of the CSV files and swaps that one option
in memory. The scripts in `sql/` are the same files you run on Windows.
