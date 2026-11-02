# ------------------------------------------------------------------
#  Таймер проектов — мини-виджет для рабочего стола Windows
#  Данные: data.json (источник) + data.js (для index.html)
#
#  Горячие клавиши (работают из любого окна):
#    Ctrl+Alt+S — старт / стоп
#    Ctrl+Alt+T — показать / спрятать виджет
# ------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- только один экземпляр ---------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ArinaTimeTrackerWidget')
if (-not $script:Mutex.WaitOne(0)) { exit }

# --- приём глобальных горячих клавиш ------------------------------
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class GlobalHotkeys : NativeWindow, IDisposable {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mod, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    private const int WM_HOTKEY = 0x0312;
    private int maxId = 0;

    public event EventHandler<int> Pressed;

    public GlobalHotkeys() { CreateHandle(new CreateParams()); }

    public bool Register(int id, uint mod, uint vk) {
        if (id > maxId) maxId = id;
        return RegisterHotKey(this.Handle, id, mod, vk);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            EventHandler<int> h = Pressed;
            if (h != null) h(this, m.WParam.ToInt32());
        }
        base.WndProc(ref m);
    }

    public void Dispose() {
        for (int i = 1; i <= maxId; i++) { try { UnregisterHotKey(this.Handle, i); } catch {} }
        DestroyHandle();
    }
}
'@

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
$script:Corner   = ''      # '', 'tl', 'tr', 'bl', 'br'
$script:NoteMode = $false

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
          note    = [string]$s.note
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
      if ($d.corner) { $script:Corner = [string]$d.corner }
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
    $sess += ,([ordered]@{ project = $s.project; start = $s.start; end = $s.end; seconds = $s.seconds; note = $s.note })
  }

  $obj = [ordered]@{
    projects = @($script:Projects)
    sessions = $sess
    current  = $cur
    window   = $win
    corner   = $script:Corner
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

# --- палитра и окно -----------------------------------------------
$W = 296
$H = 126
$C_BG    = [Drawing.ColorTranslator]::FromHtml('#121316')
$C_SOFT  = [Drawing.ColorTranslator]::FromHtml('#1E2026')
$C_TEXT  = [Drawing.ColorTranslator]::FromHtml('#ECECEF')
$C_DIM   = [Drawing.ColorTranslator]::FromHtml('#7E8190')
$C_GO    = [Drawing.ColorTranslator]::FromHtml('#4F8EF7')
$C_STOP  = [Drawing.ColorTranslator]::FromHtml('#E0564B')

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ClientSize      = New-Object Drawing.Size($W, $H)
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.BackColor       = $C_BG
$form.StartPosition   = 'Manual'
$form.Text            = 'Таймер проектов'
$form.KeyPreview      = $true

# скруглённые углы
$gp = New-Object Drawing.Drawing2D.GraphicsPath
$r  = 18
$gp.AddArc(0, 0, $r, $r, 180, 90)
$gp.AddArc($W - $r, 0, $r, $r, 270, 90)
$gp.AddArc($W - $r, $H - $r, $r, $r, 0, 90)
$gp.AddArc(0, $H - $r, $r, $r, 90, 90)
$gp.CloseAllFigures()
$form.Region = New-Object Drawing.Region($gp)

function Corner-Point([string]$c) {
  $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $m  = 20
  switch ($c) {
    'tl' { return New-Object Drawing.Point(($wa.Left + $m),        ($wa.Top + $m)) }
    'tr' { return New-Object Drawing.Point(($wa.Right - $W - $m),  ($wa.Top + $m)) }
    'bl' { return New-Object Drawing.Point(($wa.Left + $m),        ($wa.Bottom - $H - $m)) }
    'br' { return New-Object Drawing.Point(($wa.Right - $W - $m),  ($wa.Bottom - $H - $m)) }
  }
  return $null
}

if ($script:Corner) {
  $form.Location = Corner-Point $script:Corner
} elseif ($script:WinPos) {
  $form.Location = New-Object Drawing.Point($script:WinPos.x, $script:WinPos.y)
} else {
  $script:Corner = 'br'
  $form.Location = Corner-Point 'br'
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

# --- обычный режим -------------------------------------------------
$combo = New-Object Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'
$combo.FlatStyle     = 'Flat'
$combo.Location      = New-Object Drawing.Point(14, 12)
$combo.Size          = New-Object Drawing.Size(192, 24)
$combo.BackColor     = $C_BG
$combo.ForeColor     = $C_DIM
$combo.Font          = New-Object Drawing.Font('Segoe UI', 9)
foreach ($p in $script:Projects) { [void]$combo.Items.Add($p) }
$combo.SelectedIndex = 0
$form.Controls.Add($combo)

$btnAdd   = New-FlatButton '+' 212 12 28 24 $C_BG $C_DIM 11
$btnClose = New-FlatButton '×' 248 12 34 24 $C_BG $C_DIM 11
$form.Controls.Add($btnAdd)
$form.Controls.Add($btnClose)

$lblTime = New-Object Windows.Forms.Label
$lblTime.Location  = New-Object Drawing.Point(12, 40)
$lblTime.Size      = New-Object Drawing.Size(180, 38)
$lblTime.Font      = New-Object Drawing.Font('Consolas', 23)
$lblTime.ForeColor = $C_TEXT
$lblTime.Text      = '00:00:00'
$lblTime.TextAlign = 'MiddleLeft'
$form.Controls.Add($lblTime)

$lblToday = New-Object Windows.Forms.Label
$lblToday.Location  = New-Object Drawing.Point(196, 42)
$lblToday.Size      = New-Object Drawing.Size(86, 34)
$lblToday.Font      = New-Object Drawing.Font('Segoe UI', 8.5)
$lblToday.ForeColor = $C_DIM
$lblToday.TextAlign = 'MiddleRight'
$form.Controls.Add($lblToday)

$btnToggle  = New-FlatButton 'Старт'  14 86 134 28 $C_GO   $C_TEXT 10
$btnSummary = New-FlatButton 'Сводка' 154 86 128 28 $C_SOFT $C_DIM  9.5
$form.Controls.Add($btnToggle)
$form.Controls.Add($btnSummary)

# --- режим заметки -------------------------------------------------
$lblAsk = New-Object Windows.Forms.Label
$lblAsk.Location  = New-Object Drawing.Point(14, 14)
$lblAsk.Size      = New-Object Drawing.Size(268, 20)
$lblAsk.Font      = New-Object Drawing.Font('Segoe UI', 9)
$lblAsk.ForeColor = $C_DIM
$lblAsk.Visible   = $false
$form.Controls.Add($lblAsk)

$txtNote = New-Object Windows.Forms.TextBox
$txtNote.Location    = New-Object Drawing.Point(14, 44)
$txtNote.Size        = New-Object Drawing.Size(268, 26)
$txtNote.BorderStyle = 'FixedSingle'
$txtNote.BackColor   = $C_SOFT
$txtNote.ForeColor   = $C_TEXT
$txtNote.Font        = New-Object Drawing.Font('Segoe UI', 10)
$txtNote.MaxLength   = 160
$txtNote.Visible     = $false
$form.Controls.Add($txtNote)

$btnNoteOk   = New-FlatButton 'Сохранить'  14 86 134 28 $C_GO   $C_TEXT 10
$btnNoteSkip = New-FlatButton 'Пропустить' 154 86 128 28 $C_SOFT $C_DIM  9.5
$btnNoteOk.Visible = $false; $btnNoteSkip.Visible = $false
$form.Controls.Add($btnNoteOk)
$form.Controls.Add($btnNoteSkip)

# --- перетаскивание + прилипание к углам ---------------------------
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
    $script:Drag = $false
    # если бросили рядом с углом — прилипнуть к нему
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $L = $form.Location.X; $T = $form.Location.Y
    $R = $L + $W;          $B = $T + $H
    $snap = 110
    $near = ''
    if ([math]::Abs($L - $wa.Left) -lt $snap -and [math]::Abs($T - $wa.Top) -lt $snap)       { $near = 'tl' }
    elseif ([math]::Abs($R - $wa.Right) -lt $snap -and [math]::Abs($T - $wa.Top) -lt $snap)  { $near = 'tr' }
    elseif ([math]::Abs($L - $wa.Left) -lt $snap -and [math]::Abs($B - $wa.Bottom) -lt $snap){ $near = 'bl' }
    elseif ([math]::Abs($R - $wa.Right) -lt $snap -and [math]::Abs($B - $wa.Bottom) -lt $snap){ $near = 'br' }

    $script:Corner = $near
    if ($near) { $form.Location = Corner-Point $near }
    $script:WinPos = @{ x = $form.Location.X; y = $form.Location.Y }
    Save-Data
  }
}
foreach ($c in @($form, $lblTime, $lblToday)) {
  $c.add_MouseDown($onDown)
  $c.add_MouseMove($onMove)
  $c.add_MouseUp($onUp)
}

# --- переключение режимов ------------------------------------------
function Show-NormalMode {
  $script:NoteMode = $false
  foreach ($c in @($combo, $btnAdd, $btnClose, $lblTime, $lblToday, $btnToggle, $btnSummary)) { $c.Visible = $true }
  foreach ($c in @($lblAsk, $txtNote, $btnNoteOk, $btnNoteSkip)) { $c.Visible = $false }
  Update-Ui
}

function Show-NoteMode([string]$prompt) {
  $script:NoteMode = $true
  foreach ($c in @($combo, $btnAdd, $btnClose, $lblTime, $lblToday, $btnToggle, $btnSummary)) { $c.Visible = $false }
  $lblAsk.Text = $prompt
  $txtNote.Text = ''
  foreach ($c in @($lblAsk, $txtNote, $btnNoteOk, $btnNoteSkip)) { $c.Visible = $true }
  $txtNote.Focus()
}

# --- отправка на GitHub ---------------------------------------------
function Push-Remote {
  if (-not (Test-Path $SyncCmd)) { return }
  if (-not (Test-Path (Join-Path $Root '.git'))) { return }
  try {
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('"' + $SyncCmd + '"') -WindowStyle Hidden | Out-Null
  } catch { }
}

# --- логика ----------------------------------------------------------
function Update-Ui {
  if ($script:NoteMode) { return }
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

function Start-Tracking($project) {
  if (-not $project) { return }
  $script:Current = @{ project = [string]$project; start = Get-Date }
  Save-Data
  Update-Ui
}

function Stop-Tracking([bool]$askNote = $true) {
  if (-not $script:Current) { return }
  $st  = $script:Current.start
  $en  = Get-Date
  $sec = [int][math]::Round(($en - $st).TotalSeconds)
  $proj = $script:Current.project
  $script:Current = $null

  if ($sec -ge 5) {
    [void]$script:Sessions.Add(@{
      project = $proj
      start   = $st.ToString('o')
      end     = $en.ToString('o')
      seconds = $sec
      note    = ''
    })
    Save-Data
    if ($askNote -and $form.Visible) {
      Show-NoteMode ("{0} · {1} — что делала?" -f $proj, (Fmt-Short $sec))
      return
    }
    Push-Remote
  } else {
    Save-Data
  }
  Update-Ui
}

function Save-Note {
  $txt = "$($txtNote.Text)".Trim()
  if ($txt -and $script:Sessions.Count -gt 0) {
    $script:Sessions[$script:Sessions.Count - 1].note = $txt
    Save-Data
  }
  Show-NormalMode
  Push-Remote
}

function Toggle-Timer {
  if ($script:NoteMode) { return }
  if ($script:Current) { Stop-Tracking $true } else { Start-Tracking $combo.SelectedItem }
}

$btnToggle.add_Click({ Toggle-Timer })
$btnNoteOk.add_Click({ Save-Note })
$btnNoteSkip.add_Click({ Show-NormalMode; Push-Remote })

$txtNote.add_KeyDown({
  if ($_.KeyCode -eq 'Enter')  { $_.SuppressKeyPress = $true; Save-Note }
  if ($_.KeyCode -eq 'Escape') { $_.SuppressKeyPress = $true; Show-NormalMode; Push-Remote }
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

# --- контекстное меню -------------------------------------------------
$menu = New-Object Windows.Forms.ContextMenuStrip

$miNote = $menu.Items.Add('Заметка к последней сессии…')
$miNote.add_Click({
  if ($script:Sessions.Count -eq 0) { return }
  $last = $script:Sessions[$script:Sessions.Count - 1]
  $txt = [Microsoft.VisualBasic.Interaction]::InputBox(
    ("{0} · {1}" -f $last.project, (Fmt-Short $last.seconds)), 'Заметка', [string]$last.note)
  if ($null -ne $txt) {
    $last.note = "$txt".Trim()
    Save-Data
    Push-Remote
  }
})

$miCorner = New-Object Windows.Forms.ToolStripMenuItem('Прикрепить к углу')
foreach ($pair in @(@('tl','Верхний левый'), @('tr','Верхний правый'), @('bl','Нижний левый'), @('br','Нижний правый'), @('','Свободно'))) {
  $code = $pair[0]
  $item = $miCorner.DropDownItems.Add($pair[1])
  $item.Tag = $code
  $item.add_Click({
    $script:Corner = [string]$this.Tag
    if ($script:Corner) { $form.Location = Corner-Point $script:Corner }
    $script:WinPos = @{ x = $form.Location.X; y = $form.Location.Y }
    Save-Data
  })
}
[void]$menu.Items.Add($miCorner)

$miDelete = $menu.Items.Add('Убрать проект из списка')
$miDelete.add_Click({
  if ($script:Current -or $script:NoteMode) { return }
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

# --- глобальные горячие клавиши ---------------------------------------
$script:Hk = New-Object GlobalHotkeys
[void]$script:Hk.Register(1, 3, 0x53)   # Ctrl+Alt+S
[void]$script:Hk.Register(2, 3, 0x54)   # Ctrl+Alt+T
$script:Hk.add_Pressed({
  param($sender, $id)
  if ($id -eq 1) {
    if (-not $form.Visible) { $form.Show() }
    Toggle-Timer
  } elseif ($id -eq 2) {
    if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.Activate() }
  }
})

# --- тики --------------------------------------------------------------
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
  Stop-Tracking $false
  $tick.Stop()
  $autosave.Stop()
  try { $script:Hk.Dispose() } catch { }
})

Show-NormalMode
Save-Data
[Windows.Forms.Application]::Run($form)
try { $script:Mutex.ReleaseMutex() } catch { }
