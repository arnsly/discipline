# ------------------------------------------------------------------
#  Таймер проектов — мини-виджет для рабочего стола Windows
#  Данные: data.json (источник) + data.js (для summary.html)
# ------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- только один экземпляр ---------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ArinaTimeTrackerWidget')
if (-not $script:Mutex.WaitOne(0)) { exit }

$Root        = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$DataJson    = Join-Path $Root 'data.json'
$DataJs      = Join-Path $Root 'data.js'
$SummaryHtml = Join-Path $Root 'index.html'
$SyncCmd     = Join-Path $Root 'sync.cmd'

function AsArray($x) {
  if ($null -eq $x) { return @() }
  if ($x -is [System.Array]) { return $x }
  return @($x)
}

function ParseDate([string]$s) {
  [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

$script:Projects = New-Object System.Collections.ArrayList
$script:Sessions = New-Object System.Collections.ArrayList
$script:Current  = $null
$script:WinPos   = $null
$script:Busy     = $false

# --- данные -------------------------------------------------------
function Load-Data {
  $script:Projects.Clear(); $script:Sessions.Clear(); $script:Current = $null
  if (Test-Path $DataJson) {
    try {
      $d = ConvertFrom-Json ([IO.File]::ReadAllText($DataJson, [Text.Encoding]::UTF8))
      foreach ($p in (AsArray $d.projects)) { if ("$p".Trim()) { [void]$script:Projects.Add([string]$p) } }
      foreach ($s in (AsArray $d.sessions)) {
        if ($null -eq $s) { continue }
        [void]$script:Sessions.Add(@{
          project = [string]$s.project
          start   = [string]$s.start
          end     = [string]$s.end
          seconds = [int]$s.seconds
        })
      }
      if ($d.current -and $d.current.start) {
        $st = ParseDate ([string]$d.current.start)
        # защита от «забытого» таймера после выключения компьютера
        if (((Get-Date) - $st).TotalHours -lt 12) {
          $script:Current = @{ project = [string]$d.current.project; start = $st }
        }
      }
      if ($d.window) { $script:WinPos = @{ x = [int]$d.window.x; y = [int]$d.window.y } }
    } catch { }
  }
  if ($script:Projects.Count -eq 0) { [void]$script:Projects.Add('Мой проект') }
}

function Save-Data {
  $cur = $null
  if ($script:Current) {
    $cur = [ordered]@{ project = $script:Current.project; start = $script:Current.start.ToString('o') }
  }
  $win = $null
  if ($script:WinPos) { $win = [ordered]@{ x = $script:WinPos.x; y = $script:WinPos.y } }

  $sess = @()
  foreach ($s in $script:Sessions) {
    $sess += ,([ordered]@{ project = $s.project; start = $s.start; end = $s.end; seconds = $s.seconds })
  }

  $obj = [ordered]@{
    projects = @($script:Projects)
    sessions = $sess
    current  = $cur
    window   = $win
    updated  = (Get-Date).ToString('o')
  }
  $json = $obj | ConvertTo-Json -Depth 6
  $enc  = New-Object Text.UTF8Encoding $false
  try {
    [IO.File]::WriteAllText($DataJson, $json, $enc)
    [IO.File]::WriteAllText($DataJs, "window.TT_DATA = $json;", $enc)
  } catch { }
}

function Fmt-Short([int]$sec) {
  $h = [math]::Floor($sec / 3600)
  $m = [math]::Floor(($sec % 3600) / 60)
  if ($h -gt 0) { return ("{0}ч {1}м" -f $h, $m) }
  if ($m -gt 0) { return ("{0}м" -f $m) }
  return '0м'
}

function Today-Seconds {
  $today = (Get-Date).Date
  $sum = 0
  foreach ($s in $script:Sessions) {
    try { if ((ParseDate $s.start).Date -eq $today) { $sum += $s.seconds } } catch { }
  }
  if ($script:Current) { $sum += [int]((Get-Date) - $script:Current.start).TotalSeconds }
  return $sum
}

Load-Data

# --- окно ---------------------------------------------------------
$W = 288
$H = 120
$C_BG   = [Drawing.ColorTranslator]::FromHtml('#15161A')
$C_CARD = [Drawing.ColorTranslator]::FromHtml('#23252D')
$C_TEXT = [Drawing.ColorTranslator]::FromHtml('#F2F2F7')
$C_DIM  = [Drawing.ColorTranslator]::FromHtml('#8A8D99')
$C_GO   = [Drawing.ColorTranslator]::FromHtml('#4F8EF7')
$C_STOP = [Drawing.ColorTranslator]::FromHtml('#E0564B')

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ClientSize      = New-Object Drawing.Size($W, $H)
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $C_BG
$form.StartPosition   = 'Manual'
$form.Text            = 'Таймер проектов'

# скруглённые углы
$gp = New-Object Drawing.Drawing2D.GraphicsPath
$r  = 16
$gp.AddArc(0, 0, $r, $r, 180, 90)
$gp.AddArc($W - $r, 0, $r, $r, 270, 90)
$gp.AddArc($W - $r, $H - $r, $r, $r, 0, 90)
$gp.AddArc(0, $H - $r, $r, $r, 90, 90)
$gp.CloseAllFigures()
$form.Region = New-Object Drawing.Region($gp)

# положение: сохранённое или правый нижний угол
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($script:WinPos) {
  $form.Location = New-Object Drawing.Point($script:WinPos.x, $script:WinPos.y)
} else {
  $form.Location = New-Object Drawing.Point(($wa.Right - $W - 24), ($wa.Bottom - $H - 24))
}

function New-FlatButton($text, $x, $y, $w, $h, $bg, $fg, $fontSize) {
  $b = New-Object Windows.Forms.Button
  $b.Text     = $text
  $b.Location = New-Object Drawing.Point($x, $y)
  $b.Size     = New-Object Drawing.Size($w, $h)
  $b.FlatStyle = 'Flat'
  $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $bg
  $b.ForeColor = $fg
  $b.Font      = New-Object Drawing.Font('Segoe UI', $fontSize)
  $b.TabStop   = $false
  $b.Cursor    = 'Hand'
  return $b
}

# выбор проекта
$combo = New-Object Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'
$combo.FlatStyle     = 'Flat'
$combo.Location      = New-Object Drawing.Point(12, 10)
$combo.Size          = New-Object Drawing.Size(188, 24)
$combo.BackColor     = $C_CARD
$combo.ForeColor     = $C_TEXT
$combo.Font          = New-Object Drawing.Font('Segoe UI', 9)
foreach ($p in $script:Projects) { [void]$combo.Items.Add($p) }
$combo.SelectedIndex = 0
$form.Controls.Add($combo)

$btnAdd   = New-FlatButton '+' 206 10 28 24 $C_CARD $C_TEXT 11
$btnClose = New-FlatButton 'x' 240 10 36 24 $C_CARD $C_DIM 9
$form.Controls.Add($btnAdd)
$form.Controls.Add($btnClose)

# большое время
$lblTime = New-Object Windows.Forms.Label
$lblTime.Location  = New-Object Drawing.Point(10, 38)
$lblTime.Size      = New-Object Drawing.Size(178, 36)
$lblTime.Font      = New-Object Drawing.Font('Consolas', 23, [Drawing.FontStyle]::Bold)
$lblTime.ForeColor = $C_TEXT
$lblTime.Text      = '00:00:00'
$lblTime.TextAlign = 'MiddleLeft'
$form.Controls.Add($lblTime)

$lblToday = New-Object Windows.Forms.Label
$lblToday.Location  = New-Object Drawing.Point(190, 40)
$lblToday.Size      = New-Object Drawing.Size(86, 32)
$lblToday.Font      = New-Object Drawing.Font('Segoe UI', 8.5)
$lblToday.ForeColor = $C_DIM
$lblToday.TextAlign = 'MiddleRight'
$form.Controls.Add($lblToday)

$btnToggle  = New-FlatButton 'Старт'  12 80 130 28 $C_GO   $C_TEXT 10
$btnSummary = New-FlatButton 'Сводка' 148 80 128 28 $C_CARD $C_TEXT 9.5
$form.Controls.Add($btnToggle)
$form.Controls.Add($btnSummary)

# --- перетаскивание мышкой ---------------------------------------
$script:Drag    = $false
$script:DragOff = New-Object Drawing.Point(0, 0)
$script:DragSrc = $form

$onDown = {
  if ($_.Button -eq [Windows.Forms.MouseButtons]::Left) {
    $script:Drag    = $true
    $script:DragSrc = $this
    $script:DragOff = New-Object Drawing.Point($_.X, $_.Y)
  }
}
$onMove = {
  if ($script:Drag) {
    $sp  = [Windows.Forms.Control]::MousePosition
    $off = $script:DragOff
    if ($script:DragSrc -ne $form) {
      $off = New-Object Drawing.Point(($off.X + $script:DragSrc.Left), ($off.Y + $script:DragSrc.Top))
    }
    $form.Location = New-Object Drawing.Point(($sp.X - $off.X), ($sp.Y - $off.Y))
  }
}
$onUp = {
  if ($script:Drag) {
    $script:Drag   = $false
    $script:WinPos = @{ x = $form.Location.X; y = $form.Location.Y }
    Save-Data
  }
}
foreach ($c in @($form, $lblTime, $lblToday)) {
  $c.add_MouseDown($onDown)
  $c.add_MouseMove($onMove)
  $c.add_MouseUp($onUp)
}

# --- логика -------------------------------------------------------
function Update-Ui {
  if ($script:Current) {
    $el = [int]((Get-Date) - $script:Current.start).TotalSeconds
    if ($el -lt 0) { $el = 0 }
    $lblTime.Text        = [TimeSpan]::FromSeconds($el).ToString('hh\:mm\:ss')
    $lblTime.ForeColor   = $C_TEXT
    $btnToggle.Text      = 'Стоп'
    $btnToggle.BackColor = $C_STOP
    $combo.Enabled       = $false
    $idx = $combo.Items.IndexOf($script:Current.project)
    if ($idx -ge 0 -and $combo.SelectedIndex -ne $idx) { $combo.SelectedIndex = $idx }
  } else {
    $lblTime.Text        = '00:00:00'
    $lblTime.ForeColor   = $C_DIM
    $btnToggle.Text      = 'Старт'
    $btnToggle.BackColor = $C_GO
    $combo.Enabled       = $true
  }
  $lblToday.Text = "сегодня`n" + (Fmt-Short (Today-Seconds))
}

# отправляет data.json на GitHub, если папка подключена к репозиторию
function Push-Remote {
  if (-not (Test-Path $SyncCmd)) { return }
  if (-not (Test-Path (Join-Path $Root '.git'))) { return }
  try {
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('"' + $SyncCmd + '"') -WindowStyle Hidden | Out-Null
  } catch { }
}

function Start-Tracking($project) {
  if (-not $project) { return }
  $script:Current = @{ project = [string]$project; start = Get-Date }
  Save-Data
  Update-Ui
}

function Stop-Tracking {
  if (-not $script:Current) { return }
  $st  = $script:Current.start
  $en  = Get-Date
  $sec = [int][math]::Round(($en - $st).TotalSeconds)
  if ($sec -ge 5) {
    [void]$script:Sessions.Add(@{
      project = $script:Current.project
      start   = $st.ToString('o')
      end     = $en.ToString('o')
      seconds = $sec
    })
  }
  $script:Current = $null
  Save-Data
  Update-Ui
  Push-Remote
}

$btnToggle.add_Click({
  if ($script:Current) { Stop-Tracking } else { Start-Tracking $combo.SelectedItem }
})

$btnAdd.add_Click({
  $name = [Microsoft.VisualBasic.Interaction]::InputBox('Название нового проекта:', 'Новый проект', '')
  $name = "$name".Trim()
  if ($name -and -not $script:Projects.Contains($name)) {
    [void]$script:Projects.Add($name)
    [void]$combo.Items.Add($name)
    $combo.SelectedIndex = $combo.Items.Count - 1
    Save-Data
  }
})

$btnSummary.add_Click({
  Save-Data
  if (Test-Path $SummaryHtml) { Start-Process $SummaryHtml }
})

$btnClose.add_Click({ $form.Close() })

# контекстное меню (правая кнопка мыши)
$menu = New-Object Windows.Forms.ContextMenuStrip
$miDelete = $menu.Items.Add('Убрать проект из списка')
$miDelete.add_Click({
  if ($script:Current) { return }
  if ($combo.Items.Count -le 1) { return }
  $p   = "$($combo.SelectedItem)"
  $ans = [Windows.Forms.MessageBox]::Show(("Убрать «{0}» из списка? Записанное время сохранится." -f $p), 'Таймер', 'YesNo', 'Question')
  if ($ans -eq 'Yes') {
    $script:Projects.Remove($p)
    $combo.Items.Remove($p)
    $combo.SelectedIndex = 0
    Save-Data
    Update-Ui
  }
})
$miFolder = $menu.Items.Add('Открыть папку с данными')
$miFolder.add_Click({ Start-Process explorer.exe $Root })
$form.ContextMenuStrip     = $menu
$lblTime.ContextMenuStrip  = $menu
$lblToday.ContextMenuStrip = $menu

# --- тики ---------------------------------------------------------
$tick = New-Object Windows.Forms.Timer
$tick.Interval = 1000
$tick.add_Tick({ Update-Ui })
$tick.Start()

# автосохранение раз в минуту, чтобы не потерять идущую сессию
$autosave = New-Object Windows.Forms.Timer
$autosave.Interval = 60000
$autosave.add_Tick({ if ($script:Current) { Save-Data } })
$autosave.Start()

$form.add_FormClosing({
  Stop-Tracking
  $tick.Stop()
  $autosave.Stop()
})

Update-Ui
Save-Data
[void]$form.ShowDialog()
try { $script:Mutex.ReleaseMutex() } catch { }
