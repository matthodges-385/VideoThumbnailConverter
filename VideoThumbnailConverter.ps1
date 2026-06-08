Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Tool Detection
function Find-Tool ([string]$name) {
    $local = Join-Path $PSScriptRoot "$name.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:ffmpeg        = Find-Tool "ffmpeg"
$script:ffprobe       = Find-Tool "ffprobe"
$script:atomicParsley = Find-Tool "AtomicParsley"

if (-not $script:ffmpeg -or -not $script:ffprobe) {
    [System.Windows.Forms.MessageBox]::Show(
        "ffmpeg.exe and ffprobe.exe were not found.`n`nPlease download FFmpeg from https://ffmpeg.org/download.html and either:`n  - Place ffmpeg.exe and ffprobe.exe in the same folder as this script, or`n  - Add FFmpeg to your system PATH.",
        "FFmpeg Not Found",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit
}
#endregion

#region State
$script:sourceFiles  = [System.Collections.Generic.List[string]]::new()
$script:cancelFlag   = $false
$script:isProcessing = $false
$script:pendingJobs  = $null
$script:fileQueue    = $null
$script:pollTimer    = $null
$script:pool         = $null
$script:logFile      = ""
$script:totalFiles   = 0
$script:processed    = 0
$script:errors       = 0
$script:errorLog     = $null
$script:outFolder    = ""
$script:processStr   = ""
#endregion

#region Processing script block (runs in background runspaces)
$script:processBlock = {
    param($inputFile, $outputFolder, $ffmpegPath, $ffprobePath, $atomicParsleyPath)

    $ext      = [System.IO.Path]::GetExtension($inputFile).ToLower()
    $baseName = [System.IO.Path]::GetFileName($inputFile)
    $outFile  = Join-Path $outputFolder $baseName
    $tmpDir   = [System.IO.Path]::GetTempPath()
    $tmpBase  = [System.IO.Path]::GetRandomFileName()
    $tmpThumb = Join-Path $tmpDir ($tmpBase + ".jpg")
    $tmpVideo = Join-Path $tmpDir ($tmpBase + $ext)

    try {
        # Probe duration
        $durResult = & $ffprobePath -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $inputFile 2>$null
        $duration  = if ($durResult -match '^\d') { [double]$durResult } else { 0 }
        $seekSec   = if ($duration -gt 0) { [Math]::Min(35, $duration * 0.5) } else { 35 }
        $seekStr   = [TimeSpan]::FromSeconds($seekSec).ToString("hh\:mm\:ss")

        # Extract thumbnail frame
        $frameErr = & $ffmpegPath -y -ss $seekStr -i $inputFile -frames:v 1 -q:v 2 $tmpThumb 2>&1
        if (-not (Test-Path $tmpThumb) -or (Get-Item $tmpThumb).Length -eq 0) {
            $detail = ($frameErr | Where-Object { $_ -match 'Error|Invalid|No such' } | Select-Object -Last 2) -join ' '
            return [PSCustomObject]@{ Success = $false; File = $inputFile; Error = "Frame extraction failed. $detail".Trim() }
        }

        # Embed thumbnail
        $embedOk = $false

        if ($atomicParsleyPath -and $ext -ne '.mkv') {
            # AtomicParsley - fast metadata-only patch for MP4/MOV/M4V
            $apErr = & $atomicParsleyPath $inputFile --artwork $tmpThumb --output $tmpVideo 2>&1
            if (Test-Path $tmpVideo) {
                $item = Get-Item $tmpVideo
                if ($item.Length -gt 0) { $embedOk = $true }
            }
            if (-not $embedOk) {
                # Fallback to FFmpeg if AtomicParsley failed
                if (Test-Path $tmpVideo) { Remove-Item $tmpVideo -Force -ErrorAction SilentlyContinue }
            }
        }

        if (-not $embedOk) {
            if ($ext -eq '.mkv') {
                $embedErr = & $ffmpegPath -y -i $inputFile -attach $tmpThumb `
                    -metadata:s:t mimetype=image/jpeg -c copy $tmpVideo 2>&1
            } else {
                $embedErr = & $ffmpegPath -y -i $inputFile -i $tmpThumb `
                    -map 0:v:0 -map 0:a? -map 0:s? -map 1:v `
                    -c copy -c:v:1 mjpeg -disposition:v:1 attached_pic `
                    $tmpVideo 2>&1
            }
            if (Test-Path $tmpVideo) {
                $item = Get-Item $tmpVideo
                if ($item.Length -gt 0) { $embedOk = $true }
            }
            if (-not $embedOk) {
                $detail = ($embedErr | Where-Object { $_ -match 'Error|Invalid|No such|muxer' } | Select-Object -Last 2) -join ' '
                return [PSCustomObject]@{ Success = $false; File = $inputFile; Error = "Thumbnail embed failed. $detail".Trim() }
            }
        }

        # Copy to output folder
        if (-not (Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null }
        Move-Item -Path $tmpVideo -Destination $outFile -Force
        return [PSCustomObject]@{ Success = $true; File = $inputFile; Error = "" }

    } catch {
        return [PSCustomObject]@{ Success = $false; File = $inputFile; Error = $_.Exception.Message }
    } finally {
        if (Test-Path $tmpThumb) { Remove-Item $tmpThumb -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpVideo) { Remove-Item $tmpVideo -Force -ErrorAction SilentlyContinue }
    }
}
#endregion

#region Helpers
function Get-VideoFiles ([string]$path) {
    $exts = '*.mp4','*.mkv','*.mov','*.m4v','*.wmv'
    if (Test-Path $path -PathType Container) {
        return Get-ChildItem -Path $path -Recurse -Include $exts | Select-Object -ExpandProperty FullName
    } else {
        return @($path)
    }
}

function Invoke-LogMaintenance ([string]$logPath) {
    # Single rolling log — archive when file entry count hits 100
    if (-not (Test-Path $logPath)) { return }

    $lines       = Get-Content $logPath -ErrorAction SilentlyContinue
    $entryCount  = ($lines | Where-Object { $_ -match '^\[ OK \]|^\[FAIL\]' }).Count

    if ($entryCount -ge 100) {
        $stamp       = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $archiveName = "VidThumbConverter_archive_$stamp.log"
        $archivePath = Join-Path (Split-Path $logPath) $archiveName
        Copy-Item $logPath $archivePath -Force
        # Reset main log with a note pointing to the archive
        Set-Content $logPath "# Log archived on $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss')) — previous entries saved to: $archiveName`n"
    }
}
#endregion

#region Build UI
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Video Thumbnail Converter"
$form.Size            = New-Object System.Drawing.Size(570, 500)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.BackColor       = [System.Drawing.Color]::WhiteSmoke
$icoPath = Join-Path $PSScriptRoot "VidThumbConvert.ico"
if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }

# Header panel
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Size      = New-Object System.Drawing.Size(570, 70)
$pnlHeader.Location  = New-Object System.Drawing.Point(0, 0)
$pnlHeader.BackColor = [System.Drawing.Color]::White

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = "Video Thumbnail Converter"
$lblTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
$lblTitle.AutoSize  = $true
$lblTitle.Location  = New-Object System.Drawing.Point(80, 15)
$pnlHeader.Controls.Add($lblTitle)

$picHeader = New-Object System.Windows.Forms.PictureBox
$picHeader.Size     = New-Object System.Drawing.Size(60, 60)
$picHeader.Location = New-Object System.Drawing.Point(10, 5)
$picHeader.SizeMode = "Zoom"
$bmpH = New-Object System.Drawing.Bitmap(60, 60)
$gH   = [System.Drawing.Graphics]::FromImage($bmpH)
$gH.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$gH.FillRectangle([System.Drawing.Brushes]::CornflowerBlue, 5, 15, 50, 30)
$pts = New-Object 'System.Drawing.Point[]' 3
$pts[0] = New-Object System.Drawing.Point(22, 22)
$pts[1] = New-Object System.Drawing.Point(42, 30)
$pts[2] = New-Object System.Drawing.Point(22, 38)
$gH.FillPolygon([System.Drawing.Brushes]::White, $pts)
$gH.Dispose()
$picHeader.Image = $bmpH
$pnlHeader.Controls.Add($picHeader)
$form.Controls.Add($pnlHeader)

# Source row
$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text     = "Target File/s or Folder Location:"
$lblSource.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblSource.AutoSize = $true
$lblSource.Location = New-Object System.Drawing.Point(55, 85)
$form.Controls.Add($lblSource)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Items.AddRange(@("Select video file(s)", "Select folder"))
$cmbMode.SelectedIndex  = 0
$cmbMode.DropDownStyle  = "DropDownList"
$cmbMode.Size           = New-Object System.Drawing.Size(160, 24)
$cmbMode.Location       = New-Object System.Drawing.Point(350, 82)
$form.Controls.Add($cmbMode)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Size     = New-Object System.Drawing.Size(380, 24)
$txtSource.Location = New-Object System.Drawing.Point(55, 112)
$form.Controls.Add($txtSource)

$btnBrowseSource = New-Object System.Windows.Forms.Button
$btnBrowseSource.Text     = "Browse..."
$btnBrowseSource.Size     = New-Object System.Drawing.Size(90, 26)
$btnBrowseSource.Location = New-Object System.Drawing.Point(445, 111)
$form.Controls.Add($btnBrowseSource)

# Output row
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text     = "Output Folder Location:"
$lblOutput.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblOutput.AutoSize = $true
$lblOutput.Location = New-Object System.Drawing.Point(55, 155)
$form.Controls.Add($lblOutput)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Size     = New-Object System.Drawing.Size(380, 24)
$txtOutput.Location = New-Object System.Drawing.Point(55, 178)
$form.Controls.Add($txtOutput)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text     = "Browse..."
$btnBrowseOutput.Size     = New-Object System.Drawing.Size(90, 26)
$btnBrowseOutput.Location = New-Object System.Drawing.Point(445, 177)
$form.Controls.Add($btnBrowseOutput)

# Action buttons
function New-ActionButton ($text, $backColor, $x) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $text
    $btn.Size      = New-Object System.Drawing.Size(110, 50)
    $btn.Location  = New-Object System.Drawing.Point($x, 220)
    $btn.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $btn.BackColor = $backColor
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    return $btn
}

$btnStart  = New-ActionButton "Start"  ([System.Drawing.Color]::FromArgb(34,139,34))   20
$btnStop   = New-ActionButton "Stop"   ([System.Drawing.Color]::FromArgb(192,0,0))     140
$btnUpdate = New-ActionButton "Update" ([System.Drawing.Color]::FromArgb(0,128,0))     260
$btnExit   = New-ActionButton "Exit"   ([System.Drawing.Color]::FromArgb(0,120,215))   380
$form.Controls.AddRange(@($btnStart, $btnStop, $btnUpdate, $btnExit))

# Progress section
$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text      = "Progress Information:"
$lblProgress.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblProgress.ForeColor = [System.Drawing.Color]::FromArgb(0,102,204)
$lblProgress.AutoSize  = $true
$lblProgress.Location  = New-Object System.Drawing.Point(55, 290)
$form.Controls.Add($lblProgress)

$txtProgressInfo = New-Object System.Windows.Forms.TextBox
$txtProgressInfo.Size      = New-Object System.Drawing.Size(480, 24)
$txtProgressInfo.Location  = New-Object System.Drawing.Point(55, 315)
$txtProgressInfo.ReadOnly  = $true
$txtProgressInfo.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtProgressInfo)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Size     = New-Object System.Drawing.Size(480, 18)
$progressBar.Location = New-Object System.Drawing.Point(55, 345)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$form.Controls.Add($progressBar)

function New-CountLabel ($text, $x, $y) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $text
    $lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point($x, $y)
    return $lbl
}

$lblFound     = New-CountLabel "Files Found : 0"  55  378
$lblProcessed = New-CountLabel "Processed : 0"    300 378
$lblToDo      = New-CountLabel "To do : 0"        55  405
$lblErrors    = New-CountLabel "Errors : 0"       300 405
$lblErrors.ForeColor = [System.Drawing.Color]::Red

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text      = "Version 1.8"
$lblVersion.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblVersion.ForeColor = [System.Drawing.Color]::Gray
$lblVersion.AutoSize  = $true
$lblVersion.Location  = New-Object System.Drawing.Point(460, 455)

# AtomicParsley status indicator
$lblAPStatus = New-Object System.Windows.Forms.Label
$lblAPStatus.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$lblAPStatus.AutoSize = $true
$lblAPStatus.Location = New-Object System.Drawing.Point(55, 455)
if ($script:atomicParsley) {
    $lblAPStatus.Text      = "Fast mode: AtomicParsley detected"
    $lblAPStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,128,0)
} else {
    $lblAPStatus.Text      = "Standard mode: AtomicParsley not found"
    $lblAPStatus.ForeColor = [System.Drawing.Color]::Gray
}

$form.Controls.AddRange(@($lblFound, $lblProcessed, $lblToDo, $lblErrors, $lblVersion, $lblAPStatus))
#endregion

#region Counter helper
function Update-Counters ($found, $processed, $todo, $errors) {
    $lblFound.Text     = "Files Found : $found"
    $lblProcessed.Text = "Processed : $processed"
    $lblToDo.Text      = "To do : $todo"
    $lblErrors.Text    = "Errors : $errors"
    if ($found -gt 0) { $progressBar.Value = [Math]::Min(100, [int](($processed + $errors) / $found * 100)) }
    else              { $progressBar.Value = 0 }
    $form.Refresh()
}
#endregion

#region Browse handlers
function Select-FolderViaFileDialog ([string]$title) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title       = $title
    $dlg.Filter      = "All files (*.*)|*.*"
    $dlg.Multiselect = $false
    if ($dlg.ShowDialog() -eq "OK") {
        return [System.IO.Path]::GetDirectoryName($dlg.FileName)
    }
    return $null
}

$btnBrowseSource.Add_Click({
    if ($cmbMode.SelectedIndex -eq 0) {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title       = "Select Video File(s)"
        $dlg.Filter      = "Video Files|*.mp4;*.mkv;*.mov;*.m4v;*.wmv|All Files|*.*"
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -eq "OK") {
            $script:sourceFiles.Clear()
            $script:sourceFiles.AddRange([string[]]$dlg.FileNames)
            if ($dlg.FileNames.Count -eq 1) {
                $txtSource.Text = $dlg.FileName
            } else {
                $txtSource.Text = "$($dlg.FileNames.Count) files selected"
            }
            Update-Counters $script:sourceFiles.Count 0 $script:sourceFiles.Count 0
        }
    } else {
        $folder = Select-FolderViaFileDialog "Select any file inside the source folder"
        if ($folder) {
            $txtSource.Text = $folder
            $files = Get-VideoFiles $folder
            $script:sourceFiles.Clear()
            if ($files) { $script:sourceFiles.AddRange([string[]]@($files)) }
            Update-Counters $script:sourceFiles.Count 0 $script:sourceFiles.Count 0
        }
    }
})

$btnBrowseOutput.Add_Click({
    $folder = Select-FolderViaFileDialog "Select any file inside the desired output folder"
    if ($folder) { $txtOutput.Text = $folder }
})
#endregion

#region Update button
$btnUpdate.Add_Click({
    $typedPath = $txtSource.Text.Trim()
    if ($typedPath -eq "") {
        [System.Windows.Forms.MessageBox]::Show("Please enter or browse to a source path first.", "No Source", "OK", "Information") | Out-Null
        return
    }
    $script:sourceFiles.Clear()
    if (Test-Path $typedPath -PathType Container) {
        $files = Get-VideoFiles $typedPath
        if ($files) { $script:sourceFiles.AddRange([string[]]@($files)) }
    } elseif (Test-Path $typedPath -PathType Leaf) {
        $script:sourceFiles.Add($typedPath)
    } else {
        [System.Windows.Forms.MessageBox]::Show("Path not found:`n$typedPath", "Invalid Path", "OK", "Warning") | Out-Null
        return
    }
    Update-Counters $script:sourceFiles.Count 0 $script:sourceFiles.Count 0
    $count = $script:sourceFiles.Count
    $txtProgressInfo.Text = "Ready - $count file(s) found."
})
#endregion

#region Start button
$btnStart.Add_Click({
    if ($script:isProcessing) { return }

    # Populate from typed path if list is empty
    if ($script:sourceFiles.Count -eq 0) {
        $typedPath = $txtSource.Text.Trim()
        if ($typedPath -ne "" -and (Test-Path $typedPath -PathType Container)) {
            $files = Get-VideoFiles $typedPath
            if ($files) { $script:sourceFiles.AddRange([string[]]@($files)) }
        } elseif ($typedPath -ne "" -and (Test-Path $typedPath -PathType Leaf)) {
            $script:sourceFiles.Add($typedPath)
        }
    }
    if ($script:sourceFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select or type a source path first.", "No Source", "OK", "Warning") | Out-Null
        return
    }
    $outFolder = $txtOutput.Text.Trim()
    if ($outFolder -eq "") {
        [System.Windows.Forms.MessageBox]::Show("Please select an output folder.", "No Output Folder", "OK", "Warning") | Out-Null
        return
    }

    $script:cancelFlag   = $false
    $script:isProcessing = $true
    $btnStart.Enabled        = $false
    $btnBrowseSource.Enabled = $false
    $btnBrowseOutput.Enabled = $false

    # Reset counters
    $script:processed = 0
    $script:errors    = 0
    $script:errorLog  = [System.Collections.Generic.List[string]]::new()
    $script:totalFiles = $script:sourceFiles.Count

    # Rolling log — archive if over 100 entries, then append to single file
    $script:logFile = Join-Path $PSScriptRoot "VidThumbConverter.log"
    Invoke-LogMaintenance $script:logFile
    $logHeader      = "Video Thumbnail Converter v1.8 - Run started $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))"
    $logHeader     += "`nSource : $($txtSource.Text)"
    $logHeader     += "`nOutput : $outFolder"
    $logHeader     += "`nMode   : $(if ($script:atomicParsley) { 'Fast (AtomicParsley + FFmpeg)' } else { 'Standard (FFmpeg)' })"
    $logHeader     += "`nParallel jobs : 2"
    $logHeader     += "`nTotal files   : $($script:totalFiles)`n" + ("-" * 60)
    Add-Content -Path $script:logFile -Value $logHeader

    # Create runspace pool (2 parallel jobs)
    $script:pool = [RunspaceFactory]::CreateRunspacePool(1, 2)
    $script:pool.Open()

    # Convert scriptblock to string so it serialises cleanly into each runspace
    $script:processStr = $script:processBlock.ToString()
    $script:outFolder  = $outFolder

    # Build file queue — we submit jobs 2 at a time so queued count is accurate
    $script:fileQueue   = [System.Collections.Generic.Queue[string]]::new()
    foreach ($file in $script:sourceFiles.ToArray()) { $script:fileQueue.Enqueue($file) }
    $script:pendingJobs = [System.Collections.Generic.List[hashtable]]::new()

    # Seed the first 2 jobs
    $maxConcurrent = 2
    for ($i = 0; $i -lt $maxConcurrent -and $script:fileQueue.Count -gt 0; $i++) {
        $file = $script:fileQueue.Dequeue()
        $ps   = [PowerShell]::Create()
        $ps.RunspacePool = $script:pool
        [void]$ps.AddScript($script:processStr)
        [void]$ps.AddParameter('inputFile',        $file)
        [void]$ps.AddParameter('outputFolder',     $script:outFolder)
        [void]$ps.AddParameter('ffmpegPath',       $script:ffmpeg)
        [void]$ps.AddParameter('ffprobePath',      $script:ffprobe)
        [void]$ps.AddParameter('atomicParsleyPath',$script:atomicParsley)
        $handle = $ps.BeginInvoke()
        $script:pendingJobs.Add(@{ PS = $ps; Handle = $handle; File = $file; StartTime = [System.DateTime]::Now.Ticks })
    }

    Update-Counters $script:totalFiles 0 $script:totalFiles 0

    # Poll timer — runs on UI thread, safe to update controls
    $script:pollTimer = New-Object System.Windows.Forms.Timer
    $script:pollTimer.Interval = 400
    $script:pollTimer.Add_Tick({

        # Handle stop request
        if ($script:cancelFlag) {
            $script:fileQueue.Clear()
            foreach ($job in $script:pendingJobs) {
                try { $job.PS.Stop() } catch {}
                $job.PS.Dispose()
            }
            $script:pendingJobs.Clear()
        }

        # Collect completed jobs
        $toRemove = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($job in $script:pendingJobs) {
            if ($job.Handle.IsCompleted) {
                try {
                    $results  = $job.PS.EndInvoke($job.Handle)
                    $ts       = (Get-Date).ToString('HH:mm:ss')
                    $elapsed  = if ($job.StartTime) { [Math]::Round(([System.DateTime]::Now.Ticks - [long]$job.StartTime) / 10000000.0, 1) } else { 0 }
                    foreach ($r in $results) {
                        $name     = [System.IO.Path]::GetFileName($r.File)
                        $fileItem = Get-Item $r.File -ErrorAction SilentlyContinue
                        $sizeStr  = if ($fileItem) {
                            $b = $fileItem.Length
                            if     ($b -ge 1GB) { "{0:N1} GB" -f ($b / 1GB) }
                            elseif ($b -ge 1MB) { "{0:N1} MB" -f ($b / 1MB) }
                            else                { "{0:N0} KB" -f ($b / 1KB) }
                        } else { "?" }
                        if ($r.Success) {
                            $script:processed++
                            Add-Content -Path $script:logFile -Value "[ OK ]  $ts  (${elapsed}s)  $sizeStr  $name"
                        } else {
                            $script:errors++
                            $errMsg = ($r.Error -replace '[\r\n]+', ' ').Trim()
                            Add-Content -Path $script:logFile -Value "[FAIL]  $ts  (${elapsed}s)  $sizeStr  $name`n        Reason: $errMsg"
                            try { $script:errorLog.Add("$name`n        $errMsg") } catch {}
                        }
                    }
                } catch {
                    $script:errors++
                    $ts      = (Get-Date).ToString('HH:mm:ss')
                    $elapsed  = if ($job.StartTime) { [Math]::Round(([System.DateTime]::Now.Ticks - [long]$job.StartTime) / 10000000.0, 1) } else { 0 }
                    $name    = [System.IO.Path]::GetFileName($job.File)
                    $errMsg  = ($_.Exception.Message -replace '[\r\n]+', ' ').Trim()
                    Add-Content -Path $script:logFile -Value "[FAIL]  $ts  (${elapsed}s)  $name`n        Reason: $errMsg"
                }
                $job.PS.Dispose()
                $toRemove.Add($job)
            }
        }
        foreach ($j in $toRemove) { [void]$script:pendingJobs.Remove($j) }

        # Feed next jobs from queue to fill free slots
        while ($script:pendingJobs.Count -lt 2 -and $script:fileQueue.Count -gt 0 -and -not $script:cancelFlag) {
            $file = $script:fileQueue.Dequeue()
            $ps   = [PowerShell]::Create()
            $ps.RunspacePool = $script:pool
            [void]$ps.AddScript($script:processStr)
            [void]$ps.AddParameter('inputFile',        $file)
            [void]$ps.AddParameter('outputFolder',     $script:outFolder)
            [void]$ps.AddParameter('ffmpegPath',       $script:ffmpeg)
            [void]$ps.AddParameter('ffprobePath',      $script:ffprobe)
            [void]$ps.AddParameter('atomicParsleyPath',$script:atomicParsley)
            $handle = $ps.BeginInvoke()
            $script:pendingJobs.Add(@{ PS = $ps; Handle = $handle; File = $file; StartTime = [System.DateTime]::Now.Ticks })
        }

        # Update UI
        $done    = $script:processed + $script:errors
        $running = $script:pendingJobs.Count
        $queued  = $script:fileQueue.Count
        if ($running -gt 0 -or $queued -gt 0) {
            $txtProgressInfo.Text = "$running running, $queued queued | $done of $($script:totalFiles) done"
        }
        Update-Counters $script:totalFiles $script:processed ($script:totalFiles - $done) $script:errors

        # All done?
        if ($script:pendingJobs.Count -eq 0 -and $script:fileQueue.Count -eq 0) {
            $script:pollTimer.Stop()
            $script:pool.Close()
            $script:pool.Dispose()

            # Write log footer
            $footer  = "`n" + ("-" * 60)
            $footer += "`nRun finished $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))"
            $footer += "`nProcessed OK : $($script:processed)"
            $footer += "`nFailed       : $($script:errors)"
            Add-Content -Path $script:logFile -Value $footer

            # Re-enable UI
            $script:isProcessing     = $false
            $btnStart.Enabled        = $true
            $btnBrowseSource.Enabled = $true
            $btnBrowseOutput.Enabled = $true

            if ($script:cancelFlag) {
                $txtProgressInfo.Text = "Stopped. Processed: $($script:processed)  Errors: $($script:errors)"
            } else {
                $txtProgressInfo.Text = "Done! Processed: $($script:processed)  Errors: $($script:errors)  (log saved)"
            }

            # Show error summary if needed
            if ($script:errorLog.Count -gt 0) {
                $logMsg = "The following files could not be processed:`n`n" +
                          ($script:errorLog -join "`n`n") +
                          "`n`nFull details saved to:`n$($script:logFile)"
                [System.Windows.Forms.MessageBox]::Show(
                    $logMsg,
                    "Errors ($($script:errorLog.Count) file(s))",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
        }
    })
    $script:pollTimer.Start()
})
#endregion

#region Stop / Exit
$btnStop.Add_Click({ $script:cancelFlag = $true })

$btnExit.Add_Click({
    if ($script:isProcessing) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Processing is still running. Stop and exit?",
            "Confirm Exit",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:cancelFlag = $true
        if ($script:pollTimer) { $script:pollTimer.Stop() }
        if ($script:pool)      { try { $script:pool.Close(); $script:pool.Dispose() } catch {} }
    }
    $form.Close()
})
#endregion

[System.Windows.Forms.Application]::Run($form)
