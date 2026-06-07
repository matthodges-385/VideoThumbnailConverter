Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region FFmpeg Detection
function Find-FFmpeg {
    $local = Join-Path $PSScriptRoot "ffmpeg.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}
function Find-FFprobe {
    $local = Join-Path $PSScriptRoot "ffprobe.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:ffmpeg  = Find-FFmpeg
$script:ffprobe = Find-FFprobe

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

function Get-VideoDuration ([string]$filePath) {
    $result = & $script:ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $filePath 2>$null
    if ($result -match '^\d') { return [double]$result } else { return 0 }
}

function Set-VideoThumbnail ([string]$inputFile, [string]$outputFolder, [ref]$errorMsg) {
    $ext      = [System.IO.Path]::GetExtension($inputFile).ToLower()
    $baseName = [System.IO.Path]::GetFileName($inputFile)
    $outFile  = Join-Path $outputFolder $baseName
    $tmpDir   = [System.IO.Path]::GetTempPath()
    $tmpBase  = [System.IO.Path]::GetRandomFileName()
    $tmpThumb = Join-Path $tmpDir ($tmpBase + ".jpg")
    $tmpVideo = Join-Path $tmpDir ($tmpBase + $ext)

    try {
        $duration = Get-VideoDuration $inputFile
        $seekSec  = if ($duration -gt 0) { [Math]::Min(35, $duration * 0.5) } else { 35 }
        $seekStr  = [TimeSpan]::FromSeconds($seekSec).ToString("hh\:mm\:ss")

        # Extract frame — capture stderr so we can report failures
        $frameErr = & $script:ffmpeg -y -ss $seekStr -i $inputFile -frames:v 1 -q:v 2 $tmpThumb 2>&1
        if (-not (Test-Path $tmpThumb) -or (Get-Item $tmpThumb).Length -eq 0) {
            $detail = ($frameErr | Where-Object { $_ -match 'Error|Invalid|No such' } | Select-Object -Last 2) -join ' '
            $errorMsg.Value = "Frame extraction failed. $detail".Trim()
            return $false
        }

        # Embed thumbnail — safer stream map: first video + all audio + cover art
        # Using mjpeg (JPEG) instead of PNG for better MP4 compatibility
        $embedErr = $null
        if ($ext -eq '.mkv') {
            $embedErr = & $script:ffmpeg -y -i $inputFile -attach $tmpThumb `
                -metadata:s:t mimetype=image/jpeg -c copy $tmpVideo 2>&1
        } else {
            $embedErr = & $script:ffmpeg -y -i $inputFile -i $tmpThumb `
                -map 0:v:0 -map 0:a? -map 0:s? -map 1:v `
                -c copy -c:v:1 mjpeg -disposition:v:1 attached_pic `
                $tmpVideo 2>&1
        }

        if (-not (Test-Path $tmpVideo) -or (Get-Item $tmpVideo).Length -eq 0) {
            $detail = ($embedErr | Where-Object { $_ -match 'Error|Invalid|No such|muxer' } | Select-Object -Last 2) -join ' '
            $errorMsg.Value = "Thumbnail embed failed. $detail".Trim()
            return $false
        }

        # Move result to output folder
        if (-not (Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null }
        Move-Item -Path $tmpVideo -Destination $outFile -Force
        return $true

    } catch {
        $errorMsg.Value = $_.Exception.Message
        return $false
    } finally {
        if (Test-Path $tmpThumb) { Remove-Item $tmpThumb -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpVideo) { Remove-Item $tmpVideo -Force -ErrorAction SilentlyContinue }
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
$lblVersion.Text      = "Version 1.3"
$lblVersion.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
$lblVersion.ForeColor = [System.Drawing.Color]::Gray
$lblVersion.AutoSize  = $true
$lblVersion.Location  = New-Object System.Drawing.Point(460, 455)

$form.Controls.AddRange(@($lblFound, $lblProcessed, $lblToDo, $lblErrors, $lblVersion))
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
        # File mode — multi-select video files directly
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
        # Folder mode — pick any file inside the desired folder to identify it
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

    # If list is empty, try to populate from whatever is typed in the source box
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
    $btnStart.Enabled         = $false
    $btnBrowseSource.Enabled  = $false
    $btnBrowseOutput.Enabled  = $false

    $total     = $script:sourceFiles.Count
    $processed = 0
    $errors    = 0
    $errorLog  = [System.Collections.Generic.List[string]]::new()
    Update-Counters $total 0 $total 0

    # Create log file in script folder
    $logStamp   = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logFile    = Join-Path $PSScriptRoot "VidThumbConverter_$logStamp.log"
    $logHeader  = "Video Thumbnail Converter v1.3 - Run started $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))"
    $logHeader += "`nSource: $($txtSource.Text)"
    $logHeader += "`nOutput: $outFolder"
    $logHeader += "`nTotal files: $total`n" + ("-" * 60)
    Add-Content -Path $logFile -Value $logHeader

    $filesToProcess = $script:sourceFiles.ToArray()
    $i = 0

    foreach ($file in $filesToProcess) {
        if ($script:cancelFlag) {
            $txtProgressInfo.Text = "Stopped by user."
            Add-Content -Path $logFile -Value "`nRun stopped by user at file $i of $total."
            break
        }

        $i++
        $name = [System.IO.Path]::GetFileName($file)
        $txtProgressInfo.Text = "[$i of $total] $name"
        [System.Windows.Forms.Application]::DoEvents()

        $errMsg = [ref]""
        $ok = Set-VideoThumbnail -inputFile $file -outputFolder $outFolder -errorMsg $errMsg

        if ($ok) {
            $processed++
            Add-Content -Path $logFile -Value "[ OK ]  $name"
        } else {
            $errors++
            $errorLog.Add("$name`n        $($errMsg.Value)")
            Add-Content -Path $logFile -Value "[FAIL]  $name`n        Reason: $($errMsg.Value)"
        }
        Update-Counters $total $processed ($total - $processed - $errors) $errors
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Write summary to log
    $logFooter  = "`n" + ("-" * 60)
    $logFooter += "`nRun finished $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))"
    $logFooter += "`nProcessed OK : $processed"
    $logFooter += "`nFailed       : $errors"
    Add-Content -Path $logFile -Value $logFooter

    $script:isProcessing     = $false
    $btnStart.Enabled        = $true
    $btnBrowseSource.Enabled = $true
    $btnBrowseOutput.Enabled = $true

    if (-not $script:cancelFlag) {
        $txtProgressInfo.Text = "Done! Processed: $processed  Errors: $errors  (log saved to output folder)"
    }

    # Show error detail if any failures occurred
    if ($errorLog.Count -gt 0) {
        $logMsg = "The following files could not be processed:`n`n" + ($errorLog -join "`n`n") + "`n`nFull details saved to:`n$logFile"
        [System.Windows.Forms.MessageBox]::Show(
            $logMsg,
            "Errors ($($errorLog.Count) file(s))",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
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
    }
    $form.Close()
})
#endregion

[System.Windows.Forms.Application]::Run($form)
