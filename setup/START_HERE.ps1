<#
.SYNOPSIS
    AgriPulse one-click setup: checks what the project needs, installs what is
    missing (after asking you), builds the database and opens everything for the
    presentation.

.DESCRIPTION
    Start it by double-clicking START_HERE.bat in the project folder. It runs these steps:
      1. find SQL Server; install SQL Server 2022 Express if there is none (asks first)
      2. find SSMS; install it if it is missing (asks first)
      3. copy the data files to C:\AgriPulse\data (a folder SQL Server can read)
      4. build and load the AgriPulse database: Bronze, Silver, Gold (+ semantic, ml)
      5. run the 13 data-quality checks
      6. optional: Python and the packages for the notebooks
      7. open the SQL scripts in SSMS and the reports, ready for the presentation
    It talks to SQL Server directly from PowerShell, so sqlcmd is not needed.
    Everything printed is also saved in setup_log.txt in the project folder.

.PARAMETER Server
    SQL Server to use, e.g. localhost or .\SQLEXPRESS. Found automatically if omitted.
.PARAMETER DataTarget
    Folder the data files are copied to. Default C:\AgriPulse\data.
.PARAMETER ServerDataPath
    The same data folder as the SQL Server machine sees it. Only needed when SQL
    Server runs on another machine; default: DataTarget.
.PARAMETER SqlUser
    Use a SQL Server login instead of Windows authentication (asks for the password).
.PARAMETER Yes
    Answer "yes" to every question.
.PARAMETER NoInstall
    Never install anything; only report what is missing.
.PARAMETER NoOpen
    Do not open SSMS, the reports or the folder at the end.
.PARAMETER SkipPython
    Skip the optional Python step.

.EXAMPLE
    START_HERE.bat
.EXAMPLE
    START_HERE.bat -Server .\SQLEXPRESS
#>
[CmdletBinding()]
param(
    [string]$Server = "",
    [string]$DataTarget = "C:\AgriPulse\data",
    [string]$ServerDataPath = "",
    [string]$SqlUser = "",
    [string]$SqlPassword = "",
    [string]$SqlDir = "",
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$NoOpen,
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $SqlDir) { $SqlDir = Join-Path $ProjectRoot "sql" }
if (-not $ServerDataPath) { $ServerDataPath = $DataTarget }
$ChecksFile = Join-Path (Join-Path (Join-Path $ProjectRoot "src") "quality") "checks.sql"
$LogFile = Join-Path $ProjectRoot "setup_log.txt"
$IsWin = ($env:OS -eq "Windows_NT")
$TotalSteps = 7
$Summary = [ordered]@{}

try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { }

trap {
    Write-Host ""
    Write-Host ("  ERROR  Unexpected problem: " + $_.Exception.Message) -ForegroundColor Red
    $Summary["Result"] = "STOPPED by an unexpected error (see above)"
    Close-Setup 1
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Write-Step([int]$n, [string]$title) {
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $n, $TotalSteps, $title) -ForegroundColor Cyan
}
function Write-Ok([string]$m)   { Write-Host "  OK     $m" -ForegroundColor Green }
function Write-Note([string]$m) { Write-Host "  NOTE   $m" -ForegroundColor Yellow }
function Write-Bad([string]$m)  { Write-Host "  ERROR  $m" -ForegroundColor Red }
function Write-Info([string]$m) { Write-Host "         $m" }

function Confirm-Step([string]$question, [bool]$defaultYes = $true) {
    if ($Yes) { return $true }
    $suffix = "[y/N]"
    if ($defaultYes) { $suffix = "[Y/n]" }
    $answer = Read-Host "  ?      $question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultYes }
    return $answer.Trim().ToLower().StartsWith("y")
}

function Close-Setup([int]$code) {
    Write-Host ""
    Write-Host "Summary" -ForegroundColor Cyan
    foreach ($k in $Summary.Keys) { Write-Host ("  {0,-22} {1}" -f $k, $Summary[$k]) }
    Write-Host ""
    Write-Host "Full log: $LogFile"
    try { Stop-Transcript | Out-Null } catch { }
    if (-not $Yes) { Read-Host "Press Enter to close this window" | Out-Null }
    exit $code
}

function Stop-Setup([string]$message, [string[]]$hints) {
    Write-Bad $message
    foreach ($h in $hints) { Write-Info $h }
    $Summary["Result"] = "STOPPED: $message"
    Close-Setup 1
}

function Install-Package([string]$wingetId, [string]$name, [string]$downloadUrl) {
    # Installs with winget after asking; falls back to the official download page.
    if ($NoInstall) { Write-Note "$name is missing (not installed because of -NoInstall)."; return $false }
    if (-not (Confirm-Step "$name is not installed. Install it now? It needs internet and can take several minutes.")) { return $false }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Info "Installing $name with winget ($wingetId)."
        Write-Info "If Windows asks for permission, click Yes."
        & winget install --id $wingetId --exact --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { Write-Ok "$name installed."; return $true }
        Write-Note "winget could not install $name (exit code $LASTEXITCODE)."
    } else {
        Write-Note "winget is not available on this PC."
    }
    Write-Info "Opening the official download page: $downloadUrl"
    try { Start-Process $downloadUrl } catch { }
    Read-Host "  ?      Install $name from that page, then press Enter here to continue" | Out-Null
    return $true
}

# ---------------------------------------------------------------------------
# SQL Server access through .NET (no sqlcmd needed)
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue

function Get-ConnectionString([string]$database) {
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b["Data Source"] = $script:ServerName
    $b["Initial Catalog"] = $database
    if ($SqlUser) {
        $b["User ID"] = $SqlUser
        $b["Password"] = $script:SqlPasswordPlain
    } else {
        $b["Integrated Security"] = $true
    }
    $b["TrustServerCertificate"] = $true
    $b["Connect Timeout"] = 15
    $b["Pooling"] = $false
    return $b.ConnectionString
}

function Open-Connection([string]$database) {
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-ConnectionString $database)
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
        param($sender, $e)
        foreach ($err in $e.Errors) {
            if ($err.Message -like ">>*") { Write-Host ("           " + $err.Message.Substring(3)) }
        }
    }
    $conn.add_InfoMessage($handler)
    $conn.Open()
    return $conn
}

function Test-SqlConnection {
    try { $c = Open-Connection "master"; $c.Close(); return $null }
    catch { return $_.Exception.Message }
}

function Invoke-SqlScript([string]$path) {
    # Runs a .sql file batch by batch (batches are separated by GO lines, as in SSMS).
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $batches = [regex]::Split($text, '(?im)^[ \t]*GO[ \t]*;?[ \t]*\r?$')
    $conn = Open-Connection "master"
    try {
        foreach ($batch in $batches) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = 900
            [void]$cmd.ExecuteNonQuery()
        }
    } finally { $conn.Close() }
}

function Invoke-SqlQuery([string]$query, [hashtable]$params) {
    # Returns the rows of a query against the AgriPulse database as a DataTable.
    $conn = Open-Connection "AgriPulse"
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $query
        $cmd.CommandTimeout = 900
        if ($params) { foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) } }
        $table = New-Object System.Data.DataTable
        $reader = $cmd.ExecuteReader()
        $table.Load($reader)
        return ,$table
    } finally { $conn.Close() }
}

function Get-QualityChecks {
    # (name, query) for every "-- check: name" block of src/quality/checks.sql
    $text = [System.IO.File]::ReadAllText($ChecksFile, [System.Text.Encoding]::UTF8)
    $blocks = [regex]::Split($text, '(?m)^-- check:[ \t]*') | Select-Object -Skip 1
    $checks = @()
    foreach ($block in $blocks) {
        $nl = $block.IndexOf("`n")
        $name = $block.Substring(0, $nl).Trim()
        $rest = $block.Substring($nl + 1)
        $statement = $rest.Substring(0, $rest.IndexOf(";"))
        $lines = $statement -split "`n" | Where-Object { -not $_.TrimStart().StartsWith("--") }
        $checks += ,@($name, ($lines -join "`n"))
    }
    return ,$checks
}

# ---------------------------------------------------------------------------
# Finding SQL Server and SSMS
# ---------------------------------------------------------------------------
function Find-SqlServerInstance {
    # Returns the server name to connect to, or "" if no SQL Server is installed.
    $services = @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "MSSQLSERVER" -or $_.Name -like 'MSSQL$*' })
    if ($services.Count -gt 0) {
        $ordered = @($services | Sort-Object @{ Expression = { $_.Status -ne "Running" } },
                                             @{ Expression = { $_.Name -ne "MSSQLSERVER" } },
                                             @{ Expression = { $_.Name -ne 'MSSQL$SQLEXPRESS' } })
        $svc = $ordered[0]
        $name = "localhost"
        if ($svc.Name -ne "MSSQLSERVER") { $name = ".\" + $svc.Name.Substring(6) }
        $script:SqlServiceName = $svc.Name
        if ($svc.Status -ne "Running") {
            Write-Note "SQL Server service $($svc.Name) is not running. Starting it..."
            try { Start-Service -Name $svc.Name -ErrorAction Stop }
            catch {
                Write-Info "Starting a service needs administrator rights. If Windows asks, click Yes."
                $cmdText = "Start-Service -Name '" + $svc.Name + "'"
                try { Start-Process powershell -Verb RunAs -Wait -ArgumentList @("-NoProfile", "-Command", $cmdText) } catch { }
            }
            $svc.Refresh()
            if ($svc.Status -ne "Running") { Write-Note "The service is still not running." }
        }
        return $name
    }
    $localdb = Get-Command sqllocaldb -ErrorAction SilentlyContinue
    if ($localdb) {
        & sqllocaldb start MSSQLLocalDB | Out-Null
        if ($LASTEXITCODE -eq 0) { return "(localdb)\MSSQLLocalDB" }
    }
    return ""
}

function Find-Ssms {
    # 1. on the PATH
    $onPath = Get-Command "ssms.exe" -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    # 2. registered application path
    foreach ($hive in @("HKLM:", "HKCU:")) {
        try {
            $key = Get-Item -Path ($hive + "\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\ssms.exe") -ErrorAction Stop
            $exe = "$($key.GetValue(''))".Trim('"')
            if ($exe -and (Test-Path $exe)) { return $exe }
        } catch { }
    }

    # 3. the usual install folders (64-bit and 32-bit Program Files)
    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, "C:\Program Files", "C:\Program Files (x86)") |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        # SSMS 18 and later: <Program Files>\Microsoft SQL Server Management Studio <version>\...\Ssms.exe
        $dirs = @(Get-ChildItem -Path $root -Directory -Filter "Microsoft SQL Server Management Studio*" -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            $found = Get-ChildItem -Path $d.FullName -Recurse -Filter "Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
        # SSMS 17 and earlier: <Program Files>\Microsoft SQL Server\<nnn>\Tools\Binn\ManagementStudio\Ssms.exe
        $old = Get-ChildItem -Path (Join-Path $root "Microsoft SQL Server\*\Tools\Binn\ManagementStudio\Ssms.exe") -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($old) { return $old.FullName }
    }

    # 4. the Start menu shortcut, wherever SSMS was installed
    try {
        $shell = New-Object -ComObject WScript.Shell
        $menus = @((Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"),
                   (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"))
        foreach ($menu in $menus) {
            $links = @(Get-ChildItem -Path $menu -Recurse -Filter "*Management Studio*.lnk" -ErrorAction SilentlyContinue)
            foreach ($link in $links) {
                $target = $shell.CreateShortcut($link.FullName).TargetPath
                if ($target -and ($target -like "*ssms*.exe") -and (Test-Path $target)) { return $target }
            }
        }
    } catch { }
    return ""
}

function Find-Python {
    foreach ($candidate in @("python", "py")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($cmd.Source -like "*WindowsApps*") { continue }   # the Microsoft Store shortcut, not a real Python
        try {
            $v = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3") { return $candidate }
        } catch { }
    }
    return ""
}

# ===========================================================================
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " AgriPulse - one-click setup and presentation launcher"          -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " Project folder: $ProjectRoot"
if ($SqlUser -and -not $SqlPassword) {
    $secure = Read-Host "  ?      Password for SQL login '$SqlUser'" -AsSecureString
    $script:SqlPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
} else {
    $script:SqlPasswordPlain = $SqlPassword
}

# ---------------------------------------------------------------------------
Write-Step 1 "SQL Server (the database engine)"
$script:SqlServiceName = ""
if ($Server) {
    $script:ServerName = $Server
    Write-Info "Using the server you gave: $Server"
} elseif ($IsWin) {
    $script:ServerName = Find-SqlServerInstance
    if (-not $script:ServerName) {
        Write-Note "No SQL Server was found on this PC."
        [void](Install-Package "Microsoft.SQLServer.2022.Express" "SQL Server 2022 Express" "https://www.microsoft.com/en-us/sql-server/sql-server-downloads")
        $script:ServerName = Find-SqlServerInstance
    }
} else {
    $script:ServerName = "localhost"
}
if (-not $script:ServerName) {
    Stop-Setup "SQL Server is not installed." @(
        "Install SQL Server Express (free): https://www.microsoft.com/en-us/sql-server/sql-server-downloads",
        "then run START_HERE.bat again.")
}
$problem = Test-SqlConnection
if ($problem) {
    Stop-Setup "Could not connect to SQL Server '$($script:ServerName)'." @(
        "Message: $problem",
        "Check that the SQL Server service is running (Windows: Services app, 'SQL Server').",
        "Or give the server name yourself, for example:  START_HERE.bat -Server .\SQLEXPRESS")
}
Write-Ok "Connected to SQL Server: $($script:ServerName)"
$Summary["SQL Server"] = $script:ServerName

# ---------------------------------------------------------------------------
Write-Step 2 "SSMS (the program you show the database in)"
$ssms = ""
if ($IsWin) {
    $ssms = Find-Ssms
    if (-not $ssms) {
        Write-Note "SSMS (SQL Server Management Studio) was not found."
        [void](Install-Package "Microsoft.SQLServerManagementStudio" "SSMS" "https://aka.ms/ssmsfullsetup")
        $ssms = Find-Ssms
    }
}
if ($ssms) { Write-Ok "SSMS found: $ssms"; $Summary["SSMS"] = "found" }
else {
    Write-Note "SSMS not found. The database will still be built."
    Write-Info "If SSMS is installed, open it from the Start menu; otherwise install it: https://aka.ms/ssmsfullsetup"
    $Summary["SSMS"] = "NOT FOUND - open SSMS from the Start menu"
}

# ---------------------------------------------------------------------------
Write-Step 3 "Copy the data files to $DataTarget"
try {
    foreach ($sub in @("raw", "reference")) {
        $src = Join-Path (Join-Path $ProjectRoot "data") $sub
        $dst = Join-Path $DataTarget $sub
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Copy-Item -Path (Join-Path $src "*.csv") -Destination $dst -Force
    }
    $n = @(Get-ChildItem -Path $DataTarget -Recurse -Filter "*.csv").Count
    Write-Ok "$n data files copied."
} catch {
    Stop-Setup "Could not copy the data files to $DataTarget." @(
        "Message: $($_.Exception.Message)",
        "Run START_HERE.bat again with another folder, e.g.:  START_HERE.bat -DataTarget D:\AgriPulse\data")
}
if ($IsWin -and -not $script:SqlServiceName) {
    # server given by name: work out its Windows service
    if ($script:ServerName -match '^(\.|localhost|\(local\)|127\.0\.0\.1)$') { $script:SqlServiceName = "MSSQLSERVER" }
    elseif ($script:ServerName -match '^(\.|localhost|\(local\))\\(.+)$') { $script:SqlServiceName = 'MSSQL$' + $Matches[2] }
}
if ($IsWin -and $script:SqlServiceName) {
    # let the SQL Server service account read the folder (BULK INSERT runs as that account)
    $account = "NT Service\" + $script:SqlServiceName
    $root = Split-Path -Parent $DataTarget
    $granted = $false
    try {
        & icacls $root /grant ($account + ":(OI)(CI)RX") /T /Q 2>&1 | Out-Null
        $granted = ($LASTEXITCODE -eq 0)
    } catch { $granted = $false }
    if ($granted) { Write-Ok "SQL Server ($account) can read the folder." }
    else { Write-Note "Could not change folder permissions (usually fine)." }
}
$Summary["Data folder"] = $DataTarget

# ---------------------------------------------------------------------------
Write-Step 4 "Build and load the AgriPulse database"
$scripts = @("00_init.sql", "01_bronze.sql", "02_silver.sql", "03_gold.sql",
             "04_semantic.sql", "05_feature_views.sql", "07_ml_outputs.sql")
try {
    foreach ($s in $scripts) {
        Invoke-SqlScript (Join-Path $SqlDir $s)
        Write-Ok "ran sql\$s"
    }
    Write-Info "Loading Bronze (the raw files)..."
    $conn = Open-Connection "AgriPulse"
    try {
        foreach ($proc in @("bronze.load_bronze", "silver.load_silver", "gold.load_gold")) {
            if ($proc -eq "silver.load_silver") { Write-Info "Loading Silver (cleaning)..." }
            if ($proc -eq "gold.load_gold") { Write-Info "Loading Gold (star schema)..." }
            $cmd = $conn.CreateCommand()
            $cmd.CommandTimeout = 900
            if ($proc -eq "bronze.load_bronze") {
                $cmd.CommandText = "EXEC bronze.load_bronze @data_path = @p"
                [void]$cmd.Parameters.AddWithValue("@p", $ServerDataPath)
            } else {
                $cmd.CommandText = "EXEC $proc"
            }
            [void]$cmd.ExecuteNonQuery()
        }
    } finally { $conn.Close() }
} catch {
    $msg = $_.Exception.Message
    $hints = @("Message: $msg")
    if ($msg -match "bulk load|Operating system error|access") {
        $hints += "SQL Server could not read the data files in $ServerDataPath."
        $hints += "Make sure that folder exists on the SQL Server machine and is not under your user profile or OneDrive."
    }
    Stop-Setup "Building the database failed." $hints
}
$counts = Invoke-SqlQuery @"
SELECT 'Bronze' AS layer, (SELECT COUNT(*) FROM bronze.fao_yield) + (SELECT COUNT(*) FROM bronze.wb_rainfall)
     + (SELECT COUNT(*) FROM bronze.wb_temperature) + (SELECT COUNT(*) FROM bronze.fao_pesticides)
     + (SELECT COUNT(*) FROM bronze.ref_country) + (SELECT COUNT(*) FROM bronze.ref_country_alias) AS row_count, '6 tables' AS note
UNION ALL SELECT 'Silver', (SELECT COUNT(*) FROM silver.fao_yield) + (SELECT COUNT(*) FROM silver.wb_rainfall)
     + (SELECT COUNT(*) FROM silver.wb_temperature) + (SELECT COUNT(*) FROM silver.fao_pesticides)
     + (SELECT COUNT(*) FROM silver.country) + (SELECT COUNT(*) FROM silver.country_alias),
     CONCAT((SELECT COUNT(*) FROM silver.reject_log), ' rows in silver.reject_log')
UNION ALL SELECT 'Gold', (SELECT COUNT(*) FROM gold.fact_crop_year),
     CONCAT((SELECT SUM(CAST(is_shock AS INT)) FROM gold.fact_crop_year), ' shocks in gold.fact_crop_year')
"@
foreach ($r in $counts.Rows) { Write-Ok ("{0,-7} {1,8:N0} rows   {2}" -f $r.layer, [int]$r.row_count, $r.note) }
$Summary["Database"] = "AgriPulse built and loaded"

# ---------------------------------------------------------------------------
Write-Step 5 "Data-quality checks (each must return no rows)"
$passed = 0
$checks = Get-QualityChecks
foreach ($check in $checks) {
    $rows = (Invoke-SqlQuery $check[1]).Rows.Count
    if ($rows -eq 0) { $passed++; Write-Ok ("PASS  " + $check[0]) }
    else { Write-Bad ("FAIL  " + $check[0] + "  ($rows bad rows)") }
}
$Summary["Quality checks"] = "$passed / $($checks.Count) passed"
if ($passed -ne $checks.Count) { Write-Note "Some checks failed: read the messages above before presenting." }

# ---------------------------------------------------------------------------
Write-Step 6 "Python for the notebooks (optional, not needed for the Gold evaluation)"
if ($SkipPython) {
    Write-Info "Skipped (-SkipPython)."
    $Summary["Python"] = "skipped"
} elseif (-not $IsWin) {
    Write-Info "Skipped (not Windows)."
    $Summary["Python"] = "skipped"
} else {
    $python = Find-Python
    if (-not $python) {
        Write-Note "Python 3 was not found."
        if (Confirm-Step "Install Python 3.12 now? Only needed to run the notebooks." $false) {
            [void](Install-Package "Python.Python.3.12" "Python 3.12" "https://www.python.org/downloads/")
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            $python = Find-Python
        }
    }
    if ($python) {
        Write-Ok "Python found: $(& $python --version)"
        if (Confirm-Step "Install the Python packages from requirements.txt (a few minutes)?" $false) {
            & $python -m pip install --disable-pip-version-check -r (Join-Path $ProjectRoot "requirements.txt")
            if ($LASTEXITCODE -eq 0) { Write-Ok "Python packages installed."; $Summary["Python"] = "ready" }
            else { Write-Note "pip reported a problem (see above)."; $Summary["Python"] = "pip problem" }
        } else { $Summary["Python"] = "found, packages not installed" }
    } else {
        $Summary["Python"] = "not installed (optional)"
    }
}

# ---------------------------------------------------------------------------
Write-Step 7 "Open everything for the presentation"
if ($NoOpen -or -not $IsWin) {
    Write-Info "Skipped."
    $Summary["Opened"] = "nothing"
} elseif (Confirm-Step "Open SSMS with the scripts, the three reports and the project folder now?") {
    $opened = @()
    if ($ssms) {
        $scriptPaths = @("01_bronze.sql", "02_silver.sql", "03_gold.sql", "demo_queries.sql") |
            ForEach-Object { Join-Path $SqlDir $_ }
        # SSMS 21 and later changed the command line: no -E (Windows authentication is the
        # default) and -C trusts the local server certificate. Each script is passed as its
        # own quoted argument: a comma-joined list is read as ONE file name and fails when the
        # project folder has spaces or non-English letters (e.g. a OneDrive Desktop folder).
        $ssmsMajor = 0
        if ($ssms -match 'Management Studio (\d+)') { $ssmsMajor = [int]$Matches[1] }
        $newSsms = ($ssmsMajor -ge 21) -or ($ssms -match '\\Release\\')
        $ssmsArgs = @($scriptPaths | ForEach-Object { '"' + $_ + '"' })
        $ssmsArgs += @("-S", ('"' + $script:ServerName + '"'), "-d", "AgriPulse")
        if ($newSsms) {
            $ssmsArgs += "-C"
            if ($SqlUser) { $ssmsArgs += @("-U", $SqlUser, "-A", "SqlPassword") }
        } else {
            $ssmsArgs += "-nosplash"
            if ($SqlUser) { $ssmsArgs += @("-U", $SqlUser) } else { $ssmsArgs += "-E" }
        }
        try { Start-Process -FilePath $ssms -ArgumentList $ssmsArgs; $opened += "SSMS" }
        catch { Write-Note "Could not start SSMS: $($_.Exception.Message)" }
    } else {
        # no SSMS found: open the scripts with whatever program Windows uses for .sql files
        foreach ($f in @("01_bronze.sql", "02_silver.sql", "03_gold.sql", "demo_queries.sql")) {
            $path = Join-Path $SqlDir $f
            try { Start-Process -FilePath $path; $opened += $f }
            catch {
                try { Start-Process notepad.exe -ArgumentList ('"' + $path + '"'); $opened += $f } catch { }
            }
        }
    }
    $docs = @("docs\bronze_report.docx", "docs\silver_report.docx", "docs\gold_report.docx",
              "docs\PROJECT_SPEC.md", "docs\data_source_register.csv")
    foreach ($d in $docs) {
        $path = Join-Path $ProjectRoot $d
        try { Start-Process -FilePath $path; $opened += (Split-Path -Leaf $path) }
        catch {
            try { Start-Process notepad.exe -ArgumentList ('"' + $path + '"'); $opened += (Split-Path -Leaf $path) }
            catch { Write-Note "Could not open $d" }
        }
    }
    try { Start-Process explorer.exe -ArgumentList ('"' + $ProjectRoot + '"'); $opened += "project folder" } catch { }
    Write-Ok ("Opened: " + ($opened -join ", "))
    if ($ssms) {
        Write-Info "In SSMS: open Databases > AgriPulse > Tables to show the bronze, silver and gold tables."
        Write-Info "If SSMS asks you to connect: Server name $($script:ServerName), Windows Authentication,"
        Write-Info "tick 'Trust server certificate', then Connect. If a script did not open: File > Open > File, folder sql."
    }
    else {
        Write-Info "Open SSMS from the Start menu. Server name: $($script:ServerName)   Authentication: Windows Authentication"
        Write-Info "Then: Databases > AgriPulse > Tables, and File > Open > File for the .sql scripts in the sql folder."
    }
    $Summary["Opened"] = ($opened -join ", ")
} else {
    $Summary["Opened"] = "nothing (you said no)"
}

$Summary["Result"] = "READY FOR THE PRESENTATION"
Write-Host ""
Write-Host "  Everything is ready." -ForegroundColor Green
Close-Setup 0
