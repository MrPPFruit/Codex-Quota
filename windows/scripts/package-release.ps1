param(
    [string]$Version = "0.1.0",
    [switch]$NoRestore
)
$ErrorActionPreference = "Stop"

if ($Version -ne "0.1.0") {
    throw "Windows assets must use the unified public release version: 0.1.0"
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$project = Join-Path $repo "windows/src/CodexQuota.App/CodexQuota.App.csproj"
$release = Join-Path $repo "artifacts/windows-release"
$publish = Join-Path $repo "artifacts/windows-publish"
foreach ($path in @($release, $publish)) {
    if ((Test-Path $path) -and (Get-Item $path -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        throw "Refusing reparse-point build directory: $path"
    }
    Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $path -ItemType Directory | Out-Null
}

if (!$NoRestore) {
    dotnet restore $project --runtime win-x64
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet restore failed with exit code $LASTEXITCODE"
    }
}

dotnet publish $project `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --no-restore `
    -p:PublishSingleFile=true `
    -p:PublishTrimmed=false `
    -p:DebugType=embedded `
    -p:Version=$Version `
    -p:InformationalVersion=$Version `
    -p:IncludeSourceRevisionInInformationalVersion=false `
    --output $publish
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

$exe = Join-Path $publish "CodexQuota.exe"
if (!(Test-Path $exe) -or (Get-Item $exe).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
    throw "Windows executable is missing or invalid"
}

$bytes = [IO.File]::ReadAllBytes($exe)
if ($bytes.Length -lt 512 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw "Output is not a valid PE file"
}
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) {
    throw "Windows executable is not an x64 PE"
}
if ((Get-AuthenticodeSignature $exe).Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
    throw "Preview executable must remain explicitly unsigned"
}
$productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
if ($productVersion -ne $Version) {
    throw "Binary product version mismatch: $productVersion"
}

$notice = Join-Path $publish "README-Windows.txt"
$noticeTemplate = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
    "Q29kZXggUXVvdGEgezB9IFdpbmRvd3MgMTEgeDY0IOeJiOacrAror7flhYjlrozmlbTop6PljovliLDlm7rlrprnm67lvZXvvIzlho3ov5DooYwgQ29kZXhRdW90YS5leGXjgILmnKwgUHJldmlldyDlsJrmnKrkvb/nlKggQXV0aGVudGljb2RlIOS7o+eggeetvuWQjeivgeS5pu+8jFNtYXJ0U2NyZWVuIOWPr+iDveWPkeWHuuitpuWRiuOAguS7heW9k+WMheWQqyBDb2RleCDnmoTlrpjmlrkgQ2hhdEdQVCDmoYzpnaLlupTnlKjmraPlnKjov5DooYzml7bvvIzpop3luqbmsJTms6HmiY3kvJrmmL7npLrjgILlj6/kvb/nlKjmiZjnm5joj5zljZXmmL7npLrmiJbpmpDol4/msJTms6HjgIHlhbPpl63nmbvlvZXlkK/liqjmiJbpgIDlh7rnqIvluo/jgIIK"))
$noticeText = [string]::Format($noticeTemplate, $Version)
[IO.File]::WriteAllText($notice, $noticeText, [Text.UTF8Encoding]::new($false))

$archiveName = "Codex-Quota-v$Version-windows-x64.zip"
$archive = Join-Path $release $archiveName
Compress-Archive -Path (Join-Path $publish "*") -DestinationPath $archive -CompressionLevel Optimal
$verification = Join-Path $release "verify"
Expand-Archive $archive $verification
if (!(Test-Path (Join-Path $verification "CodexQuota.exe"))) {
    throw "Archive structure verification failed"
}
Remove-Item $verification -Recurse -Force

$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = "$archive.sha256"
[IO.File]::WriteAllText($checksum, "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
$checksumBytes = [IO.File]::ReadAllBytes($checksum)
if ($checksumBytes -contains 0x0d) {
    throw "SHA-256 file must use LF line endings"
}

Write-Output $archive
Write-Output $checksum
