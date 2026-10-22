param(
    [string]$GameDir = "",
    [switch]$Uninstall,
    [switch]$DetectOnly
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload = Join-Path $here "payload"
$tools = Join-Path $here "tools"
$zstd = Join-Path $tools "zstd.exe"
$backupDir = Join-Path $here "backup\install_original"
$exeName = "WitchHand.exe"
$dataName = "data.win"
$patchName = "witchhand_1.1.data.zst"

$fontFiles = @(
    "fLarge.yy", "fLargeALT.yy", "fLarger.yy", "fLargerALT.yy",
    "fMedium.yy", "fMediumALT.yy", "fMediumish.yy", "fMediumishALT.yy",
    "fSmall.yy", "fSmallALT.yy", "fSmallMedium.yy", "fSmallMediumALT.yy"
)
$files = @($dataName, "game_strings.csv", "card_stats.csv") + $fontFiles

# WitchHand 1.10c (Steam) 原版与汉化 1.1 的 data.win 哈希
$baseDataHash = "7417130ACBBBD9C369732644B03DF385B78AA6AAA8ABC6C8862CC718AC2FC072"
$targetDataHash = "61C0680CC716AFDF29D194E155E3371FDAF6B0E8160B8128B6754501E6DDABFC"
$patchHash = "6B6E57248D01A3A8BE75E0E376BE8549CC06E699B1F3F75671B2135F218996FF"

$utf8 = [System.Text.Encoding]::UTF8
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

$exePairs = @(
    @{ Old = 'Bring Potion cards here to purchase a new spell. Shift+Click to auto-purchase with existing Potions.'; New = '把药水卡牌拖到这里购买新法术。按住 Shift 单击可使用现有药水自动购买。' },
    @{ Old = 'Bring Stardrop Coin cards here to purchase an Explore card. Shift+Click to auto-purchase with existing Stardrop Coins.'; New = '把星滴币卡牌拖到这里购买探索卡。按住 Shift 单击可使用现有星滴币自动购买。' },
    @{ Old = 'Bring cards here to sell them. Use "'; New = '把卡牌拖到这里出售。请按' },
    @{ Old = '" on cards to auto-sell them.'; New = ' 可自动出售。' }
)

function Fail([string]$msg) {
    Write-Host ""
    Write-Host "错误：$msg" -ForegroundColor Red
    exit 1
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Find-WitchHand {
    $roots = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try { $steam = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if (-not $steam) {
        try { $steam = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch {}
    }
    if ($steam) { $roots.Add($steam) }

    foreach ($root in $roots.ToArray()) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            try {
                $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
                foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                    $p = $m.Groups[1].Value.Replace('\\', '\')
                    if (-not $roots.Contains($p)) { $roots.Add($p) }
                }
            } catch {}
        }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $c = Join-Path $root 'steamapps\common\WitchHand'
        if ((Test-Path -LiteralPath (Join-Path $c 'WitchHand.exe')) -and -not $candidates.Contains($c)) {
            $candidates.Add($c)
        }
    }
    foreach ($c in $candidates) {
        $dw = Join-Path $c $dataName
        if (Test-Path -LiteralPath $dw) {
            try {
                $h = Get-Sha256 $dw
                if ($h -eq $baseDataHash -or $h -eq $targetDataHash) { return $c }
            } catch {}
        }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $null
}

function Find-Bytes([byte[]]$Hay, [byte[]]$Needle) {
    if ($Needle.Length -eq 0 -or $Hay.Length -lt $Needle.Length) { return -1 }
    $max = $Hay.Length - $Needle.Length
    $i = 0
    while ($i -le $max) {
        $i = [Array]::IndexOf($Hay, $Needle[0], $i)
        if ($i -lt 0 -or $i -gt $max) { return -1 }
        $ok = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Hay[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
        $i++
    }
    return -1
}

function Patch-Exe([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $changed = $false
    foreach ($pair in $exePairs) {
        $oldBytes = $latin1.GetBytes($pair.Old)
        $newBytes = $utf8.GetBytes($pair.New)
        $o = Find-Bytes $bytes $oldBytes
        if ($o -lt 0) {
            if ((Find-Bytes $bytes $newBytes) -ge 0) {
                Write-Host "  悬浮提示已是中文：$($pair.New.Substring(0, [Math]::Min(12, $pair.New.Length)))..."
            } else {
                Write-Host "  警告：未找到待汉化字符串，游戏版本可能已更新。" -ForegroundColor Yellow
            }
            continue
        }
        $end = $o + $oldBytes.Length
        $j = $end
        while ($j -lt $bytes.Length -and $bytes[$j] -eq 0) { $j++ }
        $capacity = $j - $o - 1
        if ($newBytes.Length -gt $capacity) {
            Write-Host "  警告：译文过长，跳过该提示。" -ForegroundColor Yellow
            continue
        }
        for ($k = 0; $k -lt $newBytes.Length; $k++) { $bytes[$o + $k] = $newBytes[$k] }
        for (; $k -lt $capacity; $k++) { $bytes[$o + $k] = 0x20 }
        $bytes[$o + $capacity] = 0
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllBytes($Path, $bytes)
        Write-Host "  已汉化悬浮提示文本（WitchHand.exe）"
    }
}

if (Get-Process -Name "WitchHand" -ErrorAction SilentlyContinue) {
    Fail "游戏正在运行，请先完全退出游戏再执行。"
}

if (-not $GameDir) {
    $found = Find-WitchHand
    if ($found) {
        $GameDir = $found
        Write-Host "已找到游戏目录：$GameDir"
    }
}
if (-not $GameDir) {
    Write-Host "未能自动找到 WitchHand 游戏目录。"
    $GameDir = Read-Host "请粘贴游戏文件夹路径（例如 D:\SteamLibrary\steamapps\common\WitchHand）"
}
$GameDir = $GameDir.Trim()
if ($GameDir.StartsWith('"') -and $GameDir.EndsWith('"') -and $GameDir.Length -ge 2) {
    $GameDir = $GameDir.Substring(1, $GameDir.Length - 2).Trim()
}
if (-not (Test-Path -LiteralPath $GameDir)) { Fail "游戏目录不存在：$GameDir" }
$GameDir = (Resolve-Path -LiteralPath $GameDir).Path
if (-not (Test-Path -LiteralPath (Join-Path $GameDir $exeName))) {
    Fail "目录中没有 WitchHand.exe，请确认路径：$GameDir"
}

$dataPath = Join-Path $GameDir $dataName
$exePath = Join-Path $GameDir $exeName
if (-not (Test-Path -LiteralPath $dataPath)) { Fail "目录中没有 data.win，请确认路径：$GameDir" }
$currentHash = Get-Sha256 $dataPath

if ($DetectOnly) {
    Write-Host "游戏目录：$GameDir"
    Write-Host "data.win SHA-256：$currentHash"
    if ($currentHash -eq $baseDataHash) { Write-Host "版本状态：原版 1.10c（可安装本补丁）" }
    elseif ($currentHash -eq $targetDataHash) { Write-Host "版本状态：已安装汉化 1.1" }
    else { Write-Host "版本状态：未知（本补丁不支持此版本）" -ForegroundColor Yellow }
    exit 0
}

if ($Uninstall) {
    $backupData = Join-Path $backupDir $dataName
    if (-not (Test-Path -LiteralPath $backupData)) {
        Fail "找不到原版备份：$backupDir`n如果备份丢失，可在 Steam 中右键游戏 → 属性 → 已安装文件 → 验证游戏文件完整性，恢复英文原版。"
    }
    if ((Get-Sha256 $backupData) -ne $baseDataHash) {
        Fail "备份中的 data.win 校验失败，为避免损坏游戏，已停止还原。请用 Steam 验证游戏文件完整性恢复原版。"
    }
    if ($currentHash -ne $baseDataHash -and $currentHash -ne $targetDataHash) {
        Fail "当前 data.win 不是已知的 1.10c 版本（游戏可能已更新）。为避免降级，已停止还原。建议用 Steam 验证游戏文件完整性恢复原版。"
    }
    foreach ($f in $files + $exeName) {
        if (-not (Test-Path -LiteralPath (Join-Path $backupDir $f))) { Fail "备份缺少文件：$f" }
    }
    foreach ($f in $files + $exeName) {
        Copy-Item -LiteralPath (Join-Path $backupDir $f) -Destination (Join-Path $GameDir $f) -Force
        Write-Host "已还原 $f"
    }
    Write-Host ""
    Write-Host "卸载完成，游戏已还原为英文原版。" -ForegroundColor Green
    Write-Host "备份保留在：$backupDir"
    exit 0
}

foreach ($f in $files) {
    if ($f -eq $dataName) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $payload $f))) { Fail "安装包不完整，缺少 payload\$f" }
}
if (-not (Test-Path -LiteralPath $zstd)) { Fail "安装包不完整，缺少 tools\zstd.exe" }
$patchPath = Join-Path $payload $patchName
if (-not (Test-Path -LiteralPath $patchPath)) { Fail "安装包不完整，缺少 payload\$patchName" }
if ((Get-Sha256 $patchPath) -ne $patchHash) { Fail "补丁文件校验失败，安装包可能损坏，请重新解压。" }

$already = ($currentHash -eq $targetDataHash)
if (-not $already -and $currentHash -ne $baseDataHash) {
    Write-Host ""
    Write-Host "这个补丁只支持 WitchHand 1.10c（Steam）。" -ForegroundColor Yellow
    Write-Host "你的 data.win 版本不匹配，安装已停止，未修改任何文件。" -ForegroundColor Yellow
    Write-Host "  期望原版 SHA-256：$baseDataHash"
    Write-Host "  当前 SHA-256：    $currentHash"
    Write-Host ""
    Write-Host "如果游戏刚更新过，请等待对应版本的汉化补丁。"
    exit 1
}

$missing = @()
foreach ($f in $files + $exeName) {
    if (-not (Test-Path -LiteralPath (Join-Path $GameDir $f))) { $missing += $f }
}
if ($missing.Count -gt 0) { Fail ("游戏目录缺少文件：" + ($missing -join ", ")) }

if (-not (Test-Path -LiteralPath (Join-Path $backupDir $dataName))) {
    if ($currentHash -eq $baseDataHash) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        foreach ($f in $files + $exeName) {
            Copy-Item -LiteralPath (Join-Path $GameDir $f) -Destination (Join-Path $backupDir $f) -Force
        }
        if ((Get-Sha256 (Join-Path $backupDir $dataName)) -ne $baseDataHash) {
            Fail "创建备份失败，已停止安装。"
        }
        Write-Host "已备份原文件到：$backupDir"
    } else {
        Write-Host "注意：未找到原版备份，且当前 data.win 已是汉化版，本次不创建新备份。" -ForegroundColor Yellow
        Write-Host "如需卸载，请先用 Steam 验证游戏文件完整性恢复原版。" -ForegroundColor Yellow
    }
} else {
    Write-Host "已存在原版备份，跳过备份：$backupDir"
}

if (-not $already) {
    $tmp = Join-Path $env:TEMP ("witchhand_cn_" + [Guid]::NewGuid().ToString("N") + ".win")
    Write-Host "正在应用补丁（约需要几秒钟）..."
    & $zstd -d "--patch-from=$dataPath" -f "$patchPath" -o "$tmp"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Fail "补丁应用失败。游戏文件未被修改，请确认游戏未运行后重试。"
    }
    $newHash = Get-Sha256 $tmp
    if ($newHash -ne $targetDataHash) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Fail "补丁结果校验失败。游戏文件未被修改，请重新解压安装包后重试。"
    }
    Copy-Item -LiteralPath $tmp -Destination $dataPath -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "已更新 data.win（字体与文本）"
} else {
    Write-Host "data.win 已是汉化版，跳过补丁"
}

foreach ($f in $files) {
    if ($f -eq $dataName) { continue }
    Copy-Item -LiteralPath (Join-Path $payload $f) -Destination (Join-Path $GameDir $f) -Force
    Write-Host "已安装 $f"
}

Write-Host "正在处理悬浮提示文本..."
Patch-Exe $exePath

Write-Host ""
Write-Host "汉化 1.1 安装完成。" -ForegroundColor Green
Write-Host "原文件备份：$backupDir"
Write-Host "如需还原，运行 uninstall.bat。"
Write-Host "注意：Steam 验证完整性或游戏更新会覆盖汉化，重新运行 install.bat 即可。"
exit 0
