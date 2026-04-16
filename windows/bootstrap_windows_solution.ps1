param(
    [string]$SolutionName = "Link2Download.Windows",
    [string]$Framework = "net8.0"
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function New-ProjectIfMissing {
    param(
        [string]$Template,
        [string]$Name,
        [string]$OutputDirectory,
        [string[]]$ExtraArgs = @()
    )

    $projectFile = Join-Path $OutputDirectory "$Name.csproj"
    if (Test-Path $projectFile) {
        Write-Host "Project already exists: $projectFile"
        return
    }

    $args = @("new", $Template, "-n", $Name, "-o", $OutputDirectory, "-f", $Framework) + $ExtraArgs
    & dotnet @args
}

function Add-ProjectToSolutionIfMissing {
    param(
        [string]$SolutionFile,
        [string]$ProjectFile
    )

    $solutionContent = Get-Content $SolutionFile -Raw
    $projectName = [System.IO.Path]::GetFileName($ProjectFile)

    if ($solutionContent -like "*$projectName*") {
        Write-Host "Project already added to solution: $projectName"
        return
    }

    & dotnet sln $SolutionFile add $ProjectFile
}

function Add-ProjectReferenceIfMissing {
    param(
        [string]$ProjectFile,
        [string]$ReferenceFile
    )

    $projectContent = Get-Content $ProjectFile -Raw
    $referenceName = [System.IO.Path]::GetFileName($ReferenceFile)

    if ($projectContent -like "*$referenceName*") {
        Write-Host "Reference already exists in project: $referenceName"
        return
    }

    & dotnet add $ProjectFile reference $ReferenceFile
}

$windowsRoot = $PSScriptRoot
$srcRoot = Join-Path $windowsRoot "src"
$testsRoot = Join-Path $windowsRoot "tests"
$runtimeRoot = Join-Path (Join-Path $windowsRoot "runtime") "win-x64"
$solutionFile = Join-Path $windowsRoot "$SolutionName.sln"

$appName = "Link2Download.Windows.App"
$coreName = "Link2Download.Windows.Core"
$infrastructureName = "Link2Download.Windows.Infrastructure"
$testsName = "Link2Download.Windows.Tests"

$appDir = Join-Path $srcRoot $appName
$coreDir = Join-Path $srcRoot $coreName
$infrastructureDir = Join-Path $srcRoot $infrastructureName
$testsDir = Join-Path $testsRoot $testsName

Require-Command -Name "dotnet"

New-Item -ItemType Directory -Force -Path $srcRoot, $testsRoot, $runtimeRoot | Out-Null

if (-not (Test-Path $solutionFile)) {
    & dotnet new sln -n $SolutionName -o $windowsRoot
}
else {
    Write-Host "Solution already exists: $solutionFile"
}

New-ProjectIfMissing -Template "wpf" -Name $appName -OutputDirectory $appDir
New-ProjectIfMissing -Template "classlib" -Name $coreName -OutputDirectory $coreDir
New-ProjectIfMissing -Template "classlib" -Name $infrastructureName -OutputDirectory $infrastructureDir
New-ProjectIfMissing -Template "xunit" -Name $testsName -OutputDirectory $testsDir

$projects = @(
    (Join-Path $appDir "$appName.csproj"),
    (Join-Path $coreDir "$coreName.csproj"),
    (Join-Path $infrastructureDir "$infrastructureName.csproj"),
    (Join-Path $testsDir "$testsName.csproj")
)

foreach ($project in $projects) {
    Add-ProjectToSolutionIfMissing -SolutionFile $solutionFile -ProjectFile $project
}

$appProjectFile = Join-Path $appDir "$appName.csproj"
$coreProjectFile = Join-Path $coreDir "$coreName.csproj"
$infrastructureProjectFile = Join-Path $infrastructureDir "$infrastructureName.csproj"
$testsProjectFile = Join-Path $testsDir "$testsName.csproj"

Add-ProjectReferenceIfMissing -ProjectFile $appProjectFile -ReferenceFile $coreProjectFile
Add-ProjectReferenceIfMissing -ProjectFile $appProjectFile -ReferenceFile $infrastructureProjectFile
Add-ProjectReferenceIfMissing -ProjectFile $infrastructureProjectFile -ReferenceFile $coreProjectFile
Add-ProjectReferenceIfMissing -ProjectFile $testsProjectFile -ReferenceFile $coreProjectFile
Add-ProjectReferenceIfMissing -ProjectFile $testsProjectFile -ReferenceFile $infrastructureProjectFile

Write-Host ""
Write-Host "Windows solution bootstrap complete."
Write-Host "Solution: $solutionFile"
Write-Host "Runtime tools directory: $runtimeRoot"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Place yt-dlp.exe, ffmpeg.exe, and ffprobe.exe into windows/runtime/win-x64/"
Write-Host "  2. Open the solution in Visual Studio or VS Code"
Write-Host "  3. Start porting models, settings, persistence, and yt-dlp integration"
