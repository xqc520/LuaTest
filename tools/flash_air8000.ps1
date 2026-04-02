param(
    [string]$Port = "COM6",
    [string]$CfgPath = (Join-Path $PSScriptRoot "flash_air8000_pkg.ini"),
    [string]$ToolDir = "D:\Luatools\_temp\ec_download"
)

$flashTool = Join-Path $ToolDir "FlashToolCLI.exe"

if (-not (Test-Path $flashTool)) {
    throw "Flash tool not found: $flashTool"
}

if (-not (Test-Path $CfgPath)) {
    throw "Flash config not found: $CfgPath"
}

& $flashTool --cfgfile $CfgPath --port $Port burn
exit $LASTEXITCODE
