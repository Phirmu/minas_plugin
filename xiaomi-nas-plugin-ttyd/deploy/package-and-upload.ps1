# ttyd 打包 & 上传到小米 NAS（Windows PowerShell）
# 用法：
#   .\package-and-upload.ps1 -NasIp <NAS_IP> -Uid <NAS_UID> -User root
#   .\package-and-upload.ps1 -OnlyPack
param(
    [string] $NasIp = "",
    [string] $Uid = "",
    [string] $User = "root",
    [switch] $OnlyPack
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PluginDir = Split-Path -Parent $Root
$WorkDir = Split-Path -Parent $PluginDir
$Zip = Join-Path $WorkDir "ttyd-plugin.zip"

Write-Host "==> 打包 $PluginDir" -ForegroundColor Cyan
if (Test-Path $Zip) { Remove-Item $Zip -Force }
python (Join-Path $WorkDir "deploy-plugins.py") --list >$null

if ($OnlyPack) {
    Write-Host "==> 仅打包完成，跳过上传" -ForegroundColor Green
    exit 0
}
if ([string]::IsNullOrWhiteSpace($NasIp) -or $Uid -notmatch '^\d+$') {
    throw "部署时请指定 -NasIp <NAS_IP> 和 -Uid <NAS_UID>"
}

python (Join-Path $WorkDir "deploy-plugins.py") --host $NasIp --uid $Uid --user $User --select ttyd
