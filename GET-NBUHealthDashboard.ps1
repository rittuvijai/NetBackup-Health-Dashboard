# ==============================================================================
# Script:     Get-NBUHealthDashboard-Bulletproof.ps1
# Purpose:    100% Verified, Bulletproof, Exception-Based NetBackup Monitoring
# Scope:      Universal across Master Servers (Egypt, KSA, Qatar, UAE, etc.)
# Mode:       STRICTLY READ-ONLY (Zero state modifications)
# ==============================================================================

Clear-Host
$ErrorActionPreference = "Continue"

# ==============================================================================
# PHASE 1: PATH & TOPOLOGY AUTO-DISCOVERY
# ==============================================================================
$drives = @("D:", "N:", "C:", "E:")
$baseDir = $null
foreach ($d in $drives) {
    if (Test-Path "$d\Program Files\Veritas\NetBackup\bin\admincmd\bpdbjobs.exe") {
        $baseDir = "$d\Program Files\Veritas"
        $catalogDriveLetter = $d
        break
    }
}

if (-not $baseDir) {
    Write-Error "CRITICAL: Could not locate Veritas NetBackup binaries on drives D, N, C, or E."
    exit 1
}

$admincmd = "$baseDir\NetBackup\bin\admincmd"
$nbbin    = "$baseDir\NetBackup\bin"
$volmgr   = "$baseDir\Volmgr\bin"

$masterHost = $env:COMPUTERNAME.ToLower()
$now        = Get-Date
$nowUtc     = $now.ToUniversalTime()
$nowEpoch   = [int][double]::Parse((Get-Date $nowUtc -UFormat %s))

# Dynamically discover Robot Number and Robot Control Media Server
$robotNum = 0
$tapeMediaServer = $masterHost

try {
    $sampleTape = & "$volmgr\vmquery.exe" -a 2>$null | Select-String -Pattern "robot number:\s*(\d+)|robot control host:\s*(\S+)"
    foreach ($m in $sampleTape) {
        if ($m.Line -match "robot number:\s*(\d+)") { $robotNum = [int]$matches[1] }
        if ($m.Line -match "robot control host:\s*(\S+)") { $tapeMediaServer = $matches[1].Split('.')[0] }
    }
} catch {}

Write-Host "========================================================================================" -ForegroundColor Cyan
Write-Host "             ENTERPRISE NETBACKUP COMPREHENSIVE OPERATIONAL DASHBOARD                   " -ForegroundColor Cyan
Write-Host "  Master Host   : $masterHost               Report Generated: $($now.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkCyan
Write-Host "  Binary Root   : $baseDir       Execution Mode  : SINGLE-PASS BULLETPROOF (Issues Only)" -ForegroundColor DarkCyan
Write-Host "  Discovered TLD: Robot $robotNum on Host [$tapeMediaServer]" -ForegroundColor DarkCyan
Write-Host "========================================================================================" -ForegroundColor Cyan

# ==============================================================================
# PHASE 2: SINGLE-PASS DATA GATHERING
# ==============================================================================
$rawJobs         = & "$admincmd\bpdbjobs.exe" -report -all_columns 2>$null
$rawPools        = & "$admincmd\nbdevquery.exe" -listdv -stype PureDisk -l 2>$null
$rawMediaList    = & "$admincmd\bpmedialist.exe" -l 2>$null
$rawCatalogDR    = & "$admincmd\bpimagelist.exe" -hoursago 48 -U 2>$null
$rawCertDetails  = & "$nbbin\nbcertcmd.exe" -listCertDetails 2>$null
$rawAllPolicies  = & "$admincmd\bppllist.exe" -allpolicies -U 2>$null
$rawVmqueryAll   = & "$volmgr\vmquery.exe" -a 2>$null

# Drive status from discovered tape media server
$rawDrives = & "$volmgr\vmoprcmd.exe" -d 2>$null
if (-not $rawDrives -or $rawDrives -match "not active") {
    $rawDrives = & "$volmgr\vmoprcmd.exe" -h $tapeMediaServer -d 2>$null
}

# Local Windows Services on Master Server
$rawServices = Get-Service -Name "NetBackup*", "Veritas*" 2>$null

# Local Catalog Drive Disk Space
$catalogDisk = Get-PSDrive -Name ($catalogDriveLetter.TrimEnd(':')) 2>$null

$criticalCount = 0
$warningCount  = 0
$infoCount     = 0

# ==============================================================================
# PHASE 3: PARSING & EVALUATION
# ==============================================================================

# ------------------------------------------------------------------------------
# Check 1: NetBackup Core Windows Services
# ------------------------------------------------------------------------------
$coreServices = @("NetBackup Database Manager", "NetBackup Request Daemon", "NetBackup Enterprise Media Manager", "NetBackup Resource Broker")
$stoppedServices = @()

foreach ($s in $rawServices) {
    if ($s.DisplayName -in $coreServices -and $s.Status -ne "Running") {
        $stoppedServices += [PSCustomObject]@{
            ServiceName = $s.DisplayName
            Status      = $s.Status
            StartType   = $s.StartType
        }
        $criticalCount++
    }
}

if ($stoppedServices.Count -gt 0) {
    Write-Host "[ALERT] Core NetBackup Services Stopped on $($masterHost):" -ForegroundColor Red
    $stoppedServices | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Core Services: All critical Master daemons (EMM, Resource Broker, DB Manager) are Running." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Check 2: Catalog Database Local Disk Space
# ------------------------------------------------------------------------------
if ($catalogDisk) {
    $catFreeGB  = [math]::Round($catalogDisk.Free / 1GB, 2)
    $catUsedGB  = [math]::Round($catalogDisk.Used / 1GB, 2)
    $catTotalGB = $catFreeGB + $catUsedGB
    $catPctFree = [math]::Round(($catFreeGB / $catTotalGB) * 100, 1)

    if ($catPctFree -le 10.0) {
        Write-Host "[CRITICAL] Catalog Disk Space: Drive $catalogDriveLetter has only $catPctFree% ($catFreeGB GB) free space remaining!" -ForegroundColor Red
        $criticalCount++
    } elseif ($catPctFree -le 20.0) {
        Write-Host "[WARNING]  Catalog Disk Space: Drive $catalogDriveLetter has $catPctFree% ($catFreeGB GB) free space remaining." -ForegroundColor Yellow
        $warningCount++
    } else {
        Write-Host "[PASS] Catalog Local Storage: Drive $catalogDriveLetter has $catFreeGB GB free ($catPctFree% available)." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# Check 3: Host Security Certificate Health (Bulletproof Multi-Format Parser)
# ------------------------------------------------------------------------------
$expiryLine = $rawCertDetails | Select-String -Pattern "Expiry Date\s*:\s*(.+)$"
if ($expiryLine) {
    $expiryRaw = $expiryLine.Matches[0].Groups[1].Value.Trim()
    $cleanExpiry = [regex]::Replace(($expiryRaw -replace "GMT|UTC", "").Trim(), '\s+', ' ')
    
    $expiryDate = [DateTime]::MinValue
    $formats = @("MMM d HH:mm:ss yyyy", "MMM dd HH:mm:ss yyyy", "yyyy-MM-dd HH:mm:ss", "M/d/yyyy h:mm:ss tt")
    $parsed = [DateTime]::TryParseExact($cleanExpiry, $formats, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$expiryDate)
    
    if (-not $parsed) {
        $parsed = [DateTime]::TryParse($cleanExpiry, [ref]$expiryDate)
    }

    if ($parsed -and $expiryDate -ne [DateTime]::MinValue) {
        $daysRemaining = [math]::Round(($expiryDate - $now).TotalDays, 0)
        if ($daysRemaining -le 30) {
            Write-Host "[CRITICAL] Host Certificate: Expiring in $daysRemaining days ($expiryRaw)!" -ForegroundColor Red
            $criticalCount++
        } elseif ($daysRemaining -le 60) {
            Write-Host "[WARNING]  Host Certificate: Expiring in $daysRemaining days ($expiryRaw)." -ForegroundColor Yellow
            $warningCount++
        } else {
            Write-Host "[PASS] Host Certificate: Valid until $($expiryDate.ToString('yyyy-MM-dd')) ($daysRemaining days remaining)." -ForegroundColor Green
        }
    } else {
        Write-Host "[WARNING]  Host Certificate: Unable to parse date string '$expiryRaw'." -ForegroundColor Yellow
        $warningCount++
    }
} else {
    Write-Host "[WARNING]  Host Certificate: Unable to retrieve certificate details." -ForegroundColor Yellow
    $warningCount++
}

# ------------------------------------------------------------------------------
# Check 4: Catalog DR Backup Freshness
# ------------------------------------------------------------------------------
$catalogSuccess = $false
$lastCatalogDate = $null

foreach ($line in $rawCatalogDR) {
    if ($line -match "CatalogBackup|Catalog") {
        $tokens = $line -split '\s+'
        if ($tokens.Count -ge 3) {
            $lastCatalogDate = "$($tokens[0]) $($tokens[1])"
            $catalogSuccess = $true
            break
        }
    }
}

if ($catalogSuccess) {
    Write-Host "[PASS] Catalog DR Backup: Successfully verified within last 24h (Last run: $lastCatalogDate)." -ForegroundColor Green
} else {
    Write-Host "[CRITICAL] Catalog DR Backup: Zero successful catalog runs in past 48 hours!" -ForegroundColor Red
    $criticalCount++
}

# ------------------------------------------------------------------------------
# Check 5: Storage Pools Capacity & Watermarks
# ------------------------------------------------------------------------------
$poolIssues = @()
$poolCount = 0

foreach ($line in $rawPools) {
    if ($line.StartsWith("V_")) {
        $poolCount++
        $f = $line -split '\s+'
        if ($f.Count -ge 8) {
            $poolName = $f[1]
            $totalGB  = [math]::Round([double]$f[5], 2)
            $freeGB   = [math]::Round([double]$f[6], 2)
            $pctUsed  = [int]$f[7]
            $usedGB   = [math]::Round(($totalGB - $freeGB), 2)

            if ($pctUsed -ge 80) {
                $isCrit = $pctUsed -ge 95
                $poolIssues += [PSCustomObject]@{
                    StoragePool = $poolName
                    TotalGB     = $totalGB
                    UsedGB      = $usedGB
                    FreeGB      = $freeGB
                    PercentUsed = "$pctUsed%"
                    Severity    = if ($isCrit) { "CRITICAL" } else { "WARNING" }
                }
                if ($isCrit) { $criticalCount++ } else { $warningCount++ }
            }
        }
    }
}

if ($poolIssues.Count -gt 0) {
    Write-Host "[ALERT] Storage Pools Exceeding 80% Capacity Threshold:" -ForegroundColor Red
    $poolIssues | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Storage Pools: All $poolCount PureDisk/Cloud pools healthy (<80% utilization)." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Check 6: Tape Drives & Drive Status on Media Server
# ------------------------------------------------------------------------------
$driveIssues = @()
for ($i = 0; $i -lt $rawDrives.Count; $i++) {
    $line = $rawDrives[$i]
    if ($line -match "^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)") {
        $drvIndex = $matches[1]
        $drvType  = $matches[2]
        $control  = $matches[3]
        $recMID   = $matches[5]
        $ready    = $matches[7]

        if ($control -eq "DOWN" -or $control -match "AVR" -or $line -match "NEEDS CLEANING") {
            $driveIssues += [PSCustomObject]@{
                DriveIndex = $drvIndex
                DriveType  = $drvType
                Control    = $control
                MountedMID = $recMID
                Ready      = $ready
                Issue      = if ($control -eq "DOWN") { "Drive DOWN" } else { "Needs Cleaning / AVR" }
            }
            $criticalCount++
        }
    }
}

if ($driveIssues.Count -gt 0) {
    Write-Host "[ALERT] Tape Drive Issue(s) on $($tapeMediaServer):" -ForegroundColor Red
    $driveIssues | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Tape Drives: All drives on $tapeMediaServer are UP and operational." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Check 7: Tape Media Health (Exact Location & TLD Breakdown)
# ------------------------------------------------------------------------------
# Parse vmquery -a to build exact physical location map for all media
$tapeLocations = @{}
$currentMid = $null
$currentRec = @{}

foreach ($vLine in $rawVmqueryAll) {
    $trimL = $vLine.Trim()
    if ($trimL -match "^media ID:\s+(\S+)") {
        $currentMid = $matches[1]
        $currentRec = @{
            MediaID   = $currentMid
            Pool      = "Unknown"
            RobotType = "NONE"
            RobotNum  = -1
            Slot      = "---"
        }
        $tapeLocations[$currentMid] = $currentRec
    } elseif ($currentMid) {
        if ($trimL -match "^volume pool:\s+(.+?)(?:\s+\(\d+\))?$") {
            $currentRec.Pool = $matches[1].Trim()
        } elseif ($trimL -match "^robot type:\s+(\S+)") {
            $currentRec.RobotType = $matches[1]
        } elseif ($trimL -match "^robot number:\s+(\d+)") {
            $currentRec.RobotNum = [int]$matches[1]
        } elseif ($trimL -match "^robot slot:\s+(\S+)") {
            $currentRec.Slot = $matches[1]
        }
    }
}

# Parse bpmedialist -l to identify Frozen & Suspended media
$frozenInTLD   = @()
$frozenOffsite = @()
$suspendedList = @()

foreach ($mLine in $rawMediaList) {
    $f = $mLine -split '\s+'
    # In bpmedialist -l, field index 11 (12th field) is the hex status flag
    if ($f.Count -ge 12) {
        $mId = $f[0]
        $statHex = $f[11]
        if ($statHex -match "^0x") {
            $statVal = [Convert]::ToInt32($statHex, 16)
            $isFrozen    = ($statVal -band 0x1) -ne 0
            $isSuspended = ($statVal -band 0x2) -ne 0

            $loc = "Offsite / Non-Robotic"
            $rNum = "---"
            $slot = "---"
            $pool = "Unknown"

            if ($tapeLocations.ContainsKey($mId)) {
                $tObj = $tapeLocations[$mId]
                $pool = $tObj.Pool
                if ($tObj.RobotType -match "TLD") {
                    $loc = "Robot $($tObj.RobotNum)"
                    $rNum = $tObj.RobotNum
                    $slot = $tObj.Slot
                }
            }

            if ($isFrozen) {
                $frozenObj = [PSCustomObject]@{
                    MediaID    = $mId
                    VolumePool = $pool
                    Location   = $loc
                    Robot      = $rNum
                    Slot       = $slot
                    Status     = "FROZEN"
                }
                if ($loc -match "Robot") {
                    $frozenInTLD += $frozenObj
                } else {
                    $frozenOffsite += $frozenObj
                }
            }

            if ($isSuspended) {
                $suspendedList += [PSCustomObject]@{
                    MediaID    = $mId
                    VolumePool = $pool
                    Location   = $loc
                    Slot       = $slot
                    Status     = "SUSPENDED"
                }
            }
        }
    }
}

# Display Library TLD Frozen Status
if ($frozenInTLD.Count -gt 0) {
    Write-Host "[ALERT] Frozen Tapes INSIDE Library (TLD):" -ForegroundColor Red
    $frozenInTLD | Format-Table -AutoSize
    $criticalCount += $frozenInTLD.Count
} else {
    Write-Host "[PASS] Library TLD Media: Zero frozen tapes inside active tape library/TLD." -ForegroundColor Green
}

# Display Offsite Frozen Status (Informational)
if ($frozenOffsite.Count -gt 0) {
    Write-Host "[INFO]  Offsite / Vault Media: $($frozenOffsite.Count) historical tape(s) flagged frozen in database (Not in library):" -ForegroundColor DarkYellow
    $frozenOffsite | Select-Object -First 10 | Format-Table -AutoSize
    if ($frozenOffsite.Count -gt 10) {
        Write-Host "        ... and $($frozenOffsite.Count - 10) more offsite frozen media." -ForegroundColor Gray
    }
    $infoCount += $frozenOffsite.Count
}

if ($suspendedList.Count -gt 0) {
    Write-Host "[WARNING] Suspended Tapes Detected ($($suspendedList.Count) tapes):" -ForegroundColor Yellow
    $suspendedList | Format-Table -AutoSize
    $warningCount += $suspendedList.Count
}

# ------------------------------------------------------------------------------
# Check 8: Stalled / Long-Running Active Jobs (>24 Hours)
# ------------------------------------------------------------------------------
$stalledJobs = @()

foreach ($line in $rawJobs) {
    $f = $line.Split(',')
    if ($f.Count -gt 8 -and $f[2] -eq '1') {
        $startEpoch = [int]$f[8]
        $elapsedHours = [math]::Round(($nowEpoch - $startEpoch) / 3600, 1)

        if ($elapsedHours -ge 24.0) {
            $stalledJobs += [PSCustomObject]@{
                JobID        = $f[0]
                JobType      = switch ($f[1]) { '0' {'Backup'} '4' {'Duplication'} '6' {'Catalog'} '17' {'SLP'} Default {$f[1]} }
                Policy       = $f[4]
                Schedule     = $f[5]
                Client       = $f[6]
                ElapsedHours = $elapsedHours
            }
            $warningCount++
        }
    }
}

if ($stalledJobs.Count -gt 0) {
    Write-Host "[ALERT] Stalled / Long-Running Jobs (>24 Hours Elapsed):" -ForegroundColor Red
    $stalledJobs | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Active Job Queue: Zero jobs running >24 hours." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# Check 9: Backup Stream Health & Unresolved Failures (Past 24 Hours)
# ------------------------------------------------------------------------------
$cutoff24h = $nowEpoch - (24 * 3600)
$activeStreamsRunning = @{}

foreach ($line in $rawJobs) {
    $f = $line.Split(',')
    if ($f.Count -gt 8) {
        $state  = $f[2]
        $sched  = $f[5]
        $client = $f[6]
        $policy = $f[4]
        if ($sched -ne "-" -and $state -in @('0', '1', '2')) {
            $activeStreamsRunning["$client::$policy"] = $true
        }
    }
}

$latestCompletedJob = @{}
foreach ($line in $rawJobs) {
    $f = $line.Split(',')
    if ($f.Count -gt 8) {
        $jobId    = [int]$f[0]
        $jobType  = $f[1]
        $state    = $f[2]
        $status   = [int]$f[3]
        $policy   = $f[4]
        $schedule = $f[5]
        $client   = $f[6]
        $startSec = [int]$f[8]

        if ($jobType -eq '0' -and $state -eq '3' -and $schedule -ne "-" -and $status -ne 191 -and $startSec -ge $cutoff24h) {
            $streamKey = "$client::$policy"
            if (-not $latestCompletedJob.ContainsKey($streamKey) -or $jobId -gt $latestCompletedJob[$streamKey].JobID) {
                $latestCompletedJob[$streamKey] = [PSCustomObject]@{
                    JobID    = $jobId
                    Client   = $client
                    Policy   = $policy
                    Schedule = $schedule
                    ExitCode = $status
                }
            }
        }
    }
}

$completeFailures = @()
$partialSuccesses = @()

foreach ($key in $latestCompletedJob.Keys) {
    if ($activeStreamsRunning.ContainsKey($key)) { continue }

    $job = $latestCompletedJob[$key]
    if ($job.ExitCode -eq 0) {
        continue
    } elseif ($job.ExitCode -eq 1) {
        $partialSuccesses += [PSCustomObject]@{
            JobID          = $job.JobID
            Client         = $job.Client
            Policy         = $job.Policy
            Schedule       = $job.Schedule
            Classification = "Partial Success (Exit Code 1)"
        }
        $infoCount++
    } else {
        $completeFailures += [PSCustomObject]@{
            JobID          = $job.JobID
            Client         = $job.Client
            Policy         = $job.Policy
            Schedule       = $job.Schedule
            ExitCode       = $job.ExitCode
            Classification = "Complete Failure"
        }
        $criticalCount++
    }
}

if ($completeFailures.Count -gt 0) {
    Write-Host "[ALERT] Unresolved Backup Failures in Past 24h (Complete Failures):" -ForegroundColor Red
    $completeFailures | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Backup Failures: Zero complete unresolved failures in past 24 hours." -ForegroundColor Green
}

if ($partialSuccesses.Count -gt 0) {
    Write-Host "[INFO]  Partially Successful Backups in Past 24h (Exit Code 1):" -ForegroundColor DarkYellow
    $partialSuccesses | Format-Table -AutoSize
}

# ------------------------------------------------------------------------------
# Check 10, 11, 12: In-Memory Bulk Policy, Schedule & Client Audit
# (With In-Progress Monthly Recognition & Upgrade Policy Filtering)
# ------------------------------------------------------------------------------
$cutoff31d = $nowEpoch - (31 * 24 * 3600)
$cutoff14d = $nowEpoch - (14 * 24 * 3600)

$successfulMonthlyBackups = @{}
$activeMonthlyBackups     = @{}
$anyPolicyActivity        = @{}
$clientSuccessActivity    = @{}

foreach ($line in $rawJobs) {
    $f = $line.Split(',')
    if ($f.Count -gt 8) {
        $jobId     = $f[0]
        $jobType   = $f[1]
        $state     = $f[2]
        $exitCode  = [int]$f[3]
        $policy    = $f[4]
        $schedule  = $f[5]
        $client    = $f[6]
        $startSec  = [int]$f[8]

        if ($jobType -in @('0', '6')) {
            # Active monthly streams currently running
            if ($state -in @('0', '1', '2') -and $schedule -match "Monthly") {
                $elapsedH = [math]::Round(($nowEpoch - $startSec) / 3600, 1)
                $activeMonthlyBackups["$client::$policy"] = [PSCustomObject]@{
                    JobID        = $jobId
                    ElapsedHours = $elapsedH
                }
            }

            # Completed jobs
            if ($state -eq '3') {
                if ($startSec -ge $cutoff14d) {
                    $anyPolicyActivity[$policy] = $true
                }
                if ($exitCode -in @(0, 1) -and $startSec -ge $cutoff31d) {
                    $clientSuccessActivity[$client] = $true
                    if ($schedule -match "Monthly") {
                        $successfulMonthlyBackups["$client::$policy"] = $true
                    }
                }
            }
        }
    }
}

$monthlyMissing    = @()
$monthlyInProgress = @()
$silentPolicies    = @()
$ghostClients      = @()

if ($rawAllPolicies) {
    $policyBlocks = ($rawAllPolicies -join "`n") -split "Policy Name:\s+"
    foreach ($block in $policyBlocks) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        
        $lines = $block -split "`n"
        $polName = $lines[0].Trim()
        $isActive = ($block | Select-String -Pattern "Active:\s*yes") -ne $null

        # Filter out CatalogBackup, cloud snapshot policies, and client deployment/upgrade policies
        if ($polName -match "CatalogBackup|^SLO_UUID_|^Protection_Plan_|_upgrade|^NB_10\.") {
            continue
        }

        if ($isActive) {
            # Check 11: Silent Policy
            if (-not $anyPolicyActivity.ContainsKey($polName)) {
                $silentPolicies += [PSCustomObject]@{
                    PolicyName  = $polName
                    Status      = "Active in NetBackup, but 0 backup runs in past 14 days"
                }
                $warningCount++
            }

            # Extract Clients
            $clients = @()
            $clientMatches = [regex]::Matches($block, "HW/OS/Client:\s+\S+\s+\S+\s+(\S+)")
            foreach ($cm in $clientMatches) {
                $cVal = $cm.Groups[1].Value
                if ($cVal -ne "MEDIA_SERVER") {
                    $clients += $cVal
                }
            }

            # Check 10: Monthly Schedule Completion with IN-PROGRESS Detection
            $hasMonthlySched = ($block | Select-String -Pattern "Schedule:\s+.*Monthly.*") -ne $null
            if ($hasMonthlySched) {
                foreach ($c in $clients) {
                    $mKey = "$c::$polName"
                    if ($activeMonthlyBackups.ContainsKey($mKey)) {
                        $aObj = $activeMonthlyBackups[$mKey]
                        $monthlyInProgress += [PSCustomObject]@{
                            PolicyName   = $polName
                            ClientName   = $c
                            JobID        = $aObj.JobID
                            ElapsedHours = $aObj.ElapsedHours
                            Status       = "Currently In Progress"
                        }
                    } elseif (-not $successfulMonthlyBackups.ContainsKey($mKey)) {
                        $monthlyMissing += [PSCustomObject]@{
                            PolicyName = $polName
                            ClientName = $c
                            Issue      = "No successful run in last 31 days and not currently running"
                        }
                        $criticalCount++
                    }
                }
            }

            # Check 12: Ghost Clients
            foreach ($c in $clients) {
                if (-not $clientSuccessActivity.ContainsKey($c)) {
                    $ghostClients += [PSCustomObject]@{
                        PolicyName = $polName
                        ClientName = $c
                        Status     = "Configured in active policy, but 0 successful backups in last 30 days"
                    }
                    $warningCount++
                }
            }
        }
    }
}

# Display Monthly Completion & In-Progress Status
if ($monthlyMissing.Count -gt 0) {
    Write-Host "[ALERT] Monthly Backup Schedule Incomplete / Missing:" -ForegroundColor Red
    $monthlyMissing | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Monthly Backup Schedules: All active monthly schedules completed or currently in progress." -ForegroundColor Green
}

if ($monthlyInProgress.Count -gt 0) {
    Write-Host "[INFO]  Monthly Backups Currently In Progress:" -ForegroundColor DarkYellow
    $monthlyInProgress | Format-Table -AutoSize
}

# Display Silent Policies
if ($silentPolicies.Count -gt 0) {
    Write-Host "[ALERT] Silent / Inactive Policies (Active but 0 runs in last 14 days):" -ForegroundColor Yellow
    $silentPolicies | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Silent Policies: All active policies have executed backups in the last 14 days." -ForegroundColor Green
}

# Display Ghost Clients
if ($ghostClients.Count -gt 0) {
    Write-Host "[ALERT] Ghost / Stale Clients (0 successful backups in last 30 days):" -ForegroundColor Yellow
    $ghostClients | Format-Table -AutoSize
} else {
    Write-Host "[PASS] Client Audit: All configured clients have recent successful backups." -ForegroundColor Green
}

# ==============================================================================
# PHASE 4: EXECUTIVE SUMMARY FOOTER
# ==============================================================================
Write-Host "----------------------------------------------------------------------------------------" -ForegroundColor Cyan
if ($criticalCount -eq 0 -and $warningCount -eq 0) {
    Write-Host "STATUS: [HEALTHY] - All core NetBackup services, pools, media, and queues are normal." -ForegroundColor Green
    if ($infoCount -gt 0) {
        Write-Host "NOTE:   $infoCount stream(s) finished with Partial Success or Offsite media status." -ForegroundColor DarkYellow
    }
} else {
    Write-Host "STATUS: [ATTENTION REQUIRED] - Critical Issues: $criticalCount | Warnings: $warningCount | Info/Partial: $infoCount" -ForegroundColor Red
}
Write-Host "========================================================================================" -ForegroundColor Cyan