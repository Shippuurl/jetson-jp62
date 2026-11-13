param([string]$Port, [int]$Seconds = 60, [string]$InputLog)
$ErrorActionPreference = 'Stop'
$base = 'https://raw.githubusercontent.com/Shippuurl/jetson-jp62/main'
$cache = Join-Path $env:LOCALAPPDATA 'Jetson-UART'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$python = Join-Path $cache 'venv\Scripts\python.exe'
if (!(Test-Path $python)) {
    if (Get-Command py -ErrorAction SilentlyContinue) { & py -3 -m venv (Join-Path $cache 'venv') }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { & python -m venv (Join-Path $cache 'venv') }
    else { throw 'Install Python 3 from python.org, then rerun this command.' }
    if ($LASTEXITCODE -ne 0) { throw 'Python virtual environment creation failed.' }
}
& $python -m pip --quiet install pyserial==3.5
if ($LASTEXITCODE -ne 0) { throw 'pyserial installation failed.' }
$script = Join-Path $cache 'uart-logs.py'
Invoke-WebRequest "$base/uart-logs.py" -OutFile "$script.tmp" -UseBasicParsing
Move-Item -Force "$script.tmp" $script
$params = @($script, '--seconds', "$Seconds")
if ($Port) { $params += @('--port', $Port) }
if ($InputLog) { $params += @('--input', $InputLog) }
& $python @params
if ($LASTEXITCODE -ne 0) { throw 'Capture ended with an error; inspect the local summary and ZIP files.' }
