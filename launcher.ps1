$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$root = $PSScriptRoot
$aiRoot = Join-Path $root 'apps\domestic-global-ai-workbench'
$aiExe = Join-Path $aiRoot 'AI多Agent流水线.exe'
$homeworkRoot = Join-Path $root 'apps\qq-email-homework-assistant'
$homeworkScript = Join-Path $homeworkRoot 'app.pyw'
$iconPath = Join-Path $root '电工猴的此思妙想工作台-高清.ico'
$portalPath = Join-Path $root '电工猴的此思妙想工作台.html'

# ---------------- 调色板 ----------------
$cInk = [System.Drawing.Color]::FromArgb(28, 40, 36)
$cMuted = [System.Drawing.Color]::FromArgb(112, 126, 120)
$cCanvas = [System.Drawing.Color]::FromArgb(238, 241, 239)
$cGreen = [System.Drawing.Color]::FromArgb(36, 113, 94)
$cGreenDark = [System.Drawing.Color]::FromArgb(25, 88, 71)
$cGreenPale = [System.Drawing.Color]::FromArgb(233, 243, 238)
$cAmber = [System.Drawing.Color]::FromArgb(181, 121, 45)
$cAmberPale = [System.Drawing.Color]::FromArgb(251, 242, 230)
$cOffDot = [System.Drawing.Color]::FromArgb(176, 187, 182)

function Set-Rounded {
    param($Control, [int]$Radius)
    if ($null -eq $Control) { return }
    try {
        $w = $Control.Width
        $h = $Control.Height
        if ($w -le 4 -or $h -le 4) { return }
        $d = $Radius * 2
        if ($d -gt $w) { $d = $w }
        if ($d -gt $h) { $d = $h }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc(($w - $d), 0, $d, $d, 270, 90)
        $path.AddArc(($w - $d), ($h - $d), $d, $d, 0, 90)
        $path.AddArc(0, ($h - $d), $d, $d, 90, 90)
        $path.CloseFigure()
        $Control.Region = New-Object System.Drawing.Region($path)
    } catch { }
}

function Test-Port {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(220, $false)
        if (-not $ok) { $client.Close(); return $false }
        $client.EndConnect($iar)
        $client.Close()
        return $true
    } catch { return $false }
}

function Find-Pythonw {
    if ($env:PYTHONW_PATH -and (Test-Path -LiteralPath $env:PYTHONW_PATH)) { return $env:PYTHONW_PATH }
    $cmd = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        (Join-Path $env:ProgramFiles 'Python')
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            $found = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'pythonw.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($found) { return $found }
        }
    }
    return $null
}

$pythonw = Find-Pythonw

# ---------------- 窗口 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = '电工猴的此思妙想工作台'
$form.ClientSize = New-Object System.Drawing.Size(720, 494)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.BackColor = $cCanvas
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
}

# ---------------- 渐变头部 ----------------
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(720, 126)
$header.Add_Paint({
        param($s, $e)
        $r = $s.ClientRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { return }
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, [System.Drawing.Color]::FromArgb(23, 64, 52), [System.Drawing.Color]::FromArgb(15, 90, 77), 12.0)
        $e.Graphics.FillRectangle($brush, $r)
        $brush.Dispose()
        $f1 = New-Object System.Drawing.Font('Microsoft YaHei UI', 19, [System.Drawing.FontStyle]::Bold)
        $e.Graphics.DrawString('电工猴的此思妙想工作台', $f1, [System.Drawing.Brushes]::White, 30, 20)
        $f1.Dispose()
        $f2 = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
        $subBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(191, 214, 204))
        $e.Graphics.DrawString('应用中心 · 本机工具与 AI 协作', $f2, $subBrush, 32, 72)
        $subBrush.Dispose()
        $f2.Dispose()
    })
$form.Controls.Add($header)

# ---------------- 卡片工厂 ----------------
function New-AppCard {
    param(
        [int]$Top,
        [string]$Title,
        [string]$Detail,
        [string]$Glyph,
        [System.Drawing.Color]$From,
        [System.Drawing.Color]$To,
        [string]$BadgeText,
        [System.Drawing.Color]$BadgeBack,
        [System.Drawing.Color]$BadgeFore,
        [scriptblock]$OnOpen
    )

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(12, $Top)
    $card.Size = New-Object System.Drawing.Size(696, 120)
    $card.BackColor = [System.Drawing.Color]::White
    $card.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Add_Paint({
            param($s, $e)
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(226, 232, 227), 1)
            $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
            $pen.Dispose()
        })
    Set-Rounded -Control $card -Radius 12

    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 16)
    $accent.Size = New-Object System.Drawing.Size(4, 88)
    $accent.BackColor = $From
    $card.Controls.Add($accent)

    $ava = New-Object System.Windows.Forms.Panel
    $ava.Location = New-Object System.Drawing.Point(24, 30)
    $ava.Size = New-Object System.Drawing.Size(60, 60)
    $ava.BackColor = [System.Drawing.Color]::White
    $ava.Cursor = [System.Windows.Forms.Cursors]::Hand
    $fromColor = $From
    $toColor = $To
    $glyphText = $Glyph
    $ava.Add_Paint({
            param($s, $e)
            $r = $s.ClientRectangle
            if ($r.Width -le 0 -or $r.Height -le 0) { return }
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath
            $d = 26
            $p.AddArc(0, 0, $d, $d, 180, 90)
            $p.AddArc(($r.Width - $d), 0, $d, $d, 270, 90)
            $p.AddArc(($r.Width - $d), ($r.Height - $d), $d, $d, 0, 90)
            $p.AddArc(0, ($r.Height - $d), $d, $d, 90, 90)
            $p.CloseFigure()
            $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, $fromColor, $toColor, 45.0)
            $e.Graphics.FillPath($b, $p)
            $b.Dispose()
            $p.Dispose()
            $f = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rect = New-Object System.Drawing.RectangleF(0, 0, $r.Width, $r.Height)
            $e.Graphics.DrawString($glyphText, $f, [System.Drawing.Brushes]::White, $rect, $fmt)
            $f.Dispose()
            $fmt.Dispose()
        }.GetNewClosure())
    $card.Controls.Add($ava)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Location = New-Object System.Drawing.Point(104, 24)
    $titleLabel.Size = New-Object System.Drawing.Size(460, 28)
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $cInk
    $titleLabel.BackColor = [System.Drawing.Color]::White
    $titleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($titleLabel)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Text = $Detail
    $detailLabel.Location = New-Object System.Drawing.Point(105, 55)
    $detailLabel.Size = New-Object System.Drawing.Size(460, 22)
    $detailLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $detailLabel.ForeColor = $cMuted
    $detailLabel.BackColor = [System.Drawing.Color]::White
    $detailLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $card.Controls.Add($detailLabel)

    $badge = New-Object System.Windows.Forms.Label
    $badge.Text = $BadgeText
    $badge.Location = New-Object System.Drawing.Point(104, 84)
    $badge.Size = New-Object System.Drawing.Size(88, 22)
    $badge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $badge.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8, [System.Drawing.FontStyle]::Bold)
    $badge.ForeColor = $BadgeFore
    $badge.BackColor = $BadgeBack
    $badge.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-Rounded -Control $badge -Radius 11
    $card.Controls.Add($badge)

    $button = New-Object System.Windows.Forms.Button
    $button.Text = '打开'
    $button.Location = New-Object System.Drawing.Point(580, 38)
    $button.Size = New-Object System.Drawing.Size(96, 44)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $cGreen
    $button.ForeColor = [System.Drawing.Color]::White
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-Rounded -Control $button -Radius 10
    $button.Add_MouseEnter({ $button.BackColor = [System.Drawing.Color]::FromArgb(25, 88, 71) }.GetNewClosure())
    $button.Add_MouseLeave({ $button.BackColor = [System.Drawing.Color]::FromArgb(36, 113, 94) }.GetNewClosure())
    $button.Add_Click($OnOpen)
    $card.Controls.Add($button)

    $enter = {
        $card.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 248)
        $titleLabel.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 248)
        $detailLabel.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 248)
        $ava.BackColor = [System.Drawing.Color]::FromArgb(247, 250, 248)
    }.GetNewClosure()
    $leave = {
        $pos = $card.PointToClient([System.Windows.Forms.Cursor]::Position)
        if (-not $card.ClientRectangle.Contains($pos)) {
            $card.BackColor = [System.Drawing.Color]::White
            $titleLabel.BackColor = [System.Drawing.Color]::White
            $detailLabel.BackColor = [System.Drawing.Color]::White
            $ava.BackColor = [System.Drawing.Color]::White
        }
    }.GetNewClosure()

    foreach ($el in @($card, $titleLabel, $detailLabel, $ava, $badge)) {
        $el.Add_MouseEnter($enter)
        $el.Add_MouseLeave($leave)
        $el.Add_Click($OnOpen)
    }

    return $card
}

# ---------------- 底部提示与状态 ----------------
$hint = New-Object System.Windows.Forms.Label
$hint.Location = New-Object System.Drawing.Point(32, 418)
$hint.Size = New-Object System.Drawing.Size(656, 20)
$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$hint.ForeColor = $cMuted
$hint.BackColor = $cCanvas
$form.Controls.Add($hint)

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Text = '服务状态'
$statusCaption.Location = New-Object System.Drawing.Point(32, 450)
$statusCaption.Size = New-Object System.Drawing.Size(58, 20)
$statusCaption.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$statusCaption.ForeColor = $cMuted
$statusCaption.BackColor = $cCanvas
$form.Controls.Add($statusCaption)

$dotHw = New-Object System.Windows.Forms.Label
$dotHw.Text = '○ QQ 邮箱助手'
$dotHw.Location = New-Object System.Drawing.Point(92, 450)
$dotHw.Size = New-Object System.Drawing.Size(160, 20)
$dotHw.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$dotHw.ForeColor = $cOffDot
$dotHw.BackColor = $cCanvas
$form.Controls.Add($dotHw)

$dotAi = New-Object System.Windows.Forms.Label
$dotAi.Text = '○ AI 工作台'
$dotAi.Location = New-Object System.Drawing.Point(256, 450)
$dotAi.Size = New-Object System.Drawing.Size(160, 20)
$dotAi.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$dotAi.ForeColor = $cOffDot
$dotAi.BackColor = $cCanvas
$form.Controls.Add($dotAi)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = '刷新状态'
$refresh.Location = New-Object System.Drawing.Point(596, 444)
$refresh.Size = New-Object System.Drawing.Size(92, 28)
$refresh.FlatStyle = 'Flat'
$refresh.FlatAppearance.BorderSize = 0
$refresh.BackColor = $cCanvas
$refresh.ForeColor = $cGreen
$refresh.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$refresh.Cursor = [System.Windows.Forms.Cursors]::Hand
$refresh.Add_MouseEnter({ $refresh.ForeColor = [System.Drawing.Color]::FromArgb(25, 88, 71) }.GetNewClosure())
$refresh.Add_MouseLeave({ $refresh.ForeColor = [System.Drawing.Color]::FromArgb(36, 113, 94) }.GetNewClosure())
$form.Controls.Add($refresh)

$portalButton = New-Object System.Windows.Forms.Button
$portalButton.Text = '打开门户页'
$portalButton.Location = New-Object System.Drawing.Point(494, 444)
$portalButton.Size = New-Object System.Drawing.Size(96, 28)
$portalButton.FlatStyle = 'Flat'
$portalButton.FlatAppearance.BorderSize = 0
$portalButton.BackColor = $cCanvas
$portalButton.ForeColor = $cGreen
$portalButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$portalButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$portalButton.Add_MouseEnter({ $portalButton.ForeColor = [System.Drawing.Color]::FromArgb(25, 88, 71) }.GetNewClosure())
$portalButton.Add_MouseLeave({ $portalButton.ForeColor = [System.Drawing.Color]::FromArgb(36, 113, 94) }.GetNewClosure())
$portalButton.Add_Click({
        if (Test-Path -LiteralPath $portalPath) {
            Start-Process -FilePath $portalPath | Out-Null
            $hint.Text = '已打开：工作台门户页'
        }
    }.GetNewClosure())
$form.Controls.Add($portalButton)

function Update-Status {
    if (Test-Port 8765) {
        $dotHw.ForeColor = [System.Drawing.Color]::FromArgb(36, 113, 94)
        $dotHw.Text = '● QQ 邮箱助手 运行中'
    } else {
        $dotHw.ForeColor = [System.Drawing.Color]::FromArgb(176, 187, 182)
        $dotHw.Text = '○ QQ 邮箱助手 未运行'
    }
    if (Test-Port 8767) {
        $dotAi.ForeColor = [System.Drawing.Color]::FromArgb(36, 113, 94)
        $dotAi.Text = '● AI 工作台 运行中'
    } else {
        $dotAi.ForeColor = [System.Drawing.Color]::FromArgb(176, 187, 182)
        $dotAi.Text = '○ AI 工作台 未运行'
    }
}

# ---------------- 启动动作 ----------------
$aiAction = {
    if (Test-Path -LiteralPath $aiExe) {
        try {
            Start-Process -FilePath $aiExe -WorkingDirectory $aiRoot | Out-Null
            $hint.Text = '已打开：国内外 AI 协同工作台'
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
        }
        return
    }
    $entry = Join-Path $aiRoot 'platform.py'
    if (-not $pythonw) {
        [System.Windows.Forms.MessageBox]::Show($form, "找不到 $aiExe，也没找到 pythonw.exe。`n请先构建应用，或设置环境变量 PYTHONW_PATH。", '无法打开', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not (Test-Path -LiteralPath $entry)) {
        [System.Windows.Forms.MessageBox]::Show($form, "找不到应用文件：`n$entry", '无法打开', 'OK', 'Error') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $pythonw -ArgumentList ('"{0}"' -f $entry) -WorkingDirectory $aiRoot | Out-Null
        $hint.Text = '已打开：国内外 AI 协同工作台（源码模式）'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure()

$homeworkAction = {
    if (-not (Test-Path -LiteralPath $homeworkScript)) {
        [System.Windows.Forms.MessageBox]::Show($form, "找不到应用文件：`n$homeworkScript", '无法打开', 'OK', 'Error') | Out-Null
        return
    }
    if (-not $pythonw) {
        [System.Windows.Forms.MessageBox]::Show($form, '未找到 pythonw.exe。请安装 Python 3.9 或更新版本，或设置 PYTHONW_PATH。', '需要 Python', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        Start-Process -FilePath $pythonw -ArgumentList ('"{0}"' -f $homeworkScript) -WorkingDirectory $homeworkRoot | Out-Null
        $hint.Text = '已打开：QQ 邮箱作业班长助手'
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
    }
}.GetNewClosure()

# ---------------- 组装 ----------------
$aiCard = New-AppCard -Top 150 -Title '国内外 AI 协同工作台' -Detail '多 Agent 任务协作 · 方案博弈 · 实时控制台' -Glyph 'AI' -From ([System.Drawing.Color]::FromArgb(213, 109, 89)) -To ([System.Drawing.Color]::FromArgb(232, 155, 134)) -BadgeText 'AI 协作' -BadgeBack $cAmberPale -BadgeFore $cAmber -OnOpen $aiAction
$form.Controls.Add($aiCard)

$hwCard = New-AppCard -Top 286 -Title 'QQ 邮箱作业班长助手' -Detail '作业收集与提交统计 · 自动提醒未交' -Glyph '作' -From ([System.Drawing.Color]::FromArgb(36, 113, 94)) -To ([System.Drawing.Color]::FromArgb(31, 160, 138)) -BadgeText '本地' -BadgeBack $cGreenPale -BadgeFore $cGreenDark -OnOpen $homeworkAction
$form.Controls.Add($hwCard)

$tickStatus = { try { Update-Status } catch { } }
$refresh.Add_Click($tickStatus)
$form.Add_Shown($tickStatus)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 15000
$timer.Add_Tick($tickStatus)
$timer.Start()

[void]$form.ShowDialog()

$timer.Stop()
$timer.Dispose()
