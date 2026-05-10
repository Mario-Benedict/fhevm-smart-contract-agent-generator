# Compile every .sol file individually to avoid solc bad_alloc on large batches.
# Reports only real Solidity errors (not warnings).

npx hardhat clean

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$generatedDir = Join-Path $projectRoot "contracts\final"
$tempDir = Join-Path $projectRoot "contracts\_temp_single"

# Collect all .sol files recursively under final (skip _temp_single)
$allFiles = Get-ChildItem -Path $generatedDir -Filter "*.sol" -Recurse -File |
    Where-Object { $_.FullName -notlike "*_temp_single*" } |
    Sort-Object FullName

$total    = $allFiles.Count
$passed   = 0
$failed   = 0
$failList = @()

Write-Host "Compiling $total files one at a time..."
Write-Host ""

foreach ($file in $allFiles) {
    # Put just this file in the temp source folder
    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Copy-Item $file.FullName $tempDir

    $env:BATCH = "_temp_single"
    $env:NODE_OPTIONS = "--max-old-space-size=4096"

    $result    = npx hardhat compile 2>&1
    $resultStr = $result -join "`n"

    $hasError = $resultStr -match 'HH600|YulException|ParserError|DeclarationError|SyntaxError|TypeError'

    if ($hasError) {
        $failed++
        $failList += $file.Name
        Write-Host "FAIL  $($file.Name)"
        $result | Where-Object { $_ -match 'HH600|YulException|ParserError|DeclarationError|SyntaxError|TypeError|-->' } |
            Select-Object -First 15 | ForEach-Object { Write-Host "      $_" }
    } else {
        $passed++
        $compiledFolder = Join-Path $projectRoot "artifacts\contracts\_temp_single\$($file.Name)"

        if (-not (Test-Path (Join-Path $projectRoot "output\contracts"))) {
            New-Item -ItemType Directory -Path (Join-Path $projectRoot "output\contracts") -Force | Out-Null
        }

        if (Test-Path $compiledFolder) {
            $destinationPath = Join-Path $projectRoot "output\contracts\$($file.Name)"
            Move-Item -Path $compiledFolder -Destination $destinationPath -Force
        }
        Write-Host "ok    $($file.Name)"
    }
}

# Cleanup temp folder
if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
if (Test-Path (Join-Path $projectRoot "artifacts\contracts\_temp_single")) { Remove-Item -Path (Join-Path $projectRoot "artifacts\contracts\_temp_single") -Recurse -Force }

Write-Host ""
Write-Host "=============================="
Write-Host "Results: $passed OK, $failed FAILED out of $total"
if ($failList.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed files:"
    $failList | ForEach-Object { Write-Host "  - $_" }
}
Write-Host "=============================="
