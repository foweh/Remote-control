# ============================================================
#  mouse-ctrl-v3 - mouse driver (persistent process)
#  Launched by server.js. Reads one text command per line from stdin:
#
#    M <x> <y>        absolute move (virtual-screen coords)
#    R <dx> <dy>      relative move (read cursor + offset, no acceleration)
#    LD / LU / LC     left button down / up / click
#    RD / RU / RC     right button down / up / click
#    W <delta>        wheel (+up / -down, 120 = one notch, fractional OK)
#    K <text>         keyboard input (ASCII via SendKeys, CJK via clipboard)
#    P                ping, replies with a line: OK
#
#  On startup, emits virtual-screen bounds to stdout:  B <x> <y> <w> <h>
#  -SelfTest: compile check + read bounds/cursor only, never moves the mouse
#
#  NOTE: this file is intentionally ASCII-only (no CJK), because the
#  whole driver depends on it parsing correctly under PowerShell 5.1.
# ============================================================
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MouseWin {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, int dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);
}
"@

# ---------- virtual screen bounds (all monitors combined) ----------
$vs   = [System.Windows.Forms.SystemInformation]::VirtualScreen
$BX   = [int]$vs.X
$BY   = [int]$vs.Y
$BW   = [int]$vs.Width
$BH   = [int]$vs.Height

function Emit([string]$s) {
    [Console]::Out.WriteLine($s)
    [Console]::Out.Flush()
}

function Clamp([double]$v, [double]$min, [double]$max) {
    return [Math]::Max($min, [Math]::Min($max, $v))
}

function Set-Pos([int]$x, [int]$y) {
    $x = [int](Clamp $x $BX ($BX + $BW - 1))
    $y = [int](Clamp $y $BY ($BY + $BH - 1))
    [MouseWin]::SetCursorPos($x, $y) | Out-Null
}

function Send-Key([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $ascii = $true
    foreach ($ch in $text.ToCharArray()) {
        if ([int]$ch -gt 126 -and [int]$ch -ne 1) { $ascii = $false; break }
    }
    if ($ascii) {
        # SendKeys specials escaped first (braces first); newline marker 0x01 -> Enter (inserted last, safe)
        $escaped = $text.Replace('{','{{}').Replace('}','{}}')
        $escaped = $escaped.Replace('+','{+}').Replace('^','{^}').Replace('%','{%}').Replace('~','{~}').Replace('(','{(}').Replace(')','{)}').Replace('[','{[}').Replace(']','{]}')
        $escaped = $escaped.Replace([string][char]1, '{ENTER}')
        [System.Windows.Forms.SendKeys]::SendWait($escaped)
    } else {
        # CJK etc: clipboard + Ctrl+V (temporarily uses the clipboard); 0x01 -> real newline
        $t2 = $text.Replace([string][char]1, "`r`n")
        [System.Windows.Forms.Clipboard]::SetText($t2)
        [System.Windows.Forms.SendKeys]::SendWait('^v')
    }
}

Emit "B $BX $BY $BW $BH"

if ($SelfTest) {
    $p = [System.Windows.Forms.Cursor]::Position
    Emit "CUR $($p.X) $($p.Y)"
    Emit "SELFTEST OK"
    exit 0
}

Emit 'READY'

# unified UTF-8 channel (commands are ASCII; K payload may contain CJK)
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }          # stdin closed -> exit

    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }

    $cmd = $line[0]
    try {
        switch ($cmd) {
            'M' { # M x y / MC
                if ($line -eq 'MC') {
                    [MouseWin]::mouse_event(0x0020, 0, 0, 0, [UIntPtr]::Zero)
                    [MouseWin]::mouse_event(0x0040, 0, 0, 0, [UIntPtr]::Zero)
                    break
                }
                $parts = $line.Substring(1).Trim().Split(' ')
                Set-Pos ([int]$parts[0]) ([int]$parts[1])
                break
            }
            'D' { # DC double click
                if ($line -eq 'DC') {
                    [MouseWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                    [MouseWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                    Start-Sleep -Milliseconds 40
                    [MouseWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                    [MouseWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                }
                break
            }
            'R' { # R dx dy / RD / RU / RC
                if    ($line -eq 'RD') { [MouseWin]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero) }
                elseif($line -eq 'RU') { [MouseWin]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
                elseif($line -eq 'RC') { [MouseWin]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); [MouseWin]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
                else { # relative move: read cursor + offset, zero acceleration
                    $parts = $line.Substring(1).Trim().Split(' ')
                    $p = [MouseWin+POINT]::new()
                    [MouseWin]::GetCursorPos([ref]$p) | Out-Null
                    Set-Pos ($p.X + [int]$parts[0]) ($p.Y + [int]$parts[1])
                }
                break
            }
            'L' { # LD / LU / LC
                if    ($line -eq 'LD') { [MouseWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) }
                elseif($line -eq 'LU') { [MouseWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
                elseif($line -eq 'LC') { [MouseWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); [MouseWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
                break
            }
            'W' { # W delta
                $delta = [int]($line.Substring(1).Trim())
                [MouseWin]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero)
                break
            }
            'K' { # K text
                Send-Key ($line.Substring(1).Trim())
                break
            }
            'P' {
                Emit 'OK'
                break
            }
        }
    } catch {
        # One bad command is skipped; the driver must never die.
    }
}
