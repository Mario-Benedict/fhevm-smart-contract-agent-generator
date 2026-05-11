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
        
        # Setup folder output utama
        $outContractsDir = Join-Path $projectRoot "output\contracts"
        if (-not (Test-Path $outContractsDir)) { New-Item -ItemType Directory -Path $outContractsDir -Force | Out-Null }

        if (Test-Path $compiledFolder) {
            # ========================================================
            # TAHAP 1: BACA & SIMPAN JALUR BUILD-INFO DULU
            # ========================================================
            $dbgFiles = Get-ChildItem -Path $compiledFolder -Filter "*.dbg.json" -File -Recurse
            $buildInfosToCopy = @()
            
            foreach ($dbg in $dbgFiles) {
                try {
                    $jsonContent = Get-Content -Raw -Path $dbg.FullName | ConvertFrom-Json
                    $buildInfoRelPath = $jsonContent.buildInfo
                    
                    # Resolve jalur relatif menjadi absolut
                    $resolvedBuildInfo = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($dbg.DirectoryName, $buildInfoRelPath))

                    if (Test-Path $resolvedBuildInfo) {
                        $contractName = $dbg.Name.Replace(".dbg.json", "")
                        # Simpan data sementara ke array
                        $buildInfosToCopy += [PSCustomObject]@{
                            SourcePath = $resolvedBuildInfo
                            TargetName = "${contractName}_build-info.json"
                        }
                    }
                } catch {
                    Write-Host "WARN: Gagal mengekstrak build-info untuk $($dbg.Name)" -ForegroundColor Yellow
                }
            }

            # ========================================================
            # TAHAP 2: PINDAHKAN FOLDER ARTIFACT UTAMA
            # ========================================================
            $destinationPath = Join-Path $outContractsDir "$($file.Name)"
            
            # Hapus folder tujuan jika sudah ada (mencegah bug folder masuk ke dalam folder)
            if (Test-Path $destinationPath) { Remove-Item -Path $destinationPath -Recurse -Force }
            Move-Item -Path $compiledFolder -Destination $destinationPath -Force

            # ========================================================
            # TAHAP 3: COPY BUILD-INFO KE DALAM FOLDER YANG BARU DIPINDAH
            # ========================================================
            if ($buildInfosToCopy.Count -gt 0) {
                # Buat sub-folder 'build-info' di dalam output/contracts/File.sol/
                $targetBuildInfoDir = Join-Path $destinationPath "build-info"
                New-Item -ItemType Directory -Path $targetBuildInfoDir -Force | Out-Null

                foreach ($info in $buildInfosToCopy) {
                    $targetFile = Join-Path $targetBuildInfoDir $info.TargetName
                    Copy-Item -Path $info.SourcePath -Destination $targetFile -Force
                }
            }
        }
        Write-Host "ok    $($file.Name)"
    }

    # Bersihkan artifacts tambahan (biar build-info nggak numpuk di cache Hardhat)
    $buildInfoTemp = Join-Path $projectRoot "artifacts\build-info"
    if (Test-Path $buildInfoTemp) { Remove-Item -Path $buildInfoTemp -Recurse -Force }
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