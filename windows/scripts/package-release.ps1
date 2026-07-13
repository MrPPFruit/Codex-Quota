param([string]$Version = "0.2.0-preview.1")
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^0\.2\.0-preview\.[0-9]+$') { throw "非法 Windows Preview 版本: $Version" }
$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$release = Join-Path $repo "artifacts/windows-release"
$publish = Join-Path $repo "artifacts/windows-publish"
foreach ($path in @($release, $publish)) {
    if ((Test-Path $path) -and (Get-Item $path -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw "拒绝使用 reparse point 构建目录: $path" }
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $path -ItemType Directory | Out-Null
}
dotnet publish (Join-Path $repo "windows/src/CodexQuota.App/CodexQuota.App.csproj") --configuration Release --runtime win-x64 --self-contained true -p:PublishSingleFile=true -p:PublishTrimmed=false -p:DebugType=embedded -p:Version=$Version -p:InformationalVersion=$Version -p:IncludeSourceRevisionInInformationalVersion=false --output $publish
$exe = Join-Path $publish "CodexQuota.exe"
if (!(Test-Path $exe) -or (Get-Item $exe).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { throw "Windows executable 缺失或非法" }
$bytes = [IO.File]::ReadAllBytes($exe)
if ($bytes.Length -lt 512 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "不是有效 PE 文件" }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) { throw "Windows executable 不是 x64 PE" }
if ((Get-AuthenticodeSignature $exe).Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) { throw "预览包应保持明确未签名状态" }
$productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
if ($productVersion -ne $Version) { throw "二进制产品版本不一致: $productVersion" }
$notice = Join-Path $publish "README-Windows.txt"
@"
Codex Quota $Version for Windows 11 x64
完整解压到固定目录后运行 CodexQuota.exe。此 Preview 未使用商业代码签名证书，SmartScreen 可能显示警告。程序只在官方 Codex 运行时显示额度气泡，托盘菜单可隐藏、关闭登录启动或退出。
"@ | Set-Content $notice -Encoding UTF8
$archiveName = "Codex-Quota-v$Version-windows-x64.zip"
$archive = Join-Path $release $archiveName
Compress-Archive -Path (Join-Path $publish "*") -DestinationPath $archive -CompressionLevel Optimal
$verification = Join-Path $release "verify"
Expand-Archive $archive $verification
if (!(Test-Path (Join-Path $verification "CodexQuota.exe"))) { throw "归档结构校验失败" }
Remove-Item $verification -Recurse -Force
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = "$archive.sha256"
[IO.File]::WriteAllText($checksum, "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
$checksumBytes = [IO.File]::ReadAllBytes($checksum)
if ($checksumBytes -contains 0x0d) { throw "SHA-256 文件必须使用 LF 行尾" }
Write-Output $archive
Write-Output $checksum
