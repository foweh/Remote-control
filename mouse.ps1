# ============================================================
#  mouse-ctrl-v3 — 鼠标驱动（常驻进程）
#  由 server.js 拉起，通过 stdin 接收一行一条的文本指令：
#
#    M <x> <y>        绝对移动（虚拟屏幕坐标）
#    R <dx> <dy>      相对移动（读当前位置+偏移，无加速，丝滑）
#    LD / LU / LC     左键 按下/抬起/单击
#    RD / RU / RC     右键 按下/抬起/单击
#    W <delta>        滚轮（+向上 / -向下，120 = 一格，可发小数增量）
#    K <文本>         键盘输入（ASCII 走 SendKeys；含中文走剪贴板粘贴）
#    P                ping，回一行 OK
#
#  启动时向 stdout 输出一行虚拟屏幕边界:  B <x> <y> <w> <h>
#  -SelfTest: 只自检（编译 P/Invoke + 读边界/光标），不动鼠标
# ============================================================
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MouseWin {
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@

# ---------- 虚拟屏幕边界（多显示器合并区域） ----------
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
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($x, $y)
}

function Send-Key([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $ascii = $true
    foreach ($ch in $text.ToCharArray()) {
        if ([int]$ch -gt 126) { $ascii = $false; break }
    }
    if ($ascii) {
        # SendKeys 特殊字符转义（花括号必须先转义）
        $escaped = $text.Replace('{','{{}').Replace('}','{}}')
        $escaped = $escaped.Replace('+','{+}').Replace('^','{^}').Replace('%','{%}').Replace('~','{~}').Replace('(','{(}').Replace(')','{)}').Replace('[','{[}').Replace(']','{]}')
        [System.Windows.Forms.SendKeys]::SendWait($escaped)
    } else {
        # 中文等非 ASCII：剪贴板 + Ctrl+V（注意会占用剪贴板）
        [System.Windows.Forms.Clipboard]::SetText($text)
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

# 统一 UTF-8 通道（指令均为 ASCII，K 的文本可能含中文）
[Console]::InputEncoding  = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }          # stdin 关闭 -> 退出

    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }

    $cmd = $line[0]
    switch ($cmd) {
        'M' { # M x y
            $parts = $line.Substring(1).Trim() -split '\s+'
            Set-Pos ([int]$parts[0]) ([int]$parts[1])
            break
        }
        'R' { # R dx dy / RD / RU / RC
            if    ($line -eq 'RD') { [MouseWin]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero) }
            elseif($line -eq 'RU') { [MouseWin]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
            elseif($line -eq 'RC') { [MouseWin]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); [MouseWin]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero) }
            else { # 相对移动（读光标+偏移，完全无加速）
                $parts = $line.Substring(1).Trim() -split '\s+'
                $p = [System.Windows.Forms.Cursor]::Position
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
            [MouseWin]::mouse_event(0x0800, 0, 0, [uint32]$delta, [UIntPtr]::Zero)
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
}
