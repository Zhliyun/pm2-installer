# PM2 Offline Installation Script
# Usage: .\install.ps1 [tgz_directory] [parallel_jobs] [-Debug]

param(
    [string]$TgzDir = "packages",
    [int]$ParallelJobs = 0,  # 0 means auto-detect
    [switch]$Debug
)

# Show help information
function Show-Help {
    Write-Host "PM2 Offline Parallel Installation Script" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\install.ps1 [tgz_directory] [parallel_jobs] [-Debug]" -ForegroundColor White
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  tgz_directory   Directory path containing all tgz files (default: 'packages')" -ForegroundColor White
    Write-Host "  parallel_jobs   Maximum number of parallel installation jobs (default: half of CPU cores, min 2, max 8)" -ForegroundColor White
    Write-Host "  -Debug          Enable debug mode to show detailed error information" -ForegroundColor White
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\install.ps1                    # Use packages directory, auto-detect parallel jobs" -ForegroundColor White
    Write-Host "  .\install.ps1 .\packages          # Use .\packages directory, auto-detect parallel jobs" -ForegroundColor White
    Write-Host "  .\install.ps1 .\packages 4        # Use .\packages directory, 4 parallel jobs" -ForegroundColor White
    Write-Host "  .\install.ps1 C:\tgz 6 -Debug    # Use specified path, 6 parallel jobs, enable debug" -ForegroundColor White
    Write-Host ""
}

# Process command line arguments
if ($args -contains "-h" -or $args -contains "--help" -or $args -contains "/?") {
    Show-Help
    exit 0
}

# Auto-detect parallel jobs
if ($ParallelJobs -eq 0) {
    $cpuCount = [System.Environment]::ProcessorCount
    $ParallelJobs = [Math]::Max(2, [Math]::Min(8, [Math]::Floor($cpuCount / 2)))
}

# Color output functions
function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Debug {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message" -ForegroundColor Gray
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PM2 Offline Installation Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($Debug) {
    Write-Host "Debug mode enabled" -ForegroundColor Yellow
    Write-Host ""
}

Write-Info "TGZ file directory: $TgzDir"
Write-Info "Maximum parallel jobs: $ParallelJobs"
Write-Host ""

# Check npm
Write-Info "Checking npm environment..."
try {
    $npmVersion = npm --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "npm not found"
    }
    Write-Info "npm version: $npmVersion"
} catch {
    Write-Error "npm not found, please install Node.js first"
    Write-Error "Download: https://nodejs.org/"
    exit 1
}

# Try to kill existing PM2 daemon processes
Write-Info "Checking and cleaning existing PM2 daemon processes..."
try {
    $pm2Output = pm2 --version 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Found existing PM2 installation, executing pm2 kill..."
        pm2 kill 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "PM2 daemon processes cleaned"
        } else {
            Write-Warn "Problem occurred while cleaning PM2 daemon processes, continuing installation..."
        }
        # Wait for a while to ensure processes exit completely
        Start-Sleep -Seconds 2
    } else {
        Write-Info "No existing PM2 installation found"
    }
} catch {
    Write-Info "No existing PM2 installation found"
}

# Check directory
Write-Info "Checking tgz file directory: $TgzDir"
if (-not (Test-Path $TgzDir)) {
    Write-Error "Directory does not exist: $TgzDir"
    exit 1
}

# Count tgz files
$tgzFiles = Get-ChildItem -Path $TgzDir -Filter "*.tgz" -File
if ($tgzFiles.Count -eq 0) {
    Write-Error "No .tgz files found in directory $TgzDir"
    exit 1
}

Write-Info "Found $($tgzFiles.Count) .tgz files"

# Parse package.json to get dependency relationships
function Parse-Dependencies {
    param([string]$TgzFile)
    
    $extractDir = Join-Path $localTempDir ([System.IO.Path]::GetFileNameWithoutExtension($TgzFile))
    
    try {
        # Extract to temporary directory
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        
        # Use 7zip or tar to extract
        $extractSuccess = $false
        if (Get-Command "7z" -ErrorAction SilentlyContinue) {
            $result = & 7z x $TgzFile -o"$extractDir" -y 2>$null
            if ($LASTEXITCODE -eq 0) { $extractSuccess = $true }
        } elseif (Get-Command "tar" -ErrorAction SilentlyContinue) {
            $result = & tar -xzf $TgzFile -C $extractDir --strip-components=1 2>$null
            if ($LASTEXITCODE -eq 0) { $extractSuccess = $true }
        }
        
        if (-not $extractSuccess) {
            Write-Debug "Extraction failed: $TgzFile"
            return "unknown" + "|" + $TgzFile
        }
        
        # Read package.json
        $packageJsonPath = Join-Path $extractDir "package.json"
        if (Test-Path $packageJsonPath) {
            try {
                $packageJson = Get-Content $packageJsonPath -Raw | ConvertFrom-Json
                $name = $packageJson.name
                $version = $packageJson.version
                
                if ($name -and $version) {
                    return "$name@$version" + "|" + $TgzFile
                } else {
                    return "unknown" + "|" + $TgzFile
                }
            } catch {
                Write-Debug "Failed to parse package.json: $TgzFile"
                return "unknown" + "|" + $TgzFile
            }
        } else {
            return "unknown" + "|" + $TgzFile
        }
    } finally {
        # Clean up temporary extraction directory
        if (Test-Path $extractDir) {
            Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Group packages by dependency order
function Categorize-Packages {
    param([string[]]$TgzFiles)
    
    Write-Info "Analyzing package dependencies..."
    
    $coreDeps = @()      # Core base dependencies, install first
    $regularDeps = @()   # Regular dependencies, can install in parallel
    $pm2Core = @()       # PM2 core packages, install after dependencies
    $pm2Main = ""        # PM2 main package, install last
    
    foreach ($file in $TgzFiles) {
        $info = Parse-Dependencies $file
        $pkgName = $info.Split('|')[0]
        $filePath = $info.Split('|')[1]
        
        if (Test-Path $filePath) {
            switch -Wildcard ($pkgName) {
                # Core base dependencies, need to install first
                "async@*" { $coreDeps += $filePath; break }
                "debug@*" { $coreDeps += $filePath; break }
                "semver@*" { $coreDeps += $filePath; break }
                "commander@*" { $coreDeps += $filePath; break }
                "eventemitter2@*" { $coreDeps += $filePath; break }
                "js-yaml@*" { $coreDeps += $filePath; break }
                # PM2 main package - match pm2@ or filename contains pm2- and is main package
                "pm2@*" { $pm2Main = $filePath; break }
                # PM2 related core packages and main package
                "*pm2-*" { 
                    # If it's a pure pm2- prefixed package (main package), set as main package
                    if ($pkgName -match "^pm2-[\d\.]+$") {
                        $pm2Main = $filePath
                    } else {
                        $pm2Core += $filePath
                    }
                    break 
                }
                "*@pm2*" { $pm2Core += $filePath; break }
                # Other regular dependencies
                default { $regularDeps += $filePath; break }
            }
        }
    }
    
    return @{
        CoreDeps = $coreDeps
        RegularDeps = $regularDeps
        Pm2Core = $pm2Core
        Pm2Main = $pm2Main
    }
}

# Install package groups in parallel
function Install-ParallelGroup {
    param(
        [string[]]$Packages,
        [string]$GroupName
    )
    
    if ($Packages.Count -eq 0) {
        return 0
    }
    
    Write-Info "$GroupName (Installing $($Packages.Count) packages in parallel, max parallel jobs: $ParallelJobs)..."
    
    $jobs = New-Object System.Collections.ArrayList
    $results = New-Object System.Collections.ArrayList
    $jobCount = 0
    
    foreach ($packageFile in $Packages) {
        # Wait until current job count is less than maximum parallel jobs
        while ($jobs.Count -ge $ParallelJobs) {
            $completedJobs = New-Object System.Collections.ArrayList
            foreach ($job in $jobs) {
                if ($job.State -eq "Completed" -or $job.State -eq "Failed") {
                    [void]$completedJobs.Add($job)
                }
            }
            
            # Remove completed jobs
            foreach ($completedJob in $completedJobs) {
                [void]$jobs.Remove($completedJob)
                $result = Receive-Job $completedJob
                [void]$results.Add($result)
                Remove-Job $completedJob
            }
            
            if ($jobs.Count -ge $ParallelJobs) {
                Start-Sleep -Milliseconds 100
            }
        }
        
        # Start new installation job
        $job = Start-Job -ScriptBlock {
            param($PkgFile, $DebugMode)
            
            $pkgName = [System.IO.Path]::GetFileNameWithoutExtension($PkgFile)
            $result = @{
                PackageName = $pkgName
                PackageFile = $PkgFile
                Status = "FAILED"
                Message = ""
            }
            
            try {
                # Try normal installation
                $output = npm install -g $PkgFile --no-audit --no-fund --silent 2>&1
                $exitCode = $LASTEXITCODE
                
                if ($exitCode -eq 0) {
                    $result.Status = "SUCCESS"
                    $result.Message = "Installation successful"
                } else {
                    # Try force installation
                    $output = npm install -g $PkgFile --force --no-audit --no-fund --silent 2>&1
                    $exitCode = $LASTEXITCODE
                    
                    if ($exitCode -eq 0) {
                        $result.Status = "SUCCESS_FORCE"
                        $result.Message = "Force installation successful"
                    } else {
                        $result.Status = "FAILED"
                        $result.Message = "Installation failed: $output"
                    }
                }
            } catch {
                $result.Status = "FAILED"
                $result.Message = "Installation exception: $($_.Exception.Message)"
            }
            
            return $result
        } -ArgumentList $packageFile, $Debug
        
        [void]$jobs.Add($job)
        $jobCount++
        Write-Debug "Started installation job #$jobCount`: $([System.IO.Path]::GetFileNameWithoutExtension($packageFile)) (Job ID: $($job.Id))"
    }
    
    # Wait for all jobs to complete
    Write-Info "Waiting for all installation jobs to complete..."
    $jobs | Wait-Job | Out-Null
    
    # Collect results
    foreach ($job in $jobs) {
        $result = Receive-Job $job
        [void]$results.Add($result)
        Remove-Job $job
    }
    
    # Calculate statistics
    $success = 0
    $failed = 0
    $forceSuccess = 0
    
    foreach ($result in $results) {
        switch ($result.Status) {
            "SUCCESS" {
                Write-Host "$($result.PackageName)" -ForegroundColor Green
                $success++
            }
            "SUCCESS_FORCE" {
                Write-Host "$($result.PackageName) (force install)" -ForegroundColor Yellow
                $forceSuccess++
            }
            "FAILED" {
                Write-Host "$($result.PackageName)" -ForegroundColor Red
                if ($Debug -and $result.Message) {
                    Write-Debug "Error: $($result.Message)"
                }
                $failed++
            }
        }
    }
    
    $totalSuccess = $success + $forceSuccess
    Write-Info "Group installation result: $totalSuccess successful (normal: $success, force: $forceSuccess), $failed failed"
    
    return $failed
}

# Install single package (for PM2 main package)
function Install-SinglePackage {
    param([string]$TgzFile)
    
    $pkgName = [System.IO.Path]::GetFileNameWithoutExtension($TgzFile)
    Write-Info "Installing PM2 main package: $pkgName"
    
    try {
        $output = npm install -g $TgzFile --no-audit --no-fund --silent 2>&1
        $exitCode = $LASTEXITCODE
        
        if ($exitCode -eq 0) {
            Write-Info "Installation successful: $pkgName"
            return 0
        } else {
            Write-Warn "Trying force installation: $pkgName"
            $output = npm install -g $TgzFile --force --no-audit --no-fund --silent 2>&1
            $exitCode = $LASTEXITCODE
            
            if ($exitCode -eq 0) {
                Write-Info "Force installation successful: $pkgName"
                return 0
            } else {
                Write-Error "Installation failed: $pkgName"
                if ($Debug -and $output) {
                    Write-Debug "Error message: $output"
                }
                return 1
            }
        }
    } catch {
        Write-Error "Installation exception: $pkgName - $($_.Exception.Message)"
        return 1
    }
}

# Create local temporary directory
$localTempDir = Join-Path $env:TEMP "pm2_install_$(Get-Random)"
Write-Info "Creating local temporary directory: $localTempDir"

try {
    New-Item -ItemType Directory -Path $localTempDir -Force | Out-Null
    
    # Copy all tgz files to local directory
    Write-Info "Copying tgz files to local directory..."
    $localTgzFiles = @()
    
    foreach ($file in $tgzFiles) {
        $localFile = Join-Path $localTempDir $file.Name
        Copy-Item $file.FullName $localFile -Force
        $localTgzFiles += $localFile
        Write-Debug "Copying: $($file.Name) -> $localFile"
    }
    
    Write-Info "Copy completed, starting dependency analysis..."
    Write-Host ""
    
    # Analyze package dependencies and group them
    $categorization = Categorize-Packages $localTgzFiles
    
    $totalFailures = 0
    
    # Stage 1: Install core dependencies
    if ($categorization.CoreDeps.Count -gt 0) {
        $failures = Install-ParallelGroup $categorization.CoreDeps "Stage 1/4: Installing core base dependencies"
        $totalFailures += $failures
    }
    
    # Stage 2: Install regular dependencies in parallel
    if ($categorization.RegularDeps.Count -gt 0) {
        $failures = Install-ParallelGroup $categorization.RegularDeps "Stage 2/4: Installing regular dependencies in parallel"
        $totalFailures += $failures
    }
    
    # Stage 3: Install PM2 core packages
    if ($categorization.Pm2Core.Count -gt 0) {
        $failures = Install-ParallelGroup $categorization.Pm2Core "Stage 3/4: Installing PM2 core packages"
        $totalFailures += $failures
    }
    
    # Stage 4: Install PM2 main package (if separate main package found)
    if ($categorization.Pm2Main -and (Test-Path $categorization.Pm2Main)) {
        Write-Info "Stage 4/4: Installing PM2 main package"
        $failures = Install-SinglePackage $categorization.Pm2Main
        $totalFailures += $failures
    } else {
        Write-Info "PM2 main package already installed as dependency package, skipping separate installation step"
    }
    
    # Installation results
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Installation Results" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($totalFailures -eq 0) {
        Write-Info "All packages installed successfully!"
    } else {
        Write-Warn "$totalFailures packages failed to install"
    }
    Write-Host ""
    
    # Verify PM2
    Write-Info "Verifying PM2 installation..."
    Start-Sleep -Seconds 3
    
    try {
        $pm2Version = pm2 --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "PM2 installed successfully, version: $pm2Version"
            
            # Test PM2 functionality
            $testResult = pm2 list 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Info "PM2 functionality is normal"
            } else {
                Write-Warn "PM2 is installed but may have issues"
            }
        } else {
            throw "PM2 command not found"
        }
    } catch {
        Write-Warn "PM2 command not found in PATH"
        
        # Find npm global directory
        try {
            $npmGlobal = npm root -g 2>$null
            if ($LASTEXITCODE -eq 0) {
                $pm2Cmd = Join-Path (Split-Path $npmGlobal -Parent) "bin\pm2.cmd"
                if (Test-Path $pm2Cmd) {
                    Write-Info "PM2 installed at: $pm2Cmd"
                    Write-Info "Recommend adding the following path to system PATH environment variable:"
                    Write-Host "  $(Split-Path $pm2Cmd -Parent)" -ForegroundColor Yellow
                } else {
                    Write-Error "PM2 installation may have failed"
                }
            }
        } catch {
            Write-Error "Cannot find PM2 installation location"
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Installation Complete" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Final judgment: if PM2 works normally, consider installation successful, even if some packages failed
    $pm2Working = $false
    try {
        $pm2Test = pm2 --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            $pm2Working = $true
        }
    } catch {
        $pm2Working = $false
    }
    
    if ($pm2Working) {
        Write-Info "PM2 offline installation completed!"
        Write-Host ""
        Write-Host "You can test PM2 using the following commands:" -ForegroundColor Green
        Write-Host "  pm2 --version" -ForegroundColor White
        Write-Host "  pm2 list" -ForegroundColor White
        Write-Host ""
        if ($totalFailures -gt 0) {
            Write-Warn "Note: $totalFailures dependency packages failed to install, but PM2 main functionality is normal"
        }
    } else {
        Write-Error "PM2 installation failed"
        Write-Host ""
        Write-Host "If installation fails, you can try the following methods:" -ForegroundColor Yellow
        Write-Host "1. Use debug mode to view detailed error information:" -ForegroundColor White
        Write-Host "   .\install.ps1 -Debug" -ForegroundColor Gray
        Write-Host ""
        Write-Host "2. Check npm global installation permissions:" -ForegroundColor White
        Write-Host "   npm config get prefix" -ForegroundColor Gray
        Write-Host ""
        Write-Host "3. Run PowerShell as administrator" -ForegroundColor White
        Write-Host ""
    }
    
} finally {
    # Clean up temporary directory
    Write-Info "Cleaning up temporary files..."
    if (Test-Path $localTempDir) {
        Remove-Item -Path $localTempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Debug "Deleted temporary directory: $localTempDir"
    }
}
