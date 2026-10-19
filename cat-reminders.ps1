# ================= Cat Reminder Hub =================
# A cat in your system tray. Add reminders in two flavors:
#   1) Repeating  - nag me every X minutes (e.g. drink water every 60)
#   2) One time   - pop up once, either "in X minutes" or "at 17:30"
# One-time reminders vanish after they fire.
# Put a picture of the cat as "cat.png" next to this script.

param([switch]$ShowPanel)   # start with the panel open (screenshots/debugging)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:remindersFile = Join-Path $dir "reminders.json"
$script:settingsFile = Join-Path $dir "settings.json"
$script:catImage = Join-Path $dir "cat.png"
$script:catsDir = Join-Path $dir "cats"   # extra cat pictures: drop any number here
$script:meowsDir = Join-Path $dir "meows" # extra meow sounds: drop any number here
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
    "Meow. Fluid maintenance, STAT.",
    "That glass won't drink itself.",
    "I heard a rumor you haven't sipped in a while.",
    "If you don't drink, I sit on your keyboard.",
    "Water now, treats later. Deal?",
    "Tail is twitching. That means: drink.",
    "New hour, new glass of water.",
    "Even I drink water. Well, I try not to look like it.",
    "You look dry. Tragic.",
    "Fill my bowl, fill your glass.",
    "The cat overlords demand hydration.",
    "Whisker reminder: hydrate!",
    "Break over. Water, please.",
    "Lap water later, glass water now.",
    "Your skin is basically fur you never grew. Water it."
)
$script:quietUntil = $null

# pool of meow sounds: every .wav in the "meows" folder plus the classic meow.wav
$script:meowFiles = @()
if (Test-Path $script:meowsDir) {
    $script:meowFiles += @(Get-ChildItem $script:meowsDir -Filter *.wav -File | ForEach-Object { $_.FullName })
}
if (Test-Path (Join-Path $dir "meow.wav")) { $script:meowFiles += (Join-Path $dir "meow.wav") }

# ---------- storage ----------
function Save-Reminders {
    $json = "[]"
    if (@($script:reminders).Count -gt 0) {
        $json = ConvertTo-Json -InputObject @($script:reminders) -Depth 5
    }
    # atomic-ish write: fill a temp file first, then swap it in, so a crash
    # or a concurrent save can never leave an empty reminders.json behind
    try {
        $tmp = "$script:remindersFile.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $script:remindersFile) { Remove-Item $script:remindersFile -Force }
        Move-Item $tmp $script:remindersFile
    } catch {
        Set-Content -Path $script:remindersFile -Value $json -Encoding UTF8
    }
}

function Load-Reminders {
    $todayDefault = $false
    if (!(Test-Path $script:remindersFile)) {
        $todayDefault = $true
    } else {
        $raw = ""
        try { $raw = Get-Content $script:remindersFile -Raw } catch { }
        if (!$raw) { $todayDefault = $true }
        else {
            $script:reminders = @()
            try { $script:reminders = @((ConvertFrom-Json $raw)) } catch { $todayDefault = $true }
            # drop nulls that can sneak in from an empty/not-an-array file
            $script:reminders = @($script:reminders | Where-Object { $_ -ne $null -and $_.PSObject.Properties.Name.Count -gt 0 })
            if (@($script:reminders).Count -eq 0) { $todayDefault = $true }
        }
    }
    if ($todayDefault) {
        # no usable data: fall back to the friendly default and persist it
        $default = @([pscustomobject]@{
            Type = "repeat"
            Message = "Drink some water! Stay hydrated \_/_"
            IntervalMinutes = 60
            LastShown = $null
            FireAt = $null
        })
        $script:reminders = $default
        Save-Reminders
        & $script:log "reminders file missing/empty/corrupt - persisted defaults"
    }
}

function Get-RemType($r) {
    if ($r.PSObject.Properties.Name -contains "Type") { return $r.Type }
    return "repeat"   # old reminders, before this upgrade
}

# ---------- personal settings & water tally ----------
# settings.json is optional user state: quiet hours, today's glass count
function Load-Settings {
    # defaults; a settings.json next to the script overrides these
    $defaults = [pscustomobject]@{
        quietEnabled = $false
        quietFrom    = "23:00"   # quiet hours, for example 23:00 to 07:00
        quietTo      = "07:00"
        glasses      = 0         # glasses of water marked as drunk today
        glassesDay   = (Get-Date).ToString("yyyy-MM-dd")
        glassesTotal = 0
    }
    if (Test-Path $script:settingsFile) {
        try {
            $s = ConvertFrom-Json (Get-Content $script:settingsFile -Raw)
            foreach ($p in ($s.PSObject.Properties)) {
                if ($defaults.PSObject.Properties.Name -contains $p.Name) {
                    $defaults.($p.Name) = $p.Value
                }
            }
        } catch { }
    }
    # a new day resets the tally automatically
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($defaults.glassesDay -ne $today) {
        $defaults.glasses = 0
        $defaults.glassesDay = $today
    }
    $script:settings = $defaults
}

function Save-Settings {
    try { ConvertTo-Json -InputObject $script:settings -Depth 3 |
        Set-Content -Path $script:settingsFile -Encoding UTF8 } catch { }
}

function Add-Glass([int]$n = 1) {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($script:settings.glassesDay -ne $today) {
        $script:settings.glasses = 0
        $script:settings.glassesDay = $today
    }
    $script:settings.glasses += $n
    $script:settings.glassesTotal += $n
    Save-Settings
    Update-ListView
}

function Test-QuietHours([datetime]$now) {
    # scheduled quiet window; overnight ranges (23:00 - 07:00) supported
    if (!$script:settings.quietEnabled) { return $false }
    try {
        $from = [datetime]::ParseExact($script:settings.quietFrom, "HH:mm", $null).TimeOfDay
        $to   = [datetime]::ParseExact($script:settings.quietTo,   "HH:mm", $null).TimeOfDay
        $t = $now.TimeOfDay
        if ($from -le $to) { return ($t -ge $from -and $t -lt $to) }
        return ($t -ge $from -or $t -lt $to)
    } catch { return $false }
}

function Test-NotificationsBlocked {
    # true while the person is in a fullscreen game, presentation or similar.
    # states 1 (accepts) and 5 (accepts, persistent app) are both fine to interrupt
    try {
        $state = 0
        [void][DpiAware]::SHQueryUserNotificationState([ref]$state)
        return ($state -in 2, 3, 4, 6, 7)   # busy, d3d fullscreen, presentation, store app, do-not-disturb
    } catch { return $false }
}

# ---------- cat image prep ----------
# Removes the baked-in checkerboard background (flood fill from borders),
# removes small light islands left inside, and crops tight around the cat.
# Uses the precompiled catproc.dll (fast boot); falls back to inline compile only if missing.
$script:log = { param($m) try { Add-Content -Path (Join-Path $dir "debug.log") -Value "$(Get-Date -Format HH:mm:ss.fff) $m" -ErrorAction SilentlyContinue } catch { } }
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

# crisp rendering on scaled displays: opt out of Windows DPI virtualization
# (must happen before any window is created)
if (-not ("DpiAware" -as [type])) {
    Add-Type @'
using System.Runtime.InteropServices;
public static class DpiAware {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    // 1 = accepts notifications; anything else = fullscreen game, presentation, do-not-disturb
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
}
'@
}
[void][DpiAware]::SetProcessDPIAware()

# hardens the alpha channel of a cat cutout: no half-transparent rim left,
# so the fuchsia transparency key can't bleed pink into the cat's edges
if (-not ("CatFix" -as [type])) {
    Add-Type @'
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class CatFix {
    public static Bitmap FixEdges(Bitmap bm) {
        var rect = new Rectangle(0, 0, bm.Width, bm.Height);
        var bd = bm.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int n = bd.Stride * bm.Height;
        var buf = new byte[n];
        Marshal.Copy(bd.Scan0, buf, 0, n);
        bm.UnlockBits(bd);
        for (int i = 3; i < n; i += 4) {
            if (buf[i] <= 120) buf[i] = 0; else buf[i] = 255;
        }
        bd = bm.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        Marshal.Copy(buf, 0, bd.Scan0, n);
        bm.UnlockBits(bd);
        return bm;
    }
}
'@ -ReferencedAssemblies System.Drawing
}

# layered-window machinery for the popup: a form whose entire content is one
# ARGB surface presented with per-pixel alpha (UpdateLayeredWindow). True
# transparency with soft cat edges - replaces the old fuchsia color key,
# whose blending is what caused the pink fringe around cat cutouts.
if (-not ("CatForm" -as [type])) {
    Add-Type @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class CatForm : Form {
    // WS_EX_LAYERED from birth: the window shows nothing (and no flash)
    // until the first UpdateLayeredWindow content is pushed
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x80000; return cp; }
    }
}

public class CatLayer {
    [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SZ { public int W, H; }
    [StructLayout(LayoutKind.Sequential)] public struct BF { public byte Op, Flags, Src, Fmt; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref PT p, ref SZ s, IntPtr src, ref PT s0, uint key, ref BF b, uint f);

    public static void Blend(IntPtr hwnd, Bitmap bmp) {
        // premultiply each pixel by its alpha - the format ULW expects
        var rect = new Rectangle(0, 0, bmp.Width, bmp.Height);
        var bd = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        int n = bd.Stride * bmp.Height;
        var buf = new byte[n];
        Marshal.Copy(bd.Scan0, buf, 0, n);
        bmp.UnlockBits(bd);
        for (int i = 0; i < n; i += 4) {
            int a = buf[i + 3];
            if (a == 255) continue;
            if (a == 0) { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; continue; }
            buf[i]     = (byte)((buf[i]     * a + 127) / 255);
            buf[i + 1] = (byte)((buf[i + 1] * a + 127) / 255);
            buf[i + 2] = (byte)((buf[i + 2] * a + 127) / 255);
        }
        var bd2 = bmp.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        Marshal.Copy(buf, 0, bd2.Scan0, n);
        bmp.UnlockBits(bd2);

        IntPtr scr = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(scr);
        IntPtr hbm = bmp.GetHbitmap(Color.FromArgb(0));
        IntPtr old = SelectObject(mem, hbm);
        RECT r; GetWindowRect(hwnd, out r);
        var p  = new PT(); p.X = r.L; p.Y = r.T;
        var sz = new SZ(); sz.W = bmp.Width; sz.H = bmp.Height;
        var s0 = new PT(); s0.X = 0; s0.Y = 0;
        var bf = new BF(); bf.Op = 0; bf.Flags = 0; bf.Src = 255; bf.Fmt = 1;
        UpdateLayeredWindow(hwnd, scr, ref p, ref sz, mem, ref s0, 0, ref bf, 2);
        SelectObject(mem, old);
        DeleteObject(hbm);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, scr);
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

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

function Measure-CutTransparency($bm) {
    # ratio of see-through pixels - a real cutout has plenty, a photo has almost none
    $rect = New-Object System.Drawing.Rectangle(0, 0, $bm.Width, $bm.Height)
    $bd = $bm.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ([int]($bd.Stride * $bm.Height))
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
    $bm.UnlockBits($bd)
    $trans = 0
    for ($i = 3; $i -lt $buf.Length; $i += 4) { if ($buf[$i] -le 24) { $trans++ } }
    return ($trans / ($bm.Width * $bm.Height))
}

function Get-CatBitmapList {
    # all available cats, cleaned and cached under cache\cut_<name>.png
    # sources: every .png in the "cats" folder + the classic cat.png fallback
    if ($script:catBitmaps) { return $script:catBitmaps }
    $script:catBitmaps = @()
    $cacheDir = Join-Path $dir "cache"
    $sources = @()
    if (Test-Path $script:catsDir) {
        $sources += @(Get-ChildItem $script:catsDir -Filter *.png -File | ForEach-Object { $_.FullName })
    }
    if ((Test-Path $script:catImage) -and (-not ($sources -contains $script:catImage))) {
        $sources += $script:catImage
    }
    $skipped = @()
    foreach ($src in $sources) {
        try {
            $cache = Join-Path $cacheDir ("cut_" + [System.IO.Path]::GetFileName($src))
            if ((Test-Path $cache) -and ((Get-Item $cache).LastWriteTime -ge (Get-Item $src).LastWriteTime)) {
                $cut = Get-SafeBitmap $cache
            } else {
                $cut = [CatProc]::ProcessCat([System.IO.File]::ReadAllBytes($src))
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null   # never assume the folder exists
                $cut.Save($cache, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            # popups render with true per-pixel alpha now - soft edges are a feature,
            # the old pink color-key fringe is gone for good
            # reject non-cutouts (photos etc): a usable cutout is mostly see-through
            if ((Measure-CutTransparency $cut) -lt 0.15) {
                $skipped += "$(Split-Path $src -Leaf) - background could not be removed; photo or non-flat background"
                $cut.Dispose()
                continue
            }
            $script:catBitmaps += $cut
        } catch { }   # a bad image should never take the whole cat down
    }
    # tell the person, in a file, why a cat they added never shows up
    $skippedFile = Join-Path $cacheDir "skipped.txt"
    if ($skipped.Count -gt 0) { $skipped -join "`n" | Set-Content -Path $skippedFile -Encoding UTF8 }
    elseif (Test-Path $skippedFile) { Remove-Item $skippedFile -Force }
    return $script:catBitmaps
}

function Get-RandomCatIndex([int]$count) {
    return (Get-Random -Maximum ([Math]::Max(1, $count)))
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
    $catList = @(Get-CatBitmapList)
    $cut = $null
    if ($catList.Count -gt 0) {
        $cut = $catList[(Get-RandomCatIndex $catList.Count)]
    }
    # cat and voice are drawn independently - every popup can be a new combo
    $flavor = @(Get-Random -InputObject $script:flavors)[0]
    # remember panel visibility - dismissing the popup must not resurrect the panel
    $panelWasVisible = $false
    if ($script:form) { $panelWasVisible = $script:form.Visible }

    # scale by the display DPI so bubble, text and cat stay properly sized and crisp
    $gDpi = [System.Drawing.Graphics]::FromHwnd([System.IntPtr]::Zero)
    $s = $gDpi.DpiX / 96.0
    $gDpi.Dispose()

    $W  = [int][Math]::Round(420 * $s); $H  = [int][Math]::Round(575 * $s)
    $catX = [int][Math]::Round(10 * $s); $catY = [int][Math]::Round(140 * $s)
    $catW = [int][Math]::Round(400 * $s); $catH = [int][Math]::Round(420 * $s)

    $form = New-Object CatForm   # layered window: content is one alpha surface, no color key
    $form.Text = "Your cat says..."
    $form.Size = New-Object System.Drawing.Size($W, $H)
    $form.StartPosition = "Manual"
    $form.Location = New-Object System.Drawing.Point(
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width - $W - 10),
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - $H - 10))
    $form.TopMost = $true
    $form.FormBorderStyle = "None"
    $form.ShowInTaskbar = $false
    $form.Cursor = "Hand"

    # speech bubble colors (Material You, soft lavender)
    $bubbleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(232, 222, 248))
    $linePen     = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(199, 183, 236), 1.5)
    $msgBrush    = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(74, 68, 88))
    $hintBrush   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(125, 115, 140))
    $msgFont     = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $hintFont    = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
    $textFormat  = New-Object System.Drawing.StringFormat
    $textFormat.Alignment = "Center"
    $textFormat.LineAlignment = "Center"

    # live state shared with the renderer
    $hud = @{ countdown = 0; counting = $false; ack = $null }

    # the whole popup is one ARGB surface: bubble, text and cat drawn here,
    # pushed to the screen with per-pixel alpha. Invisible areas are truly
    # transparent AND click-through.
    $surface = New-Object System.Drawing.Bitmap($W, $H)
    $drawFrame = {
        try {
        $g = [System.Drawing.Graphics]::FromImage($surface)
        $g.SmoothingMode = "AntiAlias"
        $g.TextRenderingHint = "AntiAlias"
        $g.Clear([System.Drawing.Color]::Transparent)
        $rect = New-Object System.Drawing.Rectangle([int](14*$s), [int](6*$s), [int](392*$s), [int](96*$s))
        $path = New-BubblePath $rect ([Math]::Round(18*$s))
        $g.FillPath($bubbleBrush, $path)
        $g.DrawPath($linePen, $path)
        # tail pointing at the cat's head
        $tail = New-Object 'System.Drawing.PointF[]' 3
        $tail[0] = New-Object System.Drawing.PointF([single](170*$s), [single](100*$s))
        $tail[1] = New-Object System.Drawing.PointF([single](254*$s), [single](100*$s))
        $tail[2] = New-Object System.Drawing.PointF([single](215*$s), [single](146*$s))
        $g.FillPolygon($bubbleBrush, $tail)

        $msgRect = New-Object System.Drawing.RectangleF([single](32*$s), [single](16*$s), [single](356*$s), [single](58*$s))
        $g.DrawString($Message, $msgFont, $msgBrush, $msgRect, $textFormat)

        $hint = $flavor
        if ($hud.ack) { $hint = $hud.ack }
        elseif ($hud.counting) { $hint = "closing in $($hud.countdown)s..." }
        $hintRect = New-Object System.Drawing.RectangleF([single](32*$s), [single](80*$s), [single](356*$s), [single](18*$s))
        $g.DrawString($hint, $hintFont, $hintBrush, $hintRect, $textFormat)

        # --- the cat, huge and crisp ---
        if ($cut) {
            $g.InterpolationMode = "HighQualityBicubic"
            $g.DrawImage($cut, $catX, $catY, $catW, $catH)
        } else {
            # ASCII fallback until a picture exists
            $asciiFont = New-Object System.Drawing.Font("Consolas", 26)
            $asciiRect = New-Object System.Drawing.RectangleF([single](110*$s), [single](210*$s), [single](200*$s), [single](160*$s))
            $g.DrawString("   /\_/\`n  ( o.o )`n   > ^ <", $asciiFont, $msgBrush, $asciiRect, $textFormat)
            $asciiFont.Dispose()
        }
        $g.Dispose()
        [CatLayer]::Blend($form.Handle, $surface)
        } catch {
            & $script:log "drawFrame ERROR: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
            [System.IO.File]::WriteAllText((Join-Path $env:TEMP "cat-drawframe-error.txt"), "$($_ | Out-String)")
        }
    }

    # -- dismissal --
    $hover = New-Object System.Windows.Forms.Timer
    $hover.Interval = 1000
    $hover.Add_Tick({
        if ($hud.counting) {
            $hud.countdown--
            & $script:log "countdown tick -> $($hud.countdown)"
            if ($hud.countdown -le 0) { $form.Close() } else { & $drawFrame }
        }
    })

    $form.Add_MouseEnter({
        # first touch starts the countdown; re-touching does NOT reset it
        if (!$hud.counting) {
            $hud.countdown = 10
            $hud.counting = $true
            $hover.Start()
            & $drawFrame
        }
    })

    $form.Add_MouseClick({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            # clicking the cat to dismiss it = the water was actually drunk
            if ($Rem) { try { Add-Glass 1 } catch { } }
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
            & $drawFrame
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
    $form.Add_DoubleClick($quietHandler)   # double-click = quiet mode for one hour

    $form.Add_FormClosing({
        & $script:log "popup closing, reason: $($_.CloseReason)"
    })

    $form.Add_Shown({ $form.Activate(); & $drawFrame })
    $form.KeyPreview = $true
    $form.Add_KeyDown({ if ($_.KeyCode -eq "Enter") { $hover.Stop(); $form.Close() } })

    # safety net: auto-close after 5 minutes of being ignored
    $safety = New-Object System.Windows.Forms.Timer
    $safety.Interval = ($script:autoCloseSeconds * 1000)
    $safety.Add_Tick({ $form.Close() })
    $safety.Start()

    # purr: a real meow from the pool (meows folder + meow.wav), random per popup
    try {
        $meow = $null
        $mf = @($script:meowFiles)
        if ($mf.Count -gt 0) {
            $meow = $mf[(Get-Random -Maximum $mf.Count)]
            (New-Object System.Media.SoundPlayer($meow)).Play()
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
    $surface.Dispose()
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
    try {
        $g = $script:settings.glasses
        $unit = if ($g -eq 1) { "glass" } else { "glasses" }
        $tally.Location = New-Object System.Drawing.Point(170, 10)
        $tally.Text = "Water: $g $unit today - total $($script:settings.glassesTotal)"
    } catch { }
}

function Check-Reminders {
    $now = Get-Date
    # ad-hoc quiet mode: no popups for a while (double-click the cat to activate)
    if ($script:quietUntil -and $now -lt $script:quietUntil) { Update-ListView; return }
    # scheduled quiet hours (toggle in the tray menu)
    if (Test-QuietHours $now) { Update-ListView; return }
    # never surprise someone mid-game or mid-presentation: wait until Windows
    # says notifications are okay again (due reminders simply fire later)
    if (Test-NotificationsBlocked) { Update-ListView; return }
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
Load-Settings
& $script:log "reminders loaded: $(@($script:reminders).Count)"

# ---------- control panel ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Cat Reminders"
$form.AutoScaleMode = "Dpi"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Size = New-Object System.Drawing.Size(478, 600)
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

# today's water tally
$tally = New-Object System.Windows.Forms.Label
$tally.AutoSize = $true
$tally.ForeColor = [System.Drawing.Color]::FromArgb(103, 80, 164)
$tally.Location = New-Object System.Drawing.Point(300, 10)
$form.Controls.Add($tally)

$lv = New-Object System.Windows.Forms.ListView
$lv.View = "Details"
$lv.FullRowSelect = $true
$lv.HideSelection = $true
$lv.Size = New-Object System.Drawing.Size(446, 128)
$lv.Location = New-Object System.Drawing.Point(12, 32)
[void]$lv.Columns.Add("Message", 226)
[void]$lv.Columns.Add("Pattern", 104)
[void]$lv.Columns.Add("Next", 108)
$form.Controls.Add($lv)

# add reminder group
$group = New-Object System.Windows.Forms.GroupBox
$group.Text = "Add a reminder"
$group.Size = New-Object System.Drawing.Size(446, 236)
$group.Location = New-Object System.Drawing.Point(12, 172)
$form.Controls.Add($group)

$msgLabel = New-Object System.Windows.Forms.Label
$msgLabel.Text = "What should the cat say?"
$msgLabel.AutoSize = $true
$msgLabel.Location = New-Object System.Drawing.Point(15, 18)
$group.Controls.Add($msgLabel)

$txtMessage = New-Object System.Windows.Forms.TextBox
$txtMessage.Multiline = $true
$txtMessage.Size = New-Object System.Drawing.Size(408, 45)
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
$btnAdd.Location = New-Object System.Drawing.Point(15, 192)
$btnAdd.BackColor = [System.Drawing.Color]::FromArgb(103, 80, 164)
$btnAdd.ForeColor = [System.Drawing.Color]::White
$btnAdd.FlatStyle = "Flat"
$btnAdd.FlatAppearance.BorderSize = 0
$group.Controls.Add($btnAdd)

# preview button: opens the cat popup on demand
$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = "Show the cat now"
$btnPreview.Size = New-Object System.Drawing.Size(150, 32)
$btnPreview.Location = New-Object System.Drawing.Point(186, 192)
$btnPreview.FlatStyle = "Flat"
$btnPreview.FlatAppearance.BorderSize = 0
$group.Controls.Add($btnPreview)

# delete button
$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Delete selected"
$btnDelete.Size = New-Object System.Drawing.Size(140, 32)
$btnDelete.Location = New-Object System.Drawing.Point(192, 420)
$btnDelete.FlatStyle = "Flat"
$form.Controls.Add($btnDelete)

# "drank it" button: log a glass without waiting for a popup
$btnGlass = New-Object System.Windows.Forms.Button
$btnGlass.Text = "I drank a glass"
$btnGlass.Size = New-Object System.Drawing.Size(170, 32)
$btnGlass.Location = New-Object System.Drawing.Point(12, 420)
$btnGlass.BackColor = [System.Drawing.Color]::FromArgb(103, 80, 164)
$btnGlass.ForeColor = [System.Drawing.Color]::White
$btnGlass.FlatStyle = "Flat"
$btnGlass.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnGlass)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "One-time reminders disappear when they fire. Closing this window keeps the cat in the tray (double-click to reopen). Quiet hours lives in the tray menu - and drop cat PNGs or .wav sounds into cats / meows for random mixing. Clicking the cat counts a glass."
$hint.ForeColor = [System.Drawing.Color]::Gray
$hint.AutoSize = $false
$hint.TextAlign = "TopLeft"
$hint.Size = New-Object System.Drawing.Size(446, 100)
$hint.Location = New-Object System.Drawing.Point(12, 460)
$form.Controls.Add($hint)

# ---------- tray icon ----------
$script:trayIcon = $null
try {
    # a random cat guards the tray (each boot can be a different one)
    $catList = @(Get-CatBitmapList)
    $icoSrc = $null
    if ($catList.Count -gt 0) { $icoSrc = $catList[(Get-RandomCatIndex $catList.Count)] }
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

# scheduled quiet hours: a window like 23:00 - 07:00 where the cat stays asleep
$script:quietItem = New-Object System.Windows.Forms.ToolStripMenuItem
$script:quietItem.Text = "Quiet hours: OFF"
$script:quietItem.Add_Click({
    $script:settings.quietEnabled = -not $script:settings.quietEnabled
    Save-Settings
    $script:quietItem.Text = "Quiet hours ($($script:settings.quietFrom)-$($script:settings.quietTo)): " + $(if ($script:settings.quietEnabled) { "ON" } else { "OFF" })
    try {
        $tray.BalloonTipTitle = "Cat Reminders"
        $tray.BalloonTipText = if ($script:settings.quietEnabled) {
            "Quiet from $($script:settings.quietFrom) to $($script:settings.quietTo). The cat naps (and so should you)."
        } else { "Quiet hours off. The cat resumes hydrating you." }
        $tray.ShowBalloonTip(3000)
    } catch { }
})
[void]$menu.Items.Add($script:quietItem)
[void]$menu.Items.Add("Exit (fire the cat)", $null, {
    $script:allowClose = $true
    $tray.Visible = $false
    $form.Close()
})
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ $form.Show(); $form.Activate() })

# screenshot helper: start with the panel visible (also handy for first looks)
if ($ShowPanel) {
    Load-Settings
    Update-ListView
    $form.Show(); $form.Activate()
}

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

$btnGlass.Add_Click({
    Add-Glass 1
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
