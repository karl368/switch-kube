# ============================================
# 极简 Kubernetes 集群切换工具 switch-kube.ps1
# 新增：u=更新集群k3s地址；改用文本替换避免丢失insecure-skip-tls-verify配置
# 删减：清屏c、切换等待回车、自动备份配置
# ============================================
$KubeDir = Join-Path $HOME ".kube"
$ConfigFile = Join-Path $KubeDir "config"

# 截取纯净环境名称
function Get-ConfigDisplayName($fileObj) {
    return $fileObj.Name.Substring(8).Trim()
}

# 读取kube上下文，屏蔽报错
function Get-KubeContext($kubeConfigPath) {
    try {
        return kubectl --kubeconfig="$kubeConfigPath" config current-context 2>$null
    }
    catch {
        return $null
    }
}

# 打印分割线
function Print-SplitLine($color = "Cyan") {
    Write-Host "==========================================================" -ForegroundColor $color
}

# 加载可用配置，过滤损坏文件
function Load-KubeConfigs() {
    $allFiles = Get-ChildItem $KubeDir -File -ErrorAction SilentlyContinue
    $configList = @()
    foreach ($f in $allFiles) {
        if ($f.Name -like "config -*") {
            try {
                $null = Get-FileHash $f.FullName -Algorithm MD5 -ErrorAction Stop
                $configList += $f
            }
            catch {
                Write-Host "警告：跳过损坏配置文件 $($f.Name)" -ForegroundColor DarkYellow
            }
        }
    }
    return $configList | Sort-Object Name
}

# 文本替换更新server地址（纯文本操作，保留其他配置）
function Update-KubeServerUrl($filePath, $newIP) {
    try {
        # 读取原始文件内容
        $content = Get-Content $filePath -Raw -Encoding utf8
        $oldIPMatch = $content -match 'server: https://([\d\.]+):6443'
        $oldIP = if ($oldIPMatch) { $matches[1] } else { "未知" }
        $newServerLine = "  server: https://$newIP`:6443"
        # 正则匹配替换所有server行，只替换IP部分
        $newContent = $content -replace '  server: https://[\d\.]+:6443', $newServerLine
        # 写回文件
        Set-Content -Path $filePath -Value $newContent -Encoding utf8
        Write-Host "`n{oldIP} -> {newIP}: 服务地址已更新。" -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Host "文件修改失败：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# 主循环菜单
while ($true) {
    Clear-Host
    Print-SplitLine "Cyan"
    Write-Host "           Kubernetes 集群快速切换工具" -ForegroundColor Cyan
    Print-SplitLine "Cyan"
    Write-Host "【指令说明】数字=选择集群 | r=刷新列表 | u=更新集群地址 | q=退出" -ForegroundColor Gray
    Write-Host ""

    $hasMainConfig = Test-Path $ConfigFile
    $configs = Load-KubeConfigs

    if ($configs.Count -eq 0) {
        Write-Host "错误：未找到备用kube配置文件，命名格式必须为 config - 集群名" -ForegroundColor Red
        Read-Host "按回车继续"
        continue
    }

    # 获取主配置MD5哈希精准匹配当前集群
    $mainConfigHash = $null
    $currentTargetCfg = $null
    if ($hasMainConfig) {
        $mainConfigHash = (Get-FileHash $ConfigFile -Algorithm MD5).Hash
        # 找到当前生效对应的备用配置文件
        foreach ($cfg in $configs) {
            $h = (Get-FileHash $cfg.FullName -Algorithm MD5).Hash
            if ($h -eq $mainConfigHash) {
                $currentTargetCfg = $cfg
                break
            }
        }
    }

    # 打印集群列表
    $currentIndex = -1
    for ($i = 0; $i -lt $configs.Count; $i++) {
        $cfg = $configs[$i]
        $displayName = Get-ConfigDisplayName $cfg
        $lineText = "[$($i + 1)] $displayName"
        $isCurrent = $false

        if ($hasMainConfig) {
            $cfgHash = (Get-FileHash $cfg.FullName -Algorithm MD5).Hash
            if ($cfgHash -eq $mainConfigHash) {
                $currentIndex = $i
                $isCurrent = $true
                $lineText += "  (*当前集群)"
            }
        }

        if ($isCurrent) {
            Write-Host $lineText -ForegroundColor Green
        }
        else {
            Write-Host $lineText
        }
    }

    Print-SplitLine "Gray"
    # 当前集群状态展示
    if ($hasMainConfig -and $currentIndex -ge 0) {
        $curEnv = Get-ConfigDisplayName $configs[$currentIndex]
        Write-Host "当前生效集群：$curEnv" -ForegroundColor Green
        $curCtx = Get-KubeContext $ConfigFile
        Write-Host "上下文名称：$curCtx"
        try {
            $ns = kubectl config view --minify -o jsonpath='{..namespace}' 2>$null
            $ns = if ([string]::IsNullOrWhiteSpace($ns)) { "default" } else { $ns }
            Write-Host "默认命名空间：$ns"
        }
        catch { Write-Host "默认命名空间：读取失败" -ForegroundColor DarkYellow }
    }
    elseif ($hasMainConfig) {
        $ctx = Get-KubeContext $ConfigFile
        Write-Host "当前上下文：$ctx（无匹配备用配置）" -ForegroundColor DarkYellow
    }
    else {
        Write-Host "警告：不存在主配置文件 config，无法识别当前集群" -ForegroundColor DarkYellow
    }
    Print-SplitLine "Gray"

    $choice = Read-Host "请输入操作指令"
    switch ($choice.ToLower()) {
        "q" {
            Write-Host "已退出切换工具" -ForegroundColor Green
            exit 0
        }
        "r" { continue } # 刷新列表
        "u" {
            # 更新当前集群k3s地址逻辑
            if (-not $hasMainConfig) {
                Write-Host "`n错误：无主配置文件config，无法更新集群地址" -ForegroundColor Red
                Read-Host "按回车刷新列表"
                continue
            }
            if ($null -eq $currentTargetCfg) {
                Write-Host "`n错误：未匹配到当前集群对应的备用配置，无法修改" -ForegroundColor Red
                Read-Host "按回车刷新列表"
                continue
            }

            Write-Host "`n=== 更新k3s集群服务地址 ===" -ForegroundColor Cyan
            $newIp = Read-Host "请输入新的服务器IP（仅输入IP，无需https://端口）"
            # 简单IP格式校验
            if (-not ($newIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
                Write-Host "`n❌ IP格式不正确，请输入纯数字IP，例：192.168.1.100" -ForegroundColor Red
                Read-Host "按回车刷新列表"
                continue
            }
            $newServerUrl = "https://$newIp`:6443"

            # 1. 修改主config文件
            $res1 = Update-KubeServerUrl $ConfigFile $newIp
            # 2. 同步修改备用配置文件
            $res2 = Update-KubeServerUrl $currentTargetCfg.FullName $newIp

if ($res1 -and $res2) {
    Print-SplitLine "Green"
    Write-Host "✅ 集群地址更新成功！" -ForegroundColor Green
    Write-Host "新服务地址：$newServerUrl"
    Write-Host "已同步更新主配置与备用集群配置，保留所有原有证书/跳过tls配置"
    Print-SplitLine "Green"
            }
            else {
                Write-Host "`n❌ 更新地址失败，请检查文件权限或IP" -ForegroundColor Red
            }

            Write-Host "自动刷新集群列表..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 800
            continue
        }
        default {
            $targetConfig = $null
            # 数字选择
            if ($choice -match '^\d+$') {
                $idx = [int]$choice - 1
                if ($idx -ge 0 -and $idx -lt $configs.Count) {
                    $targetConfig = $configs[$idx]
                }
            }
            else {
                # 模糊关键词匹配
                $matchResult = $configs | Where-Object {
                    (Get-ConfigDisplayName $_).ToLower().Contains($choice.ToLower())
                }
                if ($matchResult.Count -eq 1) {
                    $targetConfig = $matchResult[0]
                }
                elseif ($matchResult.Count -gt 1) {
                    Write-Host "`n匹配到多个集群，请输入数字序号选择：" -ForegroundColor Yellow
                    $matchResult | ForEach-Object {
                        $idx = $configs.IndexOf($_) + 1
                        Write-Host "[$idx] $(Get-ConfigDisplayName $_)"
                    }
                    Read-Host "按回车刷新列表"
                    continue
                }
            }

            # 无效输入
            if ($null -eq $targetConfig) {
                Write-Host "`n输入无效，未匹配到任何集群配置！" -ForegroundColor Red
                Read-Host "按回车刷新列表"
                continue
            }

            # 重复切换当前集群判断
            if ($hasMainConfig) {
                $targetHash = (Get-FileHash $targetConfig.FullName -Algorithm MD5).Hash
                if ($targetHash -eq $mainConfigHash) {
                    Write-Host "`n当前已是该集群，无需重复切换" -ForegroundColor Yellow
                    Read-Host "按回车刷新列表"
                    continue
                }
            }

            # 直接覆盖主配置，移除备份逻辑
            Copy-Item $targetConfig.FullName $ConfigFile -Force
            $newEnvName = Get-ConfigDisplayName $targetConfig
            # 切换成功提示，自动刷新列表无等待回车
            Print-SplitLine "Green"
            Write-Host "✅ 集群切换完成！" -ForegroundColor Green
            Write-Host "当前环境：$newEnvName" -ForegroundColor Green
            $newCtx = Get-KubeContext $ConfigFile
            Write-Host "上下文：$newCtx"
            try {
                $newNs = kubectl config view --minify -o jsonpath='{..namespace}' 2>$null
                $newNs = if ([string]::IsNullOrWhiteSpace($newNs)) { "default" } else { $newNs }
                Write-Host "默认命名空间：$newNs"
            }
            catch {}
            Print-SplitLine "Green"
            Write-Host "自动刷新集群列表..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 700
            continue
        }
    }
}
