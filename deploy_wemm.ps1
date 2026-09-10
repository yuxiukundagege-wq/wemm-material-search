# WeMM 素材检索 - 一键部署脚本 (Windows)
# 双击同目录下的「一键部署.bat」即可运行本脚本。
# 幂等设计: 每一步都先检测现状, 已完成的环节自动跳过; 中断后重跑可续跑。
[CmdletBinding()]
param(
  [string]$InstallDir = '',        # 部署目录(venv/模型/索引都放这里), 默认 D:\WeMM-Embedding(无D盘则 C:\WeMM-Embedding)
  [string]$LibraryDir = '',        # 素材库目录, 默认 D:\Downloads(无D盘则 用户\Downloads)
  [string]$PackageRoot = '',       # 本分发包根目录, 默认=脚本所在目录
  [string]$AppDir = '',            # 桌面程序目录(免安装绿色版复制到这里), 默认 <部署目录>\app
  [string]$AppSourceDir = '',      # 免安装绿色版来源目录, 默认 <分发包>\app\win-unpacked
  [string]$PyMirror = 'https://pypi.tuna.tsinghua.edu.cn/simple',
  [string]$TorchMirror = 'https://mirror.sjtu.edu.cn/pytorch-wheels/cu128',
  [string]$TorchVersion = '2.11.0',
  [string]$TorchvisionVersion = '0.26.0',
  [string]$HfEndpoint = 'https://hf-mirror.com',
  [string]$PythonInstallerUrl = 'https://mirrors.huaweicloud.com/python/3.11.9/python-3.11.9-amd64.exe',
  [string]$SourceDir = '',         # 可选: 部署时顺便为这个素材目录批量建索引(不复制文件)
  [int]$MinVramGB = 8,
  [int]$MinDiskGB = 20,
  [switch]$Force,                  # 硬件/磁盘不满足时仍然继续
  [switch]$SkipAppInstall,         # 跳过桌面程序安装
  [switch]$NoShortcut,             # 不创建桌面快捷方式
  [switch]$Launch,                 # 部署完成后直接启动程序
  [switch]$DryRun                  # 只检测与打印计划, 不做任何安装/下载
)

$ErrorActionPreference = 'Stop'
$script:StepNo = 0
$script:LogFile = $null
$script:Skipped = @()
$script:LogLines = New-Object System.Collections.ArrayList

try { chcp 65001 > $null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'WeMM 素材检索 - 一键部署' } catch {}

# ================= 输出与日志 =================
function Write-Line {
  param([string]$Text, [string]$Color = 'Gray')
  Write-Host $Text -ForegroundColor $Color
  [void]$script:LogLines.Add($Text)
  if ($script:LogFile) {
    try {
      [System.IO.File]::AppendAllText($script:LogFile, ($Text + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
  }
}
function Info  { param([string]$t) Write-Line $t 'Gray' }
function Dim   { param([string]$t) Write-Line $t 'DarkGray' }
function Ok    { param([string]$t) Write-Line ('  [OK]   ' + $t) 'Green' }
function Warn  { param([string]$t) Write-Line ('  [注意] ' + $t) 'Yellow' }
function Bad   { param([string]$t) Write-Line ('  [失败] ' + $t) 'Red' }
function Step  {
  param([string]$t)
  $script:StepNo++
  Write-Line ''
  Write-Line ('==== ' + $script:StepNo + '. ' + $t + ' ====') 'Cyan'
}
function Skip  {
  param([string]$t)
  Write-Line ('  [跳过] ' + $t) 'DarkCyan'
  $script:Skipped += $t
}

function Pause-IfNeeded {
  if ($Host.Name -eq 'ConsoleHost' -and -not $env:WEMM_NO_PAUSE) {
    Write-Host ''
    Write-Host '按回车键关闭此窗口...' -ForegroundColor Yellow
    try { [void](Read-Host) } catch {}
  }
}

function Exit-WithError {
  param([string]$Msg, [int]$Code = 11)
  Write-Line ''
  Write-Line '----------------------------------------------------------------' 'Red'
  Write-Line ('部署未完成: ' + $Msg) 'Red'
  if ($script:LogFile) { Write-Line ('详细日志: ' + $script:LogFile) 'Yellow' }
  Write-Line '处理建议: 排除问题后, 再次双击「一键部署.bat」即可续跑, 已完成的环节不会重装。' 'Yellow'
  Write-Line '----------------------------------------------------------------' 'Red'
  Write-Line ''
  Pause-IfNeeded
  exit $Code
}

function Get-FreeGB {
  param([string]$Path)
  try {
    $qual = [System.IO.Path]::GetPathRoot($Path)
    $d = New-Object System.IO.DriveInfo($qual)
    return [math]::Round($d.AvailableFreeSpace / 1GB, 1)
  } catch { return -1 }
}
function Get-DirSizeGB {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return 0 }
  try {
    $s = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if (-not $s) { return 0 }
    return [math]::Round($s / 1GB, 2)
  } catch { return 0 }
}
function Run-OK {
  param([string]$Exe, [string[]]$ArgList)
  try {
    & $Exe @ArgList
    return ($LASTEXITCODE -eq 0)
  } catch {
    Write-Line ('  命令执行异常: ' + $_.Exception.Message) 'DarkYellow'
    return $false
  }
}
function Tail-Log {
  param([string]$Path, [int]$Lines = 15)
  if (-not (Test-Path $Path)) { return }
  Write-Line '  ---- 安装日志末尾(供排查) ----' 'DarkYellow'
  Get-Content $Path -Tail $Lines -Encoding UTF8 | ForEach-Object { Write-Line ('  | ' + $_) 'DarkYellow' }
  Write-Line '  ------------------------------' 'DarkYellow'
}

# ================= 健壮性辅助函数 =================
# 说明: 本脚本运行在 $ErrorActionPreference='Stop' 下, 任何一处"对空值做字符串方法"或
# "Join-Path 收到空路径"都会直接终止脚本。以下三个函数把这类风险统一收敛掉。

# 安全读取环境变量: 变量不存在/为空白时返回回退值, 绝不返回 $null
function Get-EnvValue {
  param([string]$Name, [string]$Fallback = '')
  try {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v -or ([string]$v).Trim() -eq '') { return $Fallback }
    return $v
  } catch { return $Fallback }
}

# 安全拼接路径: Base 为空(null/空串/空数组)时返回 $null(由调用方判空), 不再抛终止性错误
function Join-Safe {
  param($Base, $Child)
  if ($null -eq $Base) { return $null }
  try { $b = [string]$Base } catch { return $null }
  if ($null -eq $b -or $b.Trim() -eq '') { return $null }
  try {
    $c = [string]$Child
    if ($null -eq $c -or $c.Trim() -eq '') { return $b }
    return (Join-Path $b $c)
  } catch { return $null }
}

# 安全 Trim: 输入可能是 $null / 空数组(Read-Host 在输入被重定向时的返回值形态), 统一转字符串再 Trim
function Trim-Safe {
  param($Value)
  try {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
  } catch { return '' }
}

# 动态发现本机 Python 解释器: py 启动器注册表 -> where.exe -> Get-Command 三条路都试一遍,
# 返回 @( @(exe, @(前置参数...)), ... ); 找不到时返回空数组。用于覆盖"自定义安装路径/多版本共存"。
function Get-DynamicPythonCandidates {
  $found = New-Object System.Collections.ArrayList
  $eapD = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    # 1) py 启动器: py -0p 列出所有已注册解释器及真实路径(最可靠, 不依赖 PATH)
    try {
      $pyCmd = Get-Command 'py' -ErrorAction SilentlyContinue
      if ($pyCmd) {
        $rows = & py -0p 2>$null
        foreach ($row in @($rows)) {
          $s = [string]$row
          if ($s -match '([A-Za-z]:\\[^"' + "'" + '\r\n]*?python\.exe)') {
            [void]$found.Add(@($Matches[1].Trim(), @()))
          }
        }
      }
    } catch { }
    # 2) where.exe: PATH 上可能有多个 python
    foreach ($nm in @('python', 'python3')) {
      try {
        $rows = & where.exe $nm 2>$null
        foreach ($row in @($rows)) {
          $s = [string]$row
          if ($s -match '(?i)\.exe\s*$') { [void]$found.Add(@($s.Trim(), @())) }
        }
      } catch { }
    }
    # 3) Get-Command: 覆盖未被 where 命中的常规安装; WindowsApps 里的占位别名交给 Test-PythonAt 过滤
    foreach ($nm in @('python', 'python3', 'py')) {
      try {
        foreach ($it in @(Get-Command $nm -All -ErrorAction SilentlyContinue)) {
          $src = [string]$it.Source
          if ($src -and $src -match '(?i)\.exe\s*$') { [void]$found.Add(@($src.Trim(), @())) }
        }
      } catch { }
    }
  } catch { } finally {
    $ErrorActionPreference = $eapD
  }
  # 按可执行文件路径去重(忽略大小写), 保持发现顺序
  # 输出形式: 逐条写出字符串 "解释器路径|前置参数(空格分隔)", 例如
  #   "C:\Python311\python.exe|"、"py|-3.11"
  # 采用「逐条标量输出」而不是返回嵌套数组, 是为了避开 PowerShell 把函数返回值中
  # 的单元素数组自动展开的坑(那会让调用方 foreach 拿到字符串或数组, 行为不确定)。
  $seen = @{}
  foreach ($pair in $found) {
    $exeTxt = Trim-Safe $pair[0]
    if ($exeTxt -eq '') { continue }
    $key = $exeTxt.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $preTxt = ''
    if ($pair.Count -gt 1 -and $null -ne $pair[1]) {
      $preArr = @(@($pair[1]) | Where-Object { $null -ne $_ -and ([string]$_).Trim() -ne '' })
      if ($preArr.Count -gt 0) { $preTxt = ($preArr -join ' ') }
    }
    Write-Output ($exeTxt + '|' + $preTxt)
  }
}

# 把 Get-DynamicPythonCandidates 输出的 "exe|前置参数" 字符串解析成 @(exe, @(args)) 二元组
function ConvertTo-PythonCandidate {
  param($Item)
  $s = Trim-Safe $Item
  if ($s -eq '') { return $null }
  $segs = $s -split '\|'
  $exe = Trim-Safe $segs[0]
  if ($exe -eq '') { return $null }
  $pre = @()
  if ($segs.Count -gt 1) {
    $preTxt = Trim-Safe $segs[1]
    if ($preTxt -ne '') {
      $pre = @($preTxt.Split(' ') | Where-Object { (Trim-Safe $_) -ne '' })
    }
  }
  return ,@($exe, $pre)
}

# ================= 0. 参数与环境 =================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PackageRoot) { $PackageRoot = $scriptDir }
try {
  $PackageRoot = (Resolve-Path -LiteralPath $PackageRoot -ErrorAction Stop).Path
} catch {
  Exit-WithError ('无法定位分发包目录: ' + $PackageRoot + '  => 请确认 deploy_wemm.ps1 与 tools / installers 目录在同一文件夹内(不要单独把脚本复制出去运行)。')
}
$ToolsDir = Join-Path $PackageRoot 'tools'
$InstallerDir = Join-Path $PackageRoot 'installers'
$PortableDir = Join-Path $PackageRoot 'portable'
# 免安装绿色版程序来源: 默认取分发包里的 app\win-unpacked, 可用 -AppSourceDir 指定别处
$GreenAppSource = Join-Path $PackageRoot 'app\win-unpacked'
if ($AppSourceDir) { $GreenAppSource = $AppSourceDir }
$ManifestPath = Join-Path $ToolsDir 'model_manifest.json'
$LockPath = Join-Path $ToolsDir 'requirements-lock.txt'
$PyVerProbe = Join-Path $ToolsDir 'check_python.py'
$EnvProbe = Join-Path $ToolsDir 'check_env.py'
$InitIndexPy = Join-Path $ToolsDir 'init_index.py'
$DownloadModelPy = Join-Path $ToolsDir 'download_model.py'
$BuildIndexPy = Join-Path $ToolsDir 'build_index_local.py'

# 环境变量统一安全取值: 精简版镜像/受限账户下 ProgramFiles、LOCALAPPDATA、TEMP 等可能不存在,
# 这里缺失时回退到 .NET 的等效 API, 避免后续 Join-Path 收到空路径直接终止脚本。
$EnvLocalAppData    = Get-EnvValue 'LOCALAPPDATA' ([Environment]::GetFolderPath('LocalApplicationData'))
$EnvProgramFiles    = Get-EnvValue 'ProgramFiles'
$EnvProgramFilesX86 = Get-EnvValue 'ProgramFiles(x86)'
$EnvUserProfile     = Get-EnvValue 'USERPROFILE' ([Environment]::GetFolderPath('UserProfile'))
$EnvTempDir         = Get-EnvValue 'TEMP' ([System.IO.Path]::GetTempPath())
$EnvSystemDrive     = Get-EnvValue 'SystemDrive' 'C:'
# 桌面目录: 少数受限账户下 API 可能返回空, 这里给出基于用户目录的兜底, 保证快捷方式环节不因空路径报错
$DesktopDir = [Environment]::GetFolderPath('Desktop')
if (-not $DesktopDir) { $DesktopDir = Join-Safe $EnvUserProfile 'Desktop' }

$hasD = Test-Path 'D:\'
if (-not $InstallDir) { if ($hasD) { $InstallDir = 'D:\WeMM-Embedding' } else { $InstallDir = Join-Safe $EnvSystemDrive 'WeMM-Embedding' } }
if (-not $LibraryDir) { if ($hasD) { $LibraryDir = 'D:\Downloads' } else { $LibraryDir = Join-Safe $EnvUserProfile 'Downloads' } }
# 极端兜底: 若上一步仍没算出有效路径(环境变量全缺失), 用当前盘符拼一个, 保证后面不出现空串
if (-not $InstallDir) { $InstallDir = 'D:\WeMM-Embedding' }
if (-not $LibraryDir) { $LibraryDir = 'D:\Downloads' }
$InstallDir = ([string]$InstallDir).TrimEnd('\')
$LibraryDir = ([string]$LibraryDir).TrimEnd('\')

$VenvDir = Join-Path $InstallDir 'venv'
$VenvPy = Join-Path $VenvDir 'Scripts\python.exe'
$ModelDir = Join-Path $InstallDir 'models\WeMM-Embedding-4B'
$RunDir = Join-Path $InstallDir 'temp\index_run'
$PipLog = Join-Path $InstallDir 'pip_install.log'
$DlLog = Join-Path $InstallDir 'model_download.log'
$AppName = 'WeMM素材检索'

# 桌面程序内置的默认路径(与 electron main.js 一致); 不一致时必须用启动器写环境变量
$AppDefaultInstall = 'D:\WeMM-Embedding'
$AppDefaultLibrary = 'D:\Downloads'
$NeedLauncher = (($InstallDir -ne $AppDefaultInstall) -or ($LibraryDir -ne $AppDefaultLibrary))

if ($DryRun) {
  # 检测模式: 不创建部署目录, 日志落到系统临时目录, 保证干跑对环境零改动
  $script:LogFile = Join-Safe $EnvTempDir ('wemm_deploy_dryrun_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
} else {
  try {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  } catch {
    Exit-WithError ('无法创建部署目录 ' + $InstallDir + ' : ' + $_.Exception.Message + '  => 请换一个有写入权限的位置后重跑, 例如: 一键部署.bat -InstallDir E:\WeMM-Embedding')
  }
  $script:LogFile = Join-Safe $InstallDir ('deploy_log_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
}

Write-Line ''
Write-Line '==============================================================' 'Cyan'
Write-Line '        WeMM 素材检索  -  一键部署 (Windows)' 'Cyan'
Write-Line '==============================================================' 'Cyan'
Write-Line ''
Info '本脚本会自动完成: 环境检测 -> 独立 Python 环境 -> 后端依赖(国内镜像)'
Info '                    -> 下载 AI 模型权重(国内镜像) -> 索引初始化 -> 绿色版程序部署/快捷方式'
Info '全程无需你手动敲命令; 可重复运行, 已装好的环节会自动跳过。'
Info ''
Info ('部署目录 : ' + $InstallDir)
Info ('素材库   : ' + $LibraryDir)
Info ('日志文件 : ' + $script:LogFile)
if ($DryRun) { Warn '当前为【检测模式 -DryRun】: 只检测和打印计划, 不会安装或下载任何东西。' }

# ================= 1. 环境检测 =================
Step '环境检测 (显卡 / 显存 / 磁盘 / Python)'

$gpuName = ''; $gpuVramMB = 0; $gpuOK = $false
try {
  $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
  if ($smi) {
    # 原生程序 stderr 在 EAP=Stop 下被重定向会变成终止性错误, 这里临时降级
    $eapG = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null } catch { $raw = $null }
    $ErrorActionPreference = $eapG
    if ($raw) {
      $first = @($raw)[0]
      $parts = $first -split ','
      if ($parts.Count -ge 2) {
        # 用 Trim-Safe + TryParse, 避免 nvidia-smi 输出异常(空字段/非数字)时抛"不能对 Null 值表达式调用方法"
        $gpuName = Trim-Safe $parts[0]
        $vramTxt = Trim-Safe $parts[1]
        $vramVal = 0
        if ([int]::TryParse($vramTxt, [ref]$vramVal)) {
          $gpuVramMB = $vramVal
          # 8GB 显卡实际上报 8100~8190 MiB, 故留 512MB 容差, 避免把合格的 8GB 卡误判为不达标
          $vramNeedMB = ($MinVramGB * 1024) - 512
          if ($gpuVramMB -ge $vramNeedMB) { $gpuOK = $true }
        }
      }
    }
  }
} catch { }

if ($gpuOK) {
  Ok ('显卡: ' + $gpuName + '  显存: ' + [math]::Round($gpuVramMB / 1024, 1) + ' GB  (要求 >= ' + $MinVramGB + ' GB)')
} elseif ($gpuName) {
  Warn ('检测到 NVIDIA 显卡: ' + $gpuName + '  显存仅 ' + [math]::Round($gpuVramMB / 1024, 1) + ' GB, 低于建议的 ' + $MinVramGB + ' GB')
  Warn '显存不足时, 模型加载可能失败或搜索时爆显存(OutOfMemory)。'
} else {
  Warn '未检测到可用的 NVIDIA 显卡(nvidia-smi 不可用)。'
  Warn '本程序的后端推理在 cuda:0 上运行, 无 N 卡时无法运行。'
}
Info '硬件要求: NVIDIA 显卡 + 显存 >= 8GB + 磁盘可用空间 >= 20GB(建议 25GB)'
Info '降低要求的办法: (1) 换显存更大的显卡; (2) 使用 Windows 的 WSL/其他机器代替;'
Info '              (3) 如需纯 CPU 慢速运行, 需要改造后端(当前版本未内置 CPU 模式), 属于二次开发。'

if (-not $gpuOK -and -not $Force) {
  Warn '由于硬件不满足, 部署已暂停(未做任何改动)。'
  Warn '如果你仍要继续(例如机器上已装好环境, 只是暂时读不到显卡信息), 请重新运行并加参数 -Force。'
  Write-Host ''
  # 注意: Read-Host 在输入被重定向/关闭时会返回 $null(或空数组), 直接用 -notmatch 判断会失效,
  # 因此这里强制转成字符串再比较, 保证"未明确输入 Y"时一定会退出, 不会被静默跳过。
  $ansText = ''
  try {
    # Read-Host 在标准输入被重定向/关闭时会返回 $null 或空数组, 直接 .Trim() 会抛
    # "不能对 Null 值表达式调用方法"; 统一走 Trim-Safe(null 安全)并整体 try/catch 兜底。
    $rawAns = Read-Host '是否继续部署? 输入 Y 继续, 直接回车退出'
    $ansText = Trim-Safe $rawAns
  } catch { $ansText = '' }
  if ($ansText -notin @('y', 'Y', 'yes', 'Yes', 'YES', '是', '好')) {
    Write-Line ''
    Write-Line '已按你的选择退出, 未做任何改动。' 'Yellow'
    Pause-IfNeeded
    exit 2
  }
}

# --- 磁盘 ---
$freeGB = Get-FreeGB (Join-Path $InstallDir '.')
if ($freeGB -lt 0) { Exit-WithError ('部署目录所在磁盘不存在或不可访问: ' + $InstallDir) }
Info ('磁盘可用空间: ' + $freeGB + ' GB  (' + ([System.IO.Path]::GetPathRoot($InstallDir)) + ')')
if ($freeGB -lt $MinDiskGB) {
  Warn ('可用空间不足 ' + $MinDiskGB + ' GB, 无法容纳模型权重(约9.7GB)+依赖(约4GB)+索引/缩略图。')
  Warn '请清理磁盘, 或改用其它磁盘: 例如 一键部署.bat -InstallDir E:\WeMM-Embedding'
  if (-not $Force) { Exit-WithError '磁盘空间不足, 已终止。(如确认要强行继续, 请加参数 -Force)' 2 }
} else {
  Ok '磁盘空间充足'
}

# --- Python ---
function Test-PythonAt {
  param([string]$Exe, [string[]]$Pre = @())
  if (-not $Exe) { return $null }
  if ($Exe -match 'WindowsApps') { return $null }
  $eapP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    if ($Pre.Count -gt 0) {
      $v = & $Exe @Pre $PyVerProbe 2>$null
    } else {
      if (-not (Test-Path $Exe)) { $ErrorActionPreference = $eapP; return $null }
      $v = & $Exe $PyVerProbe 2>$null
    }
    if ($LASTEXITCODE -eq 0 -and $v -match '^3\.(10|11|12)$') { $ErrorActionPreference = $eapP; return (Trim-Safe $v) }
  } catch { }
  $ErrorActionPreference = $eapP
  return $null
}

$pyExe = $null; $pyVer = $null; $pyArgs = @()
$cands = @()

# 先做动态发现(py 启动器注册表 / where.exe / Get-Command), 覆盖自定义安装路径与多版本共存
foreach ($dyItem in @(Get-DynamicPythonCandidates)) {
  $dyPair = ConvertTo-PythonCandidate $dyItem
  if ($dyPair) { $cands += ,$dyPair }
}

# 再补上常见安装位置(部署目录自带的 Python / 用户级安装 / 系统级安装 / 固定盘位)
$cands += ,@((Join-Safe $InstallDir 'python311\python.exe'), @())
$cands += ,@('py', @('-3.11'))
$cands += ,@('py', @('-3.12'))
$cands += ,@('py', @('-3.10'))
$cands += ,@('python', @())
$cands += ,@('python3', @())
$cands += ,@((Join-Safe $EnvLocalAppData 'Programs\Python\Python311\python.exe'), @())
$cands += ,@((Join-Safe $EnvLocalAppData 'Programs\Python\Python312\python.exe'), @())
$cands += ,@((Join-Safe $EnvLocalAppData 'Programs\Python\Python310\python.exe'), @())
$cands += ,@((Join-Safe $EnvProgramFiles 'Python311\python.exe'), @())
$cands += ,@((Join-Safe $EnvProgramFiles 'Python312\python.exe'), @())
$cands += ,@((Join-Safe $EnvProgramFiles 'Python310\python.exe'), @())
$cands += ,@('C:\Python311\python.exe', @())
$cands += ,@('C:\Python312\python.exe', @())
$cands += ,@('C:\Python310\python.exe', @())

foreach ($c in $cands) {
  if ($null -eq $c) { continue }
  $exeCand = Trim-Safe $c[0]
  if ($exeCand -eq '') { continue }
  $preCand = @()
  if ($c.Count -gt 1 -and $null -ne $c[1]) { $preCand = @($c[1]) }
  $v = Test-PythonAt -Exe $exeCand -Pre $preCand
  if ($v) { $pyExe = $exeCand; $pyArgs = $preCand; $pyVer = $v; break }
}
if ($pyExe) {
  Ok ('已找到可用的 Python ' + $pyVer + ' : ' + $pyExe)
  Info '（后续依赖会装进独立虚拟环境, 不会污染系统 Python）'
} else {
  Warn '未找到可用的 Python (本程序需要 3.10 ~ 3.12 的 64 位版本)。'
  Info '已尝试的探测途径: py 启动器(py -0p) / where.exe / Get-Command / 用户与系统常见安装目录。'
  if ($DryRun) {
    Info ('检测模式: 正式运行时会自动下载并安装 Python 3.11.9 到 ' + (Join-Safe $InstallDir 'python311'))
    Warn '若自动安装失败: 可到 https://www.python.org/downloads/ 手动安装 Python 3.11 64 位(安装时务必勾选 Add python.exe to PATH), 然后重跑本脚本。'
  } else {
    Info '正在自动下载 Python 3.11.9 (国内镜像) 并安装到部署目录, 请稍候...'
    Info '（若自动安装失败: 可到 https://www.python.org/downloads/ 手动安装 Python 3.11 64 位, 勾选 Add python.exe to PATH 后重跑本脚本）'
    $pyInstaller = Join-Safe $EnvTempDir 'python-3.11.9-amd64.exe'
    if (-not $pyInstaller) { $pyInstaller = Join-Path ([System.IO.Path]::GetTempPath()) 'python-3.11.9-amd64.exe' }
    try {
      if (-not (Test-Path $pyInstaller)) {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $pyInstaller -TimeoutSec 600
      }
      Ok ('Python 安装包已就绪: ' + $pyInstaller)
    } catch {
      Exit-WithError ('下载 Python 安装包失败: ' + $_.Exception.Message + '  => 请手动安装 Python 3.11(勾选 Add to PATH)后重跑本脚本。下载地址: ' + $PythonInstallerUrl)
    }
    $pyTarget = Join-Path $InstallDir 'python311'
    $instArgs = '/quiet InstallAllUsers=0 PrependPath=0 Include_launcher=0 Include_pip=1 Include_test=0 Include_doc=0 Include_tcltk=0 Shortcuts=0 TargetDir="' + $pyTarget + '"'
    $instErr = ''
    try {
      $p = Start-Process -FilePath $pyInstaller -ArgumentList $instArgs -Wait -PassThru
      Info ('Python 安装程序退出码: ' + $p.ExitCode)
      if ($p.ExitCode -ne 0) { $instErr = '退出码 ' + $p.ExitCode }
    } catch {
      $instErr = $_.Exception.Message
    }
    if ($instErr) {
      Info ('提示: 静默安装未完全成功(' + $instErr + '), 继续尝试在常见位置查找已安装的 Python。')
    }
    # 安装器的 TargetDir 在部分场景会被忽略(例如该版本安装包在本机已注册过, 再次运行变成"修复/修改"),
    # 因此这里不写死目标路径, 而是依次探测所有常见位置, 找到可用的直接使用。
    $postCands = @()
    foreach ($dyItem in @(Get-DynamicPythonCandidates)) {
      $dyPair = ConvertTo-PythonCandidate $dyItem
      if ($dyPair) { $postCands += ,$dyPair }
    }
    foreach ($p in @(
      (Join-Safe $pyTarget 'python.exe'),
      (Join-Safe $EnvLocalAppData 'Programs\Python\Python311\python.exe'),
      (Join-Safe $EnvLocalAppData 'Programs\Python\Python312\python.exe'),
      (Join-Safe $EnvLocalAppData 'Programs\Python\Python310\python.exe'),
      (Join-Safe $EnvProgramFiles 'Python311\python.exe'),
      (Join-Safe $EnvProgramFiles 'Python312\python.exe'),
      (Join-Safe $EnvProgramFiles 'Python310\python.exe'),
      'C:\Python311\python.exe',
      'C:\Python312\python.exe',
      'C:\Python310\python.exe'
    )) {
      if ($p) { $postCands += ,@($p, @()) }
    }
    $postCount = $postCands.Count
    $pyExe = $null; $pyArgs = @(); $pyVer = $null
    foreach ($pair in $postCands) {
      $v = Test-PythonAt -Exe $pair[0] -Pre $pair[1]
      if ($v) { $pyExe = $pair[0]; $pyArgs = $pair[1]; $pyVer = $v; break }
    }
    if (-not $pyExe) {
      # 最后再试 py 启动器(它可能刚被安装器更新过)
      foreach ($t in @('-3.11', '-3.12', '-3.10')) {
        $v = Test-PythonAt -Exe 'py' -Pre @($t)
        if ($v) { $pyExe = 'py'; $pyArgs = @($t); $pyVer = $v; break }
      }
    }
    if (-not $pyExe) {
      Exit-WithError ('Python 自动安装后仍找不到可执行文件(已尝试 py 启动器 / where.exe / Get-Command 动态发现, 以及部署目录/用户目录/系统目录等 ' + $postCount + ' 处常见位置)。请手动安装 Python 3.11 64 位(安装时务必勾选 Add python.exe to PATH)后重新运行本脚本; 或手动把 Python 装到 ' + $pyTarget + ' 后重跑。下载地址: https://www.python.org/downloads/')
    }
    Ok ('Python ' + $pyVer + ' 可用: ' + $pyExe)
    if ($pyExe -ne 'py' -and ($pyExe -ne (Join-Path $pyTarget 'python.exe'))) {
      Info ('（说明: 安装器把 Python 装到了 ' + $pyExe + ', 后续将直接使用它, 不影响使用）')
    }
  }
}

if ($DryRun) {
  Write-Line ''
  Write-Line '---- 检测模式结果(不会做任何改动) ----' 'Cyan'
  $sVenv = '不存在, 将创建'; if (Test-Path $VenvPy) { $sVenv = '已存在, 将跳过创建' }
  $sDeps = '不存在, 将安装(基础依赖 + CUDA 版 PyTorch)'; if (Test-Path $VenvPy) { $sDeps = '待校验(能 import 且 CUDA 可用则跳过)' }
  $sModel = '不存在, 将下载(约9.7GB)'; if (Test-Path $ModelDir) { $sModel = '目录已存在, 将校验完整性(完整则跳过)' }
  $sRun = '不存在, 将初始化空索引'; if (Test-Path (Join-Path $RunDir 'index256.npy')) { $sRun = '已存在, 将跳过' }
  $sLib = '不存在, 将创建'; if (Test-Path $LibraryDir) { $sLib = '已存在, 将跳过' }
  Info ('虚拟环境 : ' + $VenvDir + '  ->  ' + $sVenv)
  Info ('依赖清单 : ' + $LockPath + '  ->  ' + $sDeps)
  Info ('模型权重 : ' + $ModelDir + '  ->  ' + $sModel)
  Info ('索引目录 : ' + $RunDir + '  ->  ' + $sRun)
  Info ('素材库   : ' + $LibraryDir + '  ->  ' + $sLib)
  $sApp = '不存在, 将复制免安装绿色版程序(约260MB)'; if (Test-Path (Join-Path $AppDir ($AppName + '.exe'))) { $sApp = '已存在, 将跳过' }
  Info ('桌面程序 : ' + $AppDir + '  ->  ' + $sApp)
  Write-Line ''
  Write-Line '检测模式结束, 未做任何改动。' 'Green'
  Pause-IfNeeded
  exit 0
}

# ================= 2. 独立 Python 环境 =================
Step '创建独立 Python 环境 (virtualenv)'

if (Test-Path $VenvPy) {
  Skip ('虚拟环境已存在: ' + $VenvDir)
} else {
  if (Test-Path $VenvDir) {
    $bak = $VenvDir + '_broken_' + (Get-Date -Format 'yyyyMMddHHmmss')
    Warn ('检测到不完整的虚拟环境目录, 已重命名备份为: ' + $bak)
    try { Rename-Item -Path $VenvDir -NewName (Split-Path -Leaf $bak) -Force } catch { Exit-WithError ('无法重命名残留目录, 请手动删除后重跑: ' + $VenvDir) }
  }
  Info ('正在创建虚拟环境: ' + $VenvDir)
  $ok = Run-OK -Exe $pyExe -ArgList ($pyArgs + @('-m', 'venv', $VenvDir))
  if (-not $ok -or -not (Test-Path $VenvPy)) {
    Exit-WithError ('创建虚拟环境失败。请检查磁盘权限/杀毒软件拦截, 也可手动执行: "' + $pyExe + '" -m venv "' + $VenvDir + '"')
  }
  Ok ('虚拟环境创建完成: ' + $VenvPy)
}

# ================= 3. 后端依赖 =================
Step '安装后端依赖 (pip 国内镜像 + CUDA 版 PyTorch)'

if (-not (Test-Path $LockPath)) { Exit-WithError ('缺少依赖清单文件: ' + $LockPath + ' (分发包不完整)') }
$EnvProbe = Join-Path $ToolsDir 'check_env.py'
if (-not (Test-Path $EnvProbe)) { Exit-WithError ('缺少环境自检脚本: ' + $EnvProbe + ' (分发包不完整)') }
$depsOK = $false
# 注意: PS5.1 在 EAP=Stop 下, 原生命令 stderr 一旦被重定向即成为终止性错误; torch 会往 stderr 打
# 无害告警(如 "triton not found"), 若不降级 EAP, 探测会误判为“依赖缺失”从而重复安装。实测踩过。
$eapBak = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$probe = @(); $prc = -1
try {
  $probe = & $VenvPy $EnvProbe 2>$null
  $prc = $LASTEXITCODE
} catch { $probe = @(); $prc = -1 }
$ErrorActionPreference = $eapBak

if ($prc -eq 0 -and ($probe -match 'MISSING=none') -and ($probe -match 'CUDA=OK')) { $depsOK = $true }
elseif (($probe -match 'MISSING=none') -and ($probe -match 'CUDA=NO')) {
  Warn '依赖已安装, 但 PyTorch 检测不到 CUDA 设备, 将重装 CUDA 版 PyTorch。'
}

if ($depsOK) {
  Skip '后端依赖已安装且 CUDA 可用'
} else {
  $common = @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input',
              '--retries', '5', '--timeout', '120', '--log', $PipLog)
  Info '【1/3】升级 pip ...'
  [void](Run-OK -Exe $VenvPy -ArgList ($common + @('--upgrade', 'pip', '-i', $PyMirror)))
  Info '【2/3】安装基础依赖(约 40 个包, 走清华镜像, 需要几分钟) ...'
  $ok = Run-OK -Exe $VenvPy -ArgList ($common + @('-r', $LockPath, '-i', $PyMirror))
  if (-not $ok) { Tail-Log $PipLog; Exit-WithError ('基础依赖安装失败(网络或镜像问题)。可重跑本脚本续装, 或手动执行: "' + $VenvPy + '" -m pip install -r "' + $LockPath + '" -i ' + $PyMirror) }
  Info '【3/3】安装 GPU 版 PyTorch (cu128, 约 2.6GB, 这个包较大请耐心等待) ...'
  # 说明: 该镜像是标准 PEP503 索引(每个包一个子目录), 必须用 --index-url 才能解析到子目录里的 whl;
  # 用 --find-links 指向索引根目录是找不到 torch 的(已实测)。--extra-index-url 保留清华源以补齐依赖包。
  $torchArgs = @(('torch==' + $TorchVersion + '+cu128'), ('torchvision==' + $TorchvisionVersion + '+cu128'),
                 '--index-url', $TorchMirror, '--extra-index-url', $PyMirror)
  $ok = Run-OK -Exe $VenvPy -ArgList ($common + $torchArgs)
  if (-not $ok) {
    Warn ('CUDA 镜像(' + $TorchMirror + ')安装失败, 改用 PyTorch 官方源重试(国内可能较慢)...')
    $off = 'https://download.pytorch.org/whl/cu128'
    $ok = Run-OK -Exe $VenvPy -ArgList ($common + @(('torch==' + $TorchVersion + '+cu128'), ('torchvision==' + $TorchvisionVersion + '+cu128'), '--index-url', $off, '--find-links', $off))
  }
  if (-not $ok) { Tail-Log $PipLog; Exit-WithError 'PyTorch(CUDA 版)安装失败。请检查网络后重跑本脚本(已下载部分会复用缓存)。' }

  $eapBak2 = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $probe = @(); $prc2 = -1
  try { $probe = & $VenvPy $EnvProbe 2>$null; $prc2 = $LASTEXITCODE } catch { $probe = @(); $prc2 = -1 }
  $ErrorActionPreference = $eapBak2
  if ($prc2 -ne 0) { Info ('依赖自检脚本返回码: ' + $prc2 + ' (仅作参考, 以模块缺失为准)') }
  if (-not ($probe -match 'MISSING=none')) { Exit-WithError ('依赖校验失败, 缺少模块。可手动执行查看: "' + $VenvPy + '" "' + $EnvProbe + '"') }
  if ($probe -notmatch 'CUDA=OK') {
    Exit-WithError 'PyTorch 已安装但检测不到 GPU(CUDA 不可用)。请确认: 1) 显卡为 NVIDIA 且驱动正常(命令行执行 nvidia-smi 有输出); 2) 未被安装成 CPU 版 torch。'
  }
  Ok '后端依赖安装完成, CUDA 可用'
}

# ================= 4. 模型权重 =================
Step '下载 AI 模型权重 WeMM-Embedding-4B (约 9.7GB)'

if (-not (Test-Path $ManifestPath)) { Exit-WithError ('缺少模型清单文件: ' + $ManifestPath + ' (分发包不完整)') }
$manifest = Get-Content $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$missing = 0; $mismatch = 0; $haveBytes = 0
foreach ($prop in $manifest.files.PSObject.Properties) {
  $fp = Join-Path $ModelDir $prop.Name
  if (-not (Test-Path $fp -PathType Leaf)) { $missing++; continue }
  $len = (Get-Item $fp).Length
  if ($prop.Value -gt 0 -and $len -ne $prop.Value) { $mismatch++ } else { $haveBytes += $len }
}
$totalGB = [math]::Round($manifest.total_bytes / 1GB, 2)

if ($missing -eq 0 -and $mismatch -eq 0) {
  Skip ('模型权重已完整(共 ' + @($manifest.files.PSObject.Properties).Count + ' 个文件, ' + $totalGB + 'GB): ' + $ModelDir)
} else {
  Info ('本地现状: 缺失 ' + $missing + ' 个文件, 大小不符 ' + $mismatch + ' 个, 已有 ' + [math]::Round($haveBytes / 1GB, 2) + 'GB / 共 ' + $totalGB + 'GB')
  Info ('使用国内镜像: ' + $HfEndpoint + '  (已强制 HF_HUB_DISABLE_XET=1, 避免大文件卡死)')
  $env:HF_ENDPOINT = $HfEndpoint
  $env:HF_HUB_DISABLE_XET = '1'
  $env:HF_HUB_ENABLE_HF_TRANSFER = '0'
  $dl = $DownloadModelPy
  if (-not (Test-Path $dl)) { Exit-WithError ('缺少模型下载脚本: ' + $dl + ' (分发包不完整)') }
  $env:PYTHONIOENCODING = 'utf-8'
  & $VenvPy $dl '--dir' $ModelDir '--log' $DlLog
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    Tail-Log $DlLog 20
    Exit-WithError ('模型权重下载未完成(返回码 ' + $rc + ')。下载支持断点续传, 直接重跑本脚本即可从断点继续, 不会从头下载。')
  }
  # 二次校验
  $missing = 0; $mismatch = 0
  foreach ($prop in $manifest.files.PSObject.Properties) {
    $fp = Join-Path $ModelDir $prop.Name
    if (-not (Test-Path $fp -PathType Leaf)) { $missing++; continue }
    if ($prop.Value -gt 0 -and (Get-Item $fp).Length -ne $prop.Value) { $mismatch++ }
  }
  if ($missing -gt 0 -or $mismatch -gt 0) { Exit-WithError ('模型权重校验未通过: 缺失 ' + $missing + ' 个, 大小不符 ' + $mismatch + ' 个。可重跑本脚本续传。') }
  Ok ('模型权重校验通过: ' + $ModelDir)
}

# ================= 5. 素材库与索引 =================
Step '初始化索引与素材库目录'

if (-not (Test-Path $LibraryDir)) {
  New-Item -ItemType Directory -Force -Path $LibraryDir | Out-Null
  Ok ('已创建素材库目录: ' + $LibraryDir)
} else {
  Ok ('素材库目录已存在: ' + $LibraryDir)
}

$env:PYTHONIOENCODING = 'utf-8'
$initOk = $false
try {
  & $VenvPy $InitIndexPy '--run' $RunDir
  if ($LASTEXITCODE -eq 0) { $initOk = $true }
  elseif ($LASTEXITCODE -eq 3) { Exit-WithError ('索引目录存在但已损坏, 脚本未做改动。请备份后删除该目录再重跑: ' + $RunDir) }
} catch { }

if ($initOk) {
  Ok ('索引目录就绪: ' + $RunDir)
} else {
  Warn '索引初始化脚本执行异常, 尝试直接创建最小索引...'
  New-Item -ItemType Directory -Force -Path $RunDir, (Join-Path $RunDir 'frames'), (Join-Path $RunDir 'rsz') | Out-Null
  $py = @'
import json, os, sys
import numpy as np
run = sys.argv[1]
np.save(os.path.join(run, "index256.npy"), np.zeros((0, 256), dtype=np.float32))
np.save(os.path.join(run, "index2560.npy"), np.zeros((0, 2560), dtype=np.float32))
json.dump([], open(os.path.join(run, "keys.json"), "w", encoding="utf-8"))
for n in ("assets.jsonl", "index_meta.jsonl"):
    open(os.path.join(run, n), "w", encoding="utf-8").close()
print("MIN_INDEX_OK")
'@
  $tmpPy = Join-Safe $EnvTempDir 'wemm_make_index.py'
  if (-not $tmpPy) { $tmpPy = Join-Path ([System.IO.Path]::GetTempPath()) 'wemm_make_index.py' }
  [System.IO.File]::WriteAllText($tmpPy, $py, (New-Object System.Text.UTF8Encoding($false)))
  & $VenvPy $tmpPy $RunDir
  if ($LASTEXITCODE -ne 0) { Exit-WithError ('索引目录创建失败: ' + $RunDir) }
  Ok ('索引目录已创建: ' + $RunDir)
}

if ($SourceDir) {
  if (Test-Path $SourceDir) {
    Info ('检测到 -SourceDir, 开始为已有素材目录批量建索引: ' + $SourceDir)
    Info '（该过程只读取你的文件并生成向量, 不会复制/移动/修改原文件; 支持中断后续跑）'
    & $VenvPy $BuildIndexPy '--src' $SourceDir '--run' $RunDir '--model' $ModelDir '--append'
    if ($LASTEXITCODE -ne 0) { Warn '批量建索引未成功完成, 可稍后重跑: 一键部署.bat -SourceDir "' + $SourceDir + '"' }
    else { Ok '批量建索引完成' }
  } else {
    Warn ('-SourceDir 指定的目录不存在, 已忽略: ' + $SourceDir)
  }
}

# ================= 6. 桌面程序 (免安装绿色版) =================
Step '部署桌面程序 (免安装绿色版)'

# 判断某个目录是否是一份完整可用的绿色版程序(以主程序 + Electron 关键资源为准)
function Test-GreenApp {
  param([string]$Dir)
  if (-not $Dir) { return $false }
  if (-not (Test-Path -PathType Leaf (Join-Path $Dir ($AppName + '.exe')))) { return $false }
  if (-not (Test-Path -PathType Leaf (Join-Path $Dir 'resources\app.asar'))) { return $false }
  if (-not (Test-Path -PathType Leaf (Join-Path $Dir 'resources\backend\server.py'))) { return $false }
  return $true
}

function Find-AppExe {
  $cands = @(
    (Join-Safe $EnvLocalAppData ('Programs\' + $AppName + '\' + $AppName + '.exe')),
    (Join-Safe $EnvLocalAppData ($AppName + '\' + $AppName + '.exe')),
    (Join-Safe $EnvProgramFiles ($AppName + '\' + $AppName + '.exe')),
    (Join-Safe $EnvProgramFilesX86 ($AppName + '\' + $AppName + '.exe')),
    (Join-Safe $PortableDir ($AppName + '.exe')),
    (Join-Safe $PortableDir ('win-unpacked\' + $AppName + '.exe'))
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return (Get-Item $c).FullName } }
  # 兜底: electron-builder 的安装目录名取自 package.json 的 name(例如 we-mm-search), 与
  # productName(WeMM素材检索) 并不一致, 所以仅在已知目录名里找会漏; 这里在常见安装根目录下按
  # 「程序名.exe」做一层目录扫描(很快), 兼容任意目录名。
  $roots = @(
    (Join-Safe $EnvLocalAppData 'Programs'),
    $EnvLocalAppData,
    $EnvProgramFiles,
    $EnvProgramFilesX86,
    $PortableDir
  )
  foreach ($r in $roots) {
    if (-not $r) { continue }
    if (-not (Test-Path $r)) { continue }
    try {
      $dirs = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)
      foreach ($d in $dirs) {
        $c1 = Join-Path $d.FullName ($AppName + '.exe')
        if (Test-Path $c1) { return (Get-Item $c1).FullName }
        $c2 = Join-Path $d.FullName ('win-unpacked\' + $AppName + '.exe')
        if (Test-Path $c2) { return (Get-Item $c2).FullName }
      }
    } catch { }
  }
  return $null
}

$appDest = Join-Path $AppDir ($AppName + '.exe')
$existingApp = Find-AppExe
$appExe = $null
$appMode = '已部署'

if (Test-GreenApp $AppDir) {
  $appExe = (Get-Item $appDest).FullName
  Skip ('桌面程序已就绪: ' + $appExe)
} elseif ($SkipAppInstall) {
  Warn '按参数要求跳过桌面程序部署(未检测到已部署的绿色版程序)。'
  $appMode = '未部署'
} elseif (Test-GreenApp $GreenAppSource) {
  Info '正在部署免安装绿色版程序(不写注册表, 复制完即可用)...'
  Info ('  来源: ' + $GreenAppSource)
  Info ('  目标: ' + $AppDir + '   约 260MB, 视磁盘速度约 10~60 秒, 请勿关闭窗口')
  try { New-Item -ItemType Directory -Force -Path $AppDir | Out-Null } catch {
    Exit-WithError ('无法创建程序目录 ' + $AppDir + ' : ' + $_.Exception.Message + '  => 可换位置后重跑, 例如: 一键部署.bat -AppDir E:\WeMM-App')
  }
  $rcCopy = 99
  try {
    $eapR = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & robocopy $GreenAppSource $AppDir /E /XF *.log /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
    $rcCopy = $LASTEXITCODE
    $ErrorActionPreference = $eapR
  } catch {
    $rcCopy = 99
    Write-Line ('  复制过程出现异常: ' + $_.Exception.Message) 'DarkYellow'
  }
  if (-not (Test-GreenApp $AppDir)) {
    Exit-WithError ('绿色版程序复制未完成(robocopy 返回码 ' + $rcCopy + ')。处理办法: 1) 检查磁盘空间与杀毒软件拦截; 2) 手动把分发包 app\win-unpacked 里的全部内容复制到 ' + $AppDir + '; 3) 重跑本脚本(其它环节会自动跳过)。')
  }
  $appExe = (Get-Item $appDest).FullName
  Ok ('桌面程序已部署(免安装绿色版): ' + $appExe)
} elseif (-not $existingApp) {
  $installer = $null
  if (Test-Path $InstallerDir) {
    $all = @(Get-ChildItem $InstallerDir -Filter '*.exe' -ErrorAction SilentlyContinue)
    $preferred = @($all | Where-Object { $_.Name -match '安装版|Setup|Installer' })
    if ($preferred.Count -gt 0) { $installer = $preferred | Sort-Object Name -Descending | Select-Object -First 1 }
    elseif ($all.Count -gt 0) { $installer = $all | Sort-Object Name -Descending | Select-Object -First 1 }
  }
  if (-not $installer) {
    Warn ('未找到安装包: ' + $InstallerDir + '\*.exe')
    Warn ('请把「' + $AppName + '-x.x.x-安装版-x64.exe」放到分发包的 installers 目录后重跑本脚本。')
    Warn '（其余环节已完成, 不影响后续手动安装）'
    $appMode = '未安装'
  } else {
    if ($DesktopDir) {
      $lnk = Join-Path $DesktopDir ($AppName + '.lnk')
      if (Test-Path $lnk) {
        $bak = Join-Path $DesktopDir ($AppName + '_备份_' + (Get-Date -Format 'yyyyMMddHHmmss') + '.lnk')
        try { Copy-Item $lnk $bak -Force; Info ('已备份原有桌面快捷方式为: ' + $bak) } catch {}
      }
    }
    Info ('正在静默安装桌面程序: ' + $installer.Name)
    Info '（安装过程约 10~60 秒, 期间桌面可能闪现窗口, 请勿关闭本窗口）'
    try {
      $p = Start-Process -FilePath $installer.FullName -ArgumentList '/S' -Wait -PassThru
      Info ('安装程序退出码: ' + $p.ExitCode)
    } catch {
      Warn ('静默安装调用失败: ' + $_.Exception.Message)
      Info '将尝试改为弹出安装向导, 请按提示点击完成安装...'
      try { Start-Process -FilePath $installer.FullName -Wait } catch {}
    }
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Seconds 3
      $appExe = Find-AppExe
      if ($appExe) { break }
    }
    if ($appExe) { Ok ('桌面程序安装完成: ' + $appExe) }
    else {
      $appMode = '未部署'
      Warn '静默安装后未找到程序文件。'
      Warn '解决建议: 手动双击 installers 目录里的安装包完成安装, 然后重跑本脚本(其余环节会全部跳过)。'
    }
  }
}
else {
  $appExe = $existingApp
  Skip ('检测到本机已安装的桌面程序: ' + $appExe)
}

# ================= 7. 启动器与快捷方式 =================
Step '创建启动器与桌面快捷方式'

if ($appExe) {
  $launchTarget = $appExe
  $launchWork = Split-Path -Parent $appExe
  if ($NeedLauncher) {
    $cmdPath = Join-Path $AppDir '启动WeMM素材检索.cmd'
    $lines = @(
      '@echo off',
      'rem 由一键部署脚本生成: 指定本机实际的 Python/索引/模型/素材库路径后启动程序',
      ('set "WEMM_PYTHON=' + $VenvPy + '"'),
      ('set "WEMM_RUN=' + $RunDir + '"'),
      ('set "WEMM_MODEL=' + $ModelDir + '"'),
      ('set "WEMM_DOWNLOADS=' + $LibraryDir + '"'),
      ('start "" "' + $appExe + '"')
    )
    try {
      [System.IO.File]::WriteAllText($cmdPath, ($lines -join "`r`n") + "`r`n", [System.Text.Encoding]::GetEncoding(936))
      Ok ('已生成启动器(含本机路径配置): ' + $cmdPath)
      $launchTarget = $cmdPath
      $launchWork = $AppDir
    } catch {
      Warn ('生成启动器失败: ' + $_.Exception.Message + '  => 快捷方式将直接指向程序, 若路径为默认值则仍可正常使用。')
    }
  } else {
    Skip '路径为程序内置默认值(D:\WeMM-Embedding + D:\Downloads), 无需额外启动器'
  }

  if ($NoShortcut) {
    Warn '按参数要求未创建桌面快捷方式。'
  } elseif (-not $DesktopDir) {
    Warn '未能定位桌面目录, 已跳过快捷方式创建(不影响使用, 可用部署生成的启动器进入程序)。'
  } else {
    $desktop = $DesktopDir
    $lnk = Join-Path $desktop ($AppName + '.lnk')
    $needWrite = $true
    if (Test-Path $lnk) {
      try {
        $sh = New-Object -ComObject WScript.Shell
        $old = $sh.CreateShortcut($lnk)
        if ($old.TargetPath -eq $launchTarget) { $needWrite = $false; Skip ('桌面快捷方式已存在且指向正确: ' + $lnk) }
        else {
          $bak = Join-Path $desktop ($AppName + '_备份_' + (Get-Date -Format 'yyyyMMddHHmmss') + '.lnk')
          Copy-Item $lnk $bak -Force
          Info ('原快捷方式指向 ' + $old.TargetPath + ', 已备份为 ' + (Split-Path -Leaf $bak))
        }
      } catch {}
    }
    if ($needWrite) {
      try {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnk)
        $sc.TargetPath = $launchTarget
        $sc.WorkingDirectory = $launchWork
        $sc.IconLocation = $appExe + ',0'
        $sc.Description = 'WeMM 素材检索'
        $sc.Save()
        Ok ('桌面快捷方式已创建: ' + $lnk)
      } catch {
        Warn ('创建桌面快捷方式失败: ' + $_.Exception.Message)
      }
    }
  }
} else {
  Warn '桌面程序未安装, 跳过快捷方式创建。'
}

# ================= 8. 总结 =================
Step '部署结果'

$modelGB = Get-DirSizeGB $ModelDir
$venvGB = Get-DirSizeGB $VenvDir
Write-Line ''
Write-Line ('  部署目录 : ' + $InstallDir)
Write-Line ('    - Python 环境 : ' + $VenvDir + '   (' + $venvGB + ' GB)')
Write-Line ('    - 模型权重     : ' + $ModelDir + '   (' + $modelGB + ' GB)')
Write-Line ('    - 索引目录     : ' + $RunDir)
Write-Line ('    - 素材库       : ' + $LibraryDir)
Write-Line ('    - 部署日志     : ' + $script:LogFile)
if ($appExe) {
  Write-Line ('  桌面程序 : ' + $appExe)
  Write-Line ('    - 程序目录     : ' + $AppDir + '   (免安装绿色版, 删除该目录即可卸载程序本体)')
} else { Write-Line '  桌面程序 : 未部署(见上面提示)' }
if ($script:Skipped.Count -gt 0) {
  Write-Line ''
  Write-Line ('  本次跳过(已就绪)的环节: ' + $script:Skipped.Count + ' 项') 'DarkCyan'
  foreach ($s in $script:Skipped) { Write-Line ('    - ' + $s) 'DarkCyan' }
}

Write-Line ''
Write-Line '  下一步怎么用:' 'White'
Write-Line ('   1) 双击桌面快捷方式「' + $AppName + '」启动程序(首次启动加载模型约 1 分钟, 界面会显示"模型加载中")')
Write-Line '   2) 把图片/视频拖进窗口, 点右上角「导入文件」, 等进度条走完即可被搜到'
Write-Line ('      (导入会把素材复制到素材库目录: ' + $LibraryDir + ')')
Write-Line '   3) 在搜索框输入中文描述(如"工厂流水线设备")回车, 即可按画面内容检索'
Write-Line '   4) 若已有大量素材不想再复制一份, 可用高级方式建立原位索引:'
Write-Line ('      一键部署.bat -SourceDir "你的素材目录"') 'DarkGray'
Write-Line ''
Write-Line '  常见问题:'
Write-Line '   - 首次搜索很慢: 模型预热需要 1~2 分钟, 之后正常。'
Write-Line '   - 提示显存不足: 关闭其它占显存的程序(浏览器视频/游戏/其它AI工具)后重试。'
Write-Line '   - 搜索不到刚导入的素材: 确认导入进度已完成, 再点一次搜索。'
Write-Line '   - 需要放行/被防火墙拦截: 本程序只在本机内部通信, 一般无需放行任何端口。'
Write-Line ''
Write-Line '==============================================================' 'Green'
Write-Line '  部署完成, 可以开始使用了。' 'Green'
Write-Line '==============================================================' 'Green'
Write-Line ''

if ($Launch) {
  if ($appExe) {
    Info '正在启动程序...'
    try {
      $target = if ($NeedLauncher -and (Test-Path (Join-Path $AppDir '启动WeMM素材检索.cmd'))) { Join-Path $AppDir '启动WeMM素材检索.cmd' } else { $appExe }
      Start-Process -FilePath $target | Out-Null
      Ok '程序已启动(窗口可能需要 10 秒左右出现)'
    } catch { Warn ('启动失败: ' + $_.Exception.Message) }
  } else {
    Warn '未安装桌面程序, 无法启动。'
  }
}

Pause-IfNeeded
exit 0
