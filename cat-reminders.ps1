# ================= Cat Reminder Hub =================
# A cat in your system tray. Add reminders in two flavors:
#   1) Repeating  - nag me every X minutes (e.g. drink water every 60)
#   2) One time   - pop up once, either "in X minutes" or "at 17:30"
# One-time reminders vanish after they fire.
# Put a picture of the cat as "cat.png" next to this script.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:remindersFile = Join-Path $dir "reminders.json"
$script:catImage = Join-Path $dir "cat.png"
$script:autoCloseSeconds = 300   # popup auto-closes after 5 minutes if ignored
$script:allowClose = $false

# single-instance guard: only one cat may be on duty
$script:catMutex = New-Object System.Threading.Mutex($false, "Local\CatRemindersOnDuty")
if (!$script:catMutex.WaitOne(0)) {
    $script:catMutex.Dispose()
    exit
}

# this app is 99% idle - run at below-normal priority so it never competes
try { (Get-Process -Id $PID).PriorityClass = "BelowNormal" } catch { }

# cat flavor lines - shown in the bubble under the reminder message
$script:flavors = @(
    "Pspsps... drink your water, hooman!",
    "Free lap if you hydrate. I keep my word.",
    "Water break! The cat has spoken.",
    "Sip. Sip. Purr. Repeat.",
    "Doctor cat prescribes: one glass of water.",
    "Your body is 70% water. Top it up!",
    "The bowl is empty... yours, not mine.",
    "You, hydrating = purrfect combo.",
    "Mandatory splash time \_/",
    "Meow. Fluid maintenance, STAT."
)
$script:quietUntil = $null

# ---------- storage ----------
function Save-Reminders {
    if (@($script:reminders).Count -eq 0) {
        "[]" | Set-Content -Path $script:remindersFile -Encoding UTF8
    } else {
        ConvertTo-Json -InputObject @($script:reminders) -Depth 5 |
            Set-Content -Path $script:remindersFile -Encoding UTF8
    }
}

function Load-Reminders {
    if (!(Test-Path $script:remindersFile)) {
        $default = @([pscustomobject]@{
            Type = "repeat"
            Message = "Drink some water! Stay hydrated \_/_"
            IntervalMinutes = 60
            LastShown = $null
            FireAt = $null
        })
        ConvertTo-Json -InputObject $default | Set-Content -Path $script:remindersFile -Encoding UTF8
    }
    $raw = Get-Content $script:remindersFile -Raw
    $loaded = ConvertFrom-Json $raw
    $script:reminders = @($loaded)
}

function Get-RemType($r) {
    if ($r.PSObject.Properties.Name -contains "Type") { return $r.Type }
    return "repeat"   # old reminders, before this upgrade
}

# ---------- cat image prep ----------
# Removes the baked-in checkerboard background (flood fill from borders),
# removes small light islands left inside, and crops tight around the cat.
# Uses the precompiled catproc.dll (fast boot); falls back to inline compile only if missing.
$script:log = { param($m) }
& $script:log "=== $(Get-Date -Format HH:mm:ss) launch ==="
$dllPath = Join-Path $dir "catproc.dll"
if (Test-Path $dllPath) {
    try { [void][System.Reflection.Assembly]::LoadFrom($dllPath) } catch { }
}
if (!("CatProc" -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class CatProc {
    public static Bitmap ProcessCat(byte[] pngBytes) {
        // GDI+ reads lazily from the stream - keep it alive and deep-copy the pixels
        var ms = new MemoryStream(pngBytes);
        var tmp = new Bitmap(ms);
        var src = new Bitmap(tmp);
        tmp.Dispose();
        int w = src.Width, h = src.Height;
        var rect = new Rectangle(0, 0, w, h);
        var bd = src.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        var buf = new byte[bd.Stride * h];
        Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
        src.UnlockBits(bd);

        // pass 1: flood fill from borders - remove transparent or near-neutral-light pixels
        var stack = new Stack<int>();
        Func<int, bool> isBg = idx => {
            int o = idx * 4;
            if (buf[o + 3] <= 24) return true;
            int r = buf[o], g = buf[o + 1], b = buf[o + 2];
            int hi = Math.Max(r, Math.Max(g, b));
            int lo = Math.Min(r, Math.Min(g, b));
            return hi >= 225 && (hi - lo) <= 10;
        };
        Action<int> push = idx => { buf[idx * 4 + 3] = 0; stack.Push(idx); };
        for (int x = 0; x < w; x++) { if (isBg(x)) push(x); int i2 = (h - 1) * w + x; if (isBg(i2)) push(i2); }
        for (int y = 0; y < h; y++) { int i1 = y * w; if (isBg(i1)) push(i1); int i2 = y * w + w - 1; if (isBg(i2)) push(i2); }
        while (stack.Count > 0) {
            int i = stack.Pop(); int x = i % w; int y = i / w;
            if (x > 0) { int n = i - 1; if (buf[n * 4 + 3] > 24 && isBg(n)) push(n); }
            if (x < w - 1) { int n = i + 1; if (buf[n * 4 + 3] > 24 && isBg(n)) push(n); }
            if (y > 0) { int n = i - w; if (buf[n * 4 + 3] > 24 && isBg(n)) push(n); }
            if (y < h - 1) { int n = i + w; if (buf[n * 4 + 3] > 24 && isBg(n)) push(n); }
        }

        // pass 2: remove small isolated light islands (checker squares stuck inside the fur)
        var comp = new int[w * h];
        for (int i = 0; i < comp.Length; i++) comp[i] = -1;
        var sizes = new List<int>();
        for (int start = 0; start < w * h; start++) {
            int o = start * 4;
            if (buf[o + 3] <= 24 || comp[start] >= 0) continue;
            int r = buf[o], g = buf[o + 1], b = buf[o + 2];
            int hi = Math.Max(r, Math.Max(g, b)); int lo = Math.Min(r, Math.Min(g, b));
            if (!(hi >= 225 && (hi - lo) <= 10)) continue;
            int id = sizes.Count; int cnt = 0;
            var s2 = new Stack<int>(); s2.Push(start); comp[start] = id;
            while (s2.Count > 0) {
                int i = s2.Pop(); cnt++; int x = i % w; int y = i / w;
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    if (dx == 0 && dy == 0) continue;
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    int j = ny * w + nx; int oj = j * 4;
                    if (buf[oj + 3] <= 24 || comp[j] >= 0) continue;
                    int rj = buf[oj], gj = buf[oj + 1], bj = buf[oj + 2];
                    int hj = Math.Max(rj, Math.Max(gj, bj)); int lj = Math.Min(rj, Math.Min(gj, bj));
                    if (!(hj >= 225 && (hj - lj) <= 10)) continue;
                    comp[j] = id; s2.Push(j);
                }
            }
            sizes.Add(cnt);
        }
        for (int i = 0; i < w * h; i++) {
            int o = i * 4;
            if (buf[o + 3] > 24 && comp[i] >= 0 && sizes[comp[i]] < 4000) buf[o + 3] = 0;
        }

        // bounding box of kept content
        int minX = w, minY = h, maxX = -1, maxY = -1;
        for (int y = 0; y < h; y++) {
            int row = y * w;
            for (int x = 0; x < w; x++) {
                if (buf[(row + x) * 4 + 3] > 24) {
                    if (x < minX) minX = x; if (x > maxX) maxX = x;
                    if (y < minY) minY = y; if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < 0) { minX = 0; minY = 0; maxX = w - 1; maxY = h - 1; }

        var bd2 = src.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        Marshal.Copy(buf, 0, bd2.Scan0, buf.Length);
        src.UnlockBits(bd2);

        int m = 6;
        int cx = Math.Max(0, minX - m), cy = Math.Max(0, minY - m);
        int cw = Math.Min(w - cx, (maxX - minX) + 1 + 2 * m);
        int ch2 = Math.Min(h - cy, (maxY - minY) + 1 + 2 * m);
        var res = src.Clone(new Rectangle(cx, cy, cw, ch2), PixelFormat.Format32bppArgb);
        src.Dispose();
        return res;
    }

    [DllImport("kernel32.dll")]
    public static extern bool SetProcessWorkingSetSize(IntPtr proc, int min, int max);

    // asks Windows to page out everything unused - keeps the resident footprint tiny
    public static void TrimMemory() {
        try {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            SetProcessWorkingSetSize(System.Diagnostics.Process.GetCurrentProcess().Handle, -1, -1);
        } catch { }
    }
}
'@ -ReferencedAssemblies System.Drawing
}
& $script:log "csharp compiled"

function Get-SafeBitmap([string]$path) {
    # file/stream-independent bitmap copy (avoids GDI+ lazy-loading pitfalls)
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $ms = New-Object System.IO.MemoryStream (,$bytes)
    $tmp = New-Object System.Drawing.Bitmap($ms)
    $copy = New-Object System.Drawing.Bitmap($tmp)
    $tmp.Dispose()
    $ms.Dispose()
    return $copy
}

function Get-CatCutBitmap {
    # transparent, background-free cat; cached next to the script as cat_cut.png
    if ($script:catCutBitmap) { return $script:catCutBitmap }
    if (!(Test-Path $script:catImage)) { return $null }
    $cache = Join-Path $dir "cat_cut.png"
    if ((Test-Path $cache) -and ((Get-Item $cache).LastWriteTime -ge (Get-Item $script:catImage).LastWriteTime)) {
        $script:catCutBitmap = Get-SafeBitmap $cache
        & $script:log "cat bitmap loaded from cache"
        return $script:catCutBitmap
    }
    $cut = [CatProc]::ProcessCat([System.IO.File]::ReadAllBytes($script:catImage))
    $cut.Save($cache, [System.Drawing.Imaging.ImageFormat]::Png)
    $script:catCutBitmap = $cut
    & $script:log "cat bitmap freshly processed"
    return $script:catCutBitmap
}

# ---------- the popup (floating cat + speech bubble, no window box) ----------
function New-BubblePath($rect, $r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $r, $r, 180, 90)
    $path.AddArc($rect.Right - $r - 1, $rect.Y, $r, $r, 270, 90)
    $path.AddArc($rect.Right - $r - 1, $rect.Bottom - $r - 1, $r, $r, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $r - 1, $r, $r, 90, 90)
    $path.CloseFigure()
    return $path
}

function Show-CatPopup([string]$Message, $Rem = $null) {
    $cut = Get-CatCutBitmap
    $flavor = @(Get-Random -InputObject $script:flavors)[0]
    # remember panel visibility - dismissing the popup must not resurrect the panel
    $panelWasVisible = $false
    if ($script:form) { $panelWasVisible = $script:form.Visible }

    $W = 420; $H = 575
    $catX = 10; $catY = 140; $catW = 400; $catH = 420

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Your cat says..."
    $form.Size = New-Object System.Drawing.Size($W, $H)
    $form.StartPosition = "Manual"
    $form.Location = New-Object System.Drawing.Point(
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width - $W - 10),
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - $H - 10))
    $form.TopMost = $true
    $form.FormBorderStyle = "None"
    $form.ShowInTaskbar = $false

    # magic color: anything painted in this color is invisible AND click-through
    $key = [System.Drawing.Color]::FromArgb(255, 0, 255)
    $form.BackColor = $key
    $form.TransparencyKey = $key

    # double-buffer the popup: the per-second countdown repaint must not blink
    $form.GetType().GetProperty("DoubleBuffered").SetValue($form, $true, $null)

    # speech bubble colors (Material You, soft lavender)
    $bubbleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(232, 222, 248))
    $linePen     = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(199, 183, 236), 1.5)
    $textColor   = [System.Drawing.Color]::FromArgb(74, 68, 88)
    $hintColor   = [System.Drawing.Color]::FromArgb(125, 115, 140)
    $msgFont     = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $hintFont    = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)

    # live state shared with the paint handler
    $hud = @{ countdown = 0; counting = $false; ack = $null; hintRect = (New-Object System.Drawing.Rectangle(32, 80, 356, 16)) }

    $form.Add_Paint({
        $g = $_.Graphics
        $g.SmoothingMode = "AntiAlias"
        $rect = New-Object System.Drawing.Rectangle(14, 6, 392, 96)
        $path = New-BubblePath $rect 18
        $g.FillPath($bubbleBrush, $path)
        $g.DrawPath($linePen, $path)
        # tail pointing at the cat's head
        $tail = New-Object 'System.Drawing.PointF[]' 3
        $tail[0] = New-Object System.Drawing.PointF([single]170, [single]100)
        $tail[1] = New-Object System.Drawing.PointF([single]254, [single]100)
        $tail[2] = New-Object System.Drawing.PointF([single]215, [single]146)
        $g.FillPolygon($bubbleBrush, $tail)

        $msgRect = New-Object System.Drawing.Rectangle(32, 16, 356, 58)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $Message, $msgFont, $msgRect, $textColor,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))

        $hint = $flavor
        if ($hud.ack) { $hint = $hud.ack }
        elseif ($hud.counting) { $hint = "closing in $($hud.countdown)s..." }
        $hintRect = New-Object System.Drawing.Rectangle(32, 80, 356, 16)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $hint, $hintFont, $hintRect, $hintColor,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine))
    })

    # --- the cat, huge and crisp ---
    if ($cut) {
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Image = $cut
        $pb.SizeMode = "Zoom"
        $pb.BackColor = $key   # invisible + click-through around the cat
        $pb.Size = New-Object System.Drawing.Size($catW, $catH)
        $pb.Location = New-Object System.Drawing.Point($catX, $catY)
        $pb.Cursor = "Hand"
        $form.Controls.Add($pb)
    } else {
        # ASCII fallback until a picture exists
        $ascii = New-Object System.Windows.Forms.Label
        $ascii.Text = "   /\_/\`n  ( o.o )`n   > ^ <"
        $ascii.Font = New-Object System.Drawing.Font("Consolas", 26)
        $ascii.AutoSize = $true
        $ascii.Location = New-Object System.Drawing.Point(150, 200)
        $ascii.Cursor = "Hand"
        $form.Controls.Add($ascii)
        $cat = $ascii
    }

    # -- dismissal --
    if ($cut) { $target = $pb } else { $target = $ascii }

    $hover = New-Object System.Windows.Forms.Timer
    $hover.Interval = 1000
    $hover.Add_Tick({
        if ($hud.counting) {
            $hud.countdown--
            & $script:log "countdown tick -> $($hud.countdown)"
            if ($hud.countdown -le 0) { $form.Close() } else { $form.Invalidate($hud.hintRect) }
        }
    })

    $target.Add_MouseEnter({
        # first touch starts the countdown; re-touching does NOT reset it
        if (!$hud.counting) {
            $hud.countdown = 10
            $hud.counting = $true
            $hover.Start()
            $form.Invalidate($hud.hintRect)
        }
    })

    $target.Add_MouseClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $hud.counting = $false
            $hover.Stop()
            $form.Close()
        }
        elseif ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            # right-click = snooze this reminder by 10 minutes
            if ($Rem) {
                if ((Get-RemType $Rem) -eq "once") {
                    $Rem.FireAt = (Get-Date).AddMinutes(10).ToString("o")
                } else {
                    $dur = [Math]::Min(10, $Rem.IntervalMinutes)
                    $Rem.LastShown = (Get-Date).AddMinutes(-($Rem.IntervalMinutes - $dur)).ToString("o")
                }
                Save-Reminders
                Update-ListView
                $hud.ack = "Snoozed for 10 minutes, meow."
            } else {
                $hud.ack = "Nothing to snooze - just vibes."
            }
            $hud.counting = $false
            $hover.Stop()
            $form.Invalidate($hud.hintRect)
            $script:popupAckTimer = New-Object System.Windows.Forms.Timer
            $script:popupAckTimer.Interval = 1800
            $script:popupAckTimer.Add_Tick({ $script:popupAckTimer.Stop(); $form.Close() })
            $script:popupAckTimer.Start()
        }
    })

    # double-click = quiet mode for one hour
    $quietHandler = {
        $script:quietUntil = (Get-Date).AddHours(1)
        try {
            $tray.BalloonTipTitle = "Cat Reminders"
            $tray.BalloonTipText = "Quiet for 1 hour. Zzz. (tray icon > Open reminder panel to check)"
            $tray.ShowBalloonTip(3000)
        } catch { }
        $form.Close()
    }
    $target.Add_DoubleClick($quietHandler)

    # clicking the bubble closes too
    $form.Add_MouseClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $hud.counting = $false
            $hover.Stop()
            $form.Close()
        }
    })
    $form.Add_DoubleClick($quietHandler)

    $form.Add_FormClosing({
        & $script:log "popup closing, reason: $($_.CloseReason)"
    })

    $form.Add_Shown({ $form.Activate() })
    $form.KeyPreview = $true
    $form.Add_KeyDown({ if ($_.KeyCode -eq "Enter") { $hover.Stop(); $form.Close() } })

    # safety net: auto-close after 5 minutes of being ignored
    $safety = New-Object System.Windows.Forms.Timer
    $safety.Interval = ($script:autoCloseSeconds * 1000)
    $safety.Add_Tick({ $form.Close() })
    $safety.Start()

    # purr: use a real meow if you drop one as "meow.wav" next to the script
    try {
        $meowFile = Join-Path $dir "meow.wav"
        if (Test-Path $meowFile) {
            $meow = New-Object System.Media.SoundPlayer($meowFile)
            $meow.Play()
        } else {
            [System.Media.SystemSounds]::Exclamation.Play()
        }
    } catch { try { [System.Media.SystemSounds]::Exclamation.Play() } catch {} }

    [void]$form.ShowDialog()
    $hud.counting = $false
    $hover.Stop()
    $hover.Dispose()
    $safety.Stop()
    $safety.Dispose()
    if ($script:popupAckTimer) {
        $script:popupAckTimer.Stop()
        $script:popupAckTimer.Dispose()
        $script:popupAckTimer = $null
    }

    # popup dismissal returns focus to the appartment's main window - undo that
    # unless you had the panel open yourself
    if (!$panelWasVisible) { $script:form.Hide() }

    # the popup owned big bitmaps - hand the memory back
    try { [CatProc]::TrimMemory() } catch { }
}

# ---------- reminder engine ----------
function Update-ListView {
    $lv.Items.Clear()
    $now = Get-Date
    foreach ($r in $script:reminders) {
        if ((Get-RemType $r) -eq "once") {
            $fire = [datetime]$r.FireAt
            $nextText = if ($fire -le $now) { "due now!" } else { $fire.ToString("HH:mm") }
            $pattern = "one-time"
        } else {
            $last = [datetime]::MinValue
            if ($r.LastShown) { $last = [datetime]$r.LastShown }
            $next = $last.AddMinutes($r.IntervalMinutes)
            if ($last -eq [datetime]::MinValue) { $nextText = "on next check" }
            elseif ($next -le $now) { $nextText = "due now!" }
            else { $nextText = $next.ToString("HH:mm") }
            $pattern = "every $($r.IntervalMinutes) min"
        }
        $item = New-Object System.Windows.Forms.ListViewItem($r.Message)
        [void]$item.SubItems.Add($pattern)
        [void]$item.SubItems.Add($nextText)
        [void]$lv.Items.Add($item)
    }
}

function Check-Reminders {
    $now = Get-Date
    # quiet mode: no popups for a while (double-click the cat to activate)
    if ($script:quietUntil -and $now -lt $script:quietUntil) { Update-ListView; return }
    $changed = $false
    $keep = @()
    foreach ($r in $script:reminders) {
        if ((Get-RemType $r) -eq "once") {
            # one-time: fire once, then disappear
            if ($now -ge [datetime]$r.FireAt) {
                Show-CatPopup $r.Message $r
                $changed = $true   # dropped, not kept
            } else {
                $keep += $r
            }
        } else {
            # repeating: fire every IntervalMinutes
            $last = [datetime]::MinValue
            if ($r.LastShown) { $last = [datetime]$r.LastShown }
            if (($now - $last).TotalMinutes -ge $r.IntervalMinutes) {
                $r.LastShown = $now.ToString("o")
                $changed = $true
                Show-CatPopup $r.Message $r
            }
            $keep += $r
        }
    }
    $script:reminders = $keep
    if ($changed) { Save-Reminders }
    Update-ListView
}

# ---------- load ----------
Load-Reminders
& $script:log "reminders loaded: $(@($script:reminders).Count)"

# ---------- control panel ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Cat Reminders"
$form.Size = New-Object System.Drawing.Size(470, 540)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.ShowInTaskbar = $false

# reminder list
$lvLabel = New-Object System.Windows.Forms.Label
$lvLabel.Text = "Active reminders:"
$lvLabel.AutoSize = $true
$lvLabel.Location = New-Object System.Drawing.Point(12, 10)
$form.Controls.Add($lvLabel)

$lv = New-Object System.Windows.Forms.ListView
$lv.View = "Details"
$lv.FullRowSelect = $true
$lv.HideSelection = $true
$lv.Size = New-Object System.Drawing.Size(432, 130)
$lv.Location = New-Object System.Drawing.Point(12, 32)
[void]$lv.Columns.Add("Message", 220)
[void]$lv.Columns.Add("Pattern", 100)
[void]$lv.Columns.Add("Next", 100)
$form.Controls.Add($lv)

# add reminder group
$group = New-Object System.Windows.Forms.GroupBox
$group.Text = "Add a reminder"
$group.Size = New-Object System.Drawing.Size(432, 230)
$group.Location = New-Object System.Drawing.Point(12, 172)
$form.Controls.Add($group)

$msgLabel = New-Object System.Windows.Forms.Label
$msgLabel.Text = "What should the cat say?"
$msgLabel.AutoSize = $true
$msgLabel.Location = New-Object System.Drawing.Point(15, 18)
$group.Controls.Add($msgLabel)

$txtMessage = New-Object System.Windows.Forms.TextBox
$txtMessage.Multiline = $true
$txtMessage.Size = New-Object System.Drawing.Size(400, 45)
$txtMessage.Location = New-Object System.Drawing.Point(15, 36)
$group.Controls.Add($txtMessage)

# mode: repeating
$rbRepeat = New-Object System.Windows.Forms.RadioButton
$rbRepeat.Text = "Repeat: every"
$rbRepeat.AutoSize = $true
$rbRepeat.Location = New-Object System.Drawing.Point(15, 92)
$rbRepeat.Checked = $true
$group.Controls.Add($rbRepeat)

$numRepeat = New-Object System.Windows.Forms.NumericUpDown
$numRepeat.Minimum = 1
$numRepeat.Maximum = 100000
$numRepeat.Value = 60
$numRepeat.Size = New-Object System.Drawing.Size(62, 25)
$numRepeat.Location = New-Object System.Drawing.Point(113, 88)
$group.Controls.Add($numRepeat)

$lblRepeat = New-Object System.Windows.Forms.Label
$lblRepeat.Text = "minutes"
$lblRepeat.AutoSize = $true
$lblRepeat.Location = New-Object System.Drawing.Point(180, 92)
$group.Controls.Add($lblRepeat)

# mode: one time, in X minutes
$rbOnceIn = New-Object System.Windows.Forms.RadioButton
$rbOnceIn.Text = "One time: in"
$rbOnceIn.AutoSize = $true
$rbOnceIn.Location = New-Object System.Drawing.Point(15, 122)
$group.Controls.Add($rbOnceIn)

$numOnce = New-Object System.Windows.Forms.NumericUpDown
$numOnce.Minimum = 1
$numOnce.Maximum = 100000
$numOnce.Value = 30
$numOnce.Size = New-Object System.Drawing.Size(62, 25)
$numOnce.Location = New-Object System.Drawing.Point(113, 118)
$group.Controls.Add($numOnce)

$lblOnceIn = New-Object System.Windows.Forms.Label
$lblOnceIn.Text = "minutes from now"
$lblOnceIn.AutoSize = $true
$lblOnceIn.Location = New-Object System.Drawing.Point(180, 122)
$group.Controls.Add($lblOnceIn)

# mode: one time, at a clock time
$rbOnceAt = New-Object System.Windows.Forms.RadioButton
$rbOnceAt.Text = "One time: at"
$rbOnceAt.AutoSize = $true
$rbOnceAt.Location = New-Object System.Drawing.Point(15, 152)
$group.Controls.Add($rbOnceAt)

$timePicker = New-Object System.Windows.Forms.DateTimePicker
$timePicker.Format = "Time"
$timePicker.ShowUpDown = $true
$timePicker.Size = New-Object System.Drawing.Size(90, 25)
$timePicker.Location = New-Object System.Drawing.Point(113, 148)
$timePicker.Value = (Get-Date).AddHours(1)
$group.Controls.Add($timePicker)

$lblOnceAt = New-Object System.Windows.Forms.Label
$lblOnceAt.Text = "(tomorrow if that time already passed)"
$lblOnceAt.AutoSize = $true
$lblOnceAt.ForeColor = [System.Drawing.Color]::Gray
$lblOnceAt.Location = New-Object System.Drawing.Point(210, 152)
$group.Controls.Add($lblOnceAt)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = "Add reminder"
$btnAdd.Size = New-Object System.Drawing.Size(150, 32)
$btnAdd.Location = New-Object System.Drawing.Point(15, 188)
$btnAdd.BackColor = [System.Drawing.Color]::FromArgb(103, 80, 164)
$btnAdd.ForeColor = [System.Drawing.Color]::White
$btnAdd.FlatStyle = "Flat"
$btnAdd.FlatAppearance.BorderSize = 0
$group.Controls.Add($btnAdd)

# preview button: opens the cat popup on demand
$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = "Show the cat now"
$btnPreview.Size = New-Object System.Drawing.Size(150, 32)
$btnPreview.Location = New-Object System.Drawing.Point(180, 188)
$btnPreview.FlatStyle = "Flat"
$btnPreview.FlatAppearance.BorderSize = 0
$group.Controls.Add($btnPreview)

# delete button
$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete selected"
$btnDelete.Size = New-Object System.Drawing.Size(140, 32)
$btnDelete.Location = New-Object System.Drawing.Point(12, 412)
$btnDelete.FlatStyle = "Flat"
$form.Controls.Add($btnDelete)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "One-time reminders disappear after they fire.`nClosing this window keeps the cat in the tray -`ndouble-click the tray icon to reopen."
$hint.ForeColor = [System.Drawing.Color]::Gray
$hint.AutoSize = $false
$hint.Size = New-Object System.Drawing.Size(280, 45)
$hint.Location = New-Object System.Drawing.Point(165, 408)
$form.Controls.Add($hint)

# ---------- tray icon ----------
$script:trayIcon = $null
try {
    $icoSrc = Get-CatCutBitmap
    if ($icoSrc) {
        # scale down to tray size first - GetHicon on the full-size bitmap is wasteful
        $ico32 = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($ico32)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($icoSrc, 0, 0, 32, 32)
        $g.Dispose()
        $script:trayIcon = [System.Drawing.Icon]::FromHandle($ico32.GetHicon())
    }
} catch { $script:trayIcon = $null }

$tray = New-Object System.Windows.Forms.NotifyIcon
if ($script:trayIcon) { $tray.Icon = $script:trayIcon }
$tray.Text = "Cat Reminders - on duty"
$tray.Visible = $true
& $script:log "tray icon created"

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Open reminder panel", $null, { $form.Show(); $form.Activate() })
[void]$menu.Items.Add("Show the cat now", $null, { Show-CatPopup "Miau! Right meow? Anything you added will look like this." })
[void]$menu.Items.Add("Exit (fire the cat)", $null, {
    $script:allowClose = $true
    $tray.Visible = $false
    $form.Close()
})
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })

# ---------- events ----------
# enable only the controls for the chosen mode
function Sync-ModeControls {
    $numRepeat.Enabled = $rbRepeat.Checked
    $numOnce.Enabled = $rbOnceIn.Checked
    $timePicker.Enabled = $rbOnceAt.Checked
}
foreach ($rb in @($rbRepeat, $rbOnceIn, $rbOnceAt)) {
    $rb.Add_CheckedChanged({ Sync-ModeControls })
}
Sync-ModeControls

$btnAdd.Add_Click({
    $text = $txtMessage.Text.Trim()
    if (!$text) { $text = "Psst... time for your reminder!" }

    if ($rbRepeat.Checked) {
        $script:reminders += [pscustomobject]@{
            Type = "repeat"
            Message = $text
            IntervalMinutes = [int]$numRepeat.Value
            LastShown = $null
            FireAt = $null
        }
    } elseif ($rbOnceIn.Checked) {
        $script:reminders += [pscustomobject]@{
            Type = "once"
            Message = $text
            IntervalMinutes = $null
            LastShown = $null
            FireAt = (Get-Date).AddMinutes([int]$numOnce.Value).ToString("o")
        }
    } else {
        # clock time: today, or tomorrow if it already passed
        $fire = (Get-Date).Date.Add($timePicker.Value.TimeOfDay)
        if ($fire -le (Get-Date)) { $fire = $fire.AddDays(1) }
        $script:reminders += [pscustomobject]@{
            Type = "once"
            Message = $text
            IntervalMinutes = $null
            LastShown = $null
            FireAt = $fire.ToString("o")
        }
    }
    Save-Reminders
    Update-ListView
    $txtMessage.Clear()
})

$btnPreview.Add_Click({
    Show-CatPopup "Miau! This is what a reminder looks like. Meow meow."
})

$btnDelete.Add_Click({
    if ($lv.SelectedItems.Count -gt 0) {
        $idx = $lv.SelectedItems[0].Index
        $newList = @()
        for ($i = 0; $i -lt $script:reminders.Count; $i++) {
            if ($i -ne $idx) { $newList += $script:reminders[$i] }
        }
        $script:reminders = $newList
        Save-Reminders
        Update-ListView
    }
})

# closing the panel hides it (cat keeps working)
$form.Add_FormClosing({
    if (!$script:allowClose) {
        $_.Cancel = $true
        $form.Hide()
    }
})

# ---------- timers ----------
$checkTimer = New-Object System.Windows.Forms.Timer
$checkTimer.Interval = 15000   # check every 15 seconds if something is due
$checkTimer.Add_Tick({ Check-Reminders })

$startupTimer = New-Object System.Windows.Forms.Timer
$startupTimer.Interval = 1500  # show the cat once shortly after launch
$startupTimer.Add_Tick({
    $startupTimer.Stop()
    Check-Reminders
})

$form.Add_Shown({
    & $script:log "form shown"
    $form.Activate()
    Update-ListView
    $checkTimer.Start()
    $startupTimer.Start()
    try {
        $tray.BalloonTipTitle = "Cat Reminders"
        $tray.BalloonTipText = "The cat icon lives next to your clock (you may need to click ^ to see it). Double-click it anytime!"
        $tray.ShowBalloonTip(6000)
    } catch {}
})

if ($script:trayIcon) { $form.Icon = $script:trayIcon }

# everything is loaded now - trim what isn't needed
try { [CatProc]::TrimMemory() } catch { }

# the UI pages some memory back while showing - trim once more after it settles
$trimTimer = New-Object System.Windows.Forms.Timer
$trimTimer.Interval = 60000
$trimTimer.Add_Tick({
    $trimTimer.Stop()
    try { [CatProc]::TrimMemory() } catch { }
})
$trimTimer.Start()

& $script:log "calling Application.Run"

# ---------- run ----------
[System.Windows.Forms.Application]::Run($form)
& $script:log "Application.Run returned"

# cleanup when exiting
$checkTimer.Stop()
$tray.Visible = $false
$tray.Dispose()
