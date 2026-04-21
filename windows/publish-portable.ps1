Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$windowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $windowsRoot
$appProject = Join-Path $windowsRoot "src\Link2Download.Windows.App\Link2Download.Windows.App.csproj"
$publishDir = Join-Path $windowsRoot "dist\Link2Download-Windows-Portable"
$zipPath = Join-Path $windowsRoot "dist\Link2Download-Windows-Portable.zip"
$readmePath = Join-Path $publishDir "README-PORTABLE.txt"

if (Test-Path $publishDir) {
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}

New-Item -ItemType Directory -Path $publishDir | Out-Null

dotnet publish $appProject `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:EnableCompressionInSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:EmbedPortableRuntime=true `
    -o $publishDir

@"
Link2Download for Windows - portable package

How to run:
1. Unzip the whole archive to any folder.
2. Run Link2Download.exe.

Portable behavior:
- No .cmd launcher is required.
- yt-dlp, ffmpeg, and ffprobe are bundled into the exe.
- deno.exe is bundled too when it is present in windows/runtime/win-x64.
- On first start, the app extracts the runtime tools to:
  %LocalAppData%\Link2Download\runtime\win-x64

User data is stored here:
- %AppData%\Link2Download\settings.json
- %AppData%\Link2Download\history.json
- %LocalAppData%\Link2Download\logs\app.log
"@ | Set-Content -LiteralPath $readmePath -Encoding UTF8

if (Test-Path $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Compress-Archive -Path (Join-Path $publishDir "*") -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Portable build ready:"
Write-Host "  Folder: $publishDir"
Write-Host "  Zip:    $zipPath"
