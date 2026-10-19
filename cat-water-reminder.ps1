# ================= Cat Hydration Reminder =================
# Every 60 minutes, a cat pops up and tells you to drink water.
# Close the popup normally, or it auto-closes after 5 minutes of ignoring.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$intervalMinutes = 60   # how often the cat nags you
$autoCloseSeconds = 300 # popup auto-closes after 5 minutes

function Show-CatPopup {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Miau! Hydration Time"
    $form.Size = New-Object System.Drawing.Size(420, 340)
    $form.StartPosition = "Manual"
    $form.Location = New-Object System.Drawing.Point(
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width - 420),
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height - 340))
    $form.TopMost = $true
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White

    # --- the cat ---
    $cat = New-Object System.Windows.Forms.Label
    $cat.Text = @"
   /\_/\
  ( o.o )   ~ psst!
   > ^ <   /  it's time!
              / \
"@
    $cat.Font = New-Object System.Drawing.Font("Consolas", 13)
    $cat.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $cat.AutoSize = $false
    $cat.Size = New-Object System.Drawing.Size(400, 130)
    $cat.Location = New-Object System.Drawing.Point(10, 10)
    $form.Controls.Add($cat)

    # --- the message ---
    $msg = New-Object System.Windows.Forms.Label
    $msg.Text = "Drink some water! Stay hydrated. `_/_"
    $msg.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $msg.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 200)
    $msg.AutoSize = $false
    $msg.Size = New-Object System.Drawing.Size(380, 70)
    $msg.TextAlign = "MiddleCenter"
    $msg.Location = New-Object System.Drawing.Point(10, 145)
    $form.Controls.Add($msg)

    # --- okay button ---
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Okay, drinking now!"
    $ok.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $ok.Size = New-Object System.Drawing.Size(180, 38)
    $ok.Location = New-Object System.Drawing.Point(110, 230)
    $ok.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 220)
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.FlatStyle = "Flat"
    $ok.Add_Click({ $form.Close() })
    $form.Controls.Add($ok)

    $form.Add_Shown({ $form.Activate() })

    # auto-close timer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = ($autoCloseSeconds * 1000)
    $timer.Add_Tick({ $form.Close() })
    $timer.Start()

    # small purr (sound)
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}

    [void]$form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
}

# --- main loop ---
# show the cat once at startup so you know it's working, then every hour
Show-CatPopup
while ($true) {
    Start-Sleep -Seconds ($intervalMinutes * 60)
    Show-CatPopup
}
