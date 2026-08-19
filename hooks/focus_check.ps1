# notify.sh 的 Windows 前台检测（Git Bash 经 powershell.exe -File 调用）。
# 判断前台焦点窗口是否属于 -StartPid 进程的祖先（即 Claude Code 所在的终端），
# 输出三种结果之一：
#   FOCUSED — 终端窗口聚焦，调用方跳过推送
#   AWAY    — 全局无键鼠输入超过 MaxIdle 秒（人不在，锁屏也会累计），照常推送
#   NO      — 焦点在别的窗口，照常推送
# 任何异常静默退出且不输出 FOCUSED，调用方按 fail-open（照常推送）处理。
param(
  [Parameter(Mandatory = $true)][int]$StartPid,
  [int]$MaxIdle = 120
)
$ErrorActionPreference = 'SilentlyContinue'

Add-Type -Namespace CC -Name Native -MemberDefinition @"
[DllImport("user32.dll")]   public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]   public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")]   public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
"@

# Add-Type 失败（受限语言模式等）时后续调用全为 $null，而 $null -eq $null 为真，
# 会把"取不到窗口句柄"误判成 FOCUSED 吞掉通知——必须显式校验后按未聚焦处理
if (-not ('CC.Native' -as [type])) { Write-Output 'NO'; exit 0 }

# 已锁屏（锁屏界面进程 LogonUI 在运行）→ 一定看不到终端，照常推送。
# 手动 Win+L 锁屏时按键会清零空闲计时，不能只靠下面的空闲阈值；
# 锁屏时 GetForegroundWindow 通常也返回 0，这里是双保险
if (Get-Process -Name LogonUI -ErrorAction SilentlyContinue) { Write-Output 'AWAY'; exit 0 }

# 人已走开：全局空闲超过阈值则不管焦点在哪都照常推送
$lii = New-Object -TypeName 'CC.Native+LASTINPUTINFO'
$lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
if ([CC.Native]::GetLastInputInfo([ref]$lii)) {
  $idleSec = ([Environment]::TickCount - $lii.dwTime) / 1000
  if ($idleSec -ge $MaxIdle) { Write-Output 'AWAY'; exit 0 }
}

$fw = [CC.Native]::GetForegroundWindow()
if ($fw -eq [IntPtr]::Zero) { Write-Output 'NO'; exit 0 }

# 经典 conhost 控制台：本进程继承的控制台窗口句柄可直接和前台窗口比对
if ($fw -eq [CC.Native]::GetConsoleWindow()) { Write-Output 'FOCUSED'; exit 0 }

# Windows Terminal / VS Code 等：窗口属主进程（WindowsTerminal.exe / Code.exe）
# 是 shell 的祖先，沿 StartPid 的父进程链上溯比对
$fgPid = [uint32]0
[void][CC.Native]::GetWindowThreadProcessId($fw, [ref]$fgPid)
$p = $StartPid
for ($i = 0; $i -lt 25 -and $p -gt 4; $i++) {
  if ($p -eq $fgPid) { Write-Output 'FOCUSED'; exit 0 }
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p"
  if (-not $proc) { break }
  $p = [int]$proc.ParentProcessId
}
Write-Output 'NO'
