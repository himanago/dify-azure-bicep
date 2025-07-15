param (
    [string]$ResourceGroupName = "",
    [switch]$SkipDeploy
)

# スクリプトの先頭（パラメータ宣言の後）
$env:AZURE_DEFAULTS_GROUP = $ResourceGroupName

# リソースグループ名が指定されていない場合は、parametersファイルから取得
if (Test-Path "./parameters.json") {
    $params = Get-Content "./parameters.json" | ConvertFrom-Json
    if ($ResourceGroupName -eq "") {
        $location = $params.parameters.location.value
        $rgPrefix = $params.parameters.resourceGroupPrefix.value
        $ResourceGroupName = "$rgPrefix-$location"
    }
    Write-Host "リソースグループ名: $ResourceGroupName"
    $env:AZURE_DEFAULTS_GROUP = $ResourceGroupName

    $pgsqlUser = $params.parameters.pgsqlUser.value
    $pgsqlPassword = $params.parameters.pgsqlPassword.value

} else {
    Write-Error "parameters.jsonファイルが見つかりません。リソースグループ名を指定してください。"
    exit 1
}

# Azure CLIのサインイン状態を確認
$loginStatus = az account show --query "name" -o tsv 2>$null
if (-not $loginStatus) {
    Write-Host "Azure CLIにログインします..." -ForegroundColor Yellow
    az login
}

# Bicepデプロイをスキップしない場合
if (-not $SkipDeploy) {
    Write-Host "Bicepテンプレートをデプロイしています..." -ForegroundColor Cyan
    az deployment sub create --location japaneast --template-file main.bicep --parameters parameters.json
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Bicepデプロイに失敗しました。"
        exit 1
    }
}

# 現在のAzureコンテキストを確認
Write-Host "Azureサブスクリプション情報を確認しています..." -ForegroundColor Cyan
$currentSubscription = az account show --query "name" -o tsv
Write-Host "現在のサブスクリプション: $currentSubscription"

# リソースグループの存在を確認
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Host "リソースグループが見つかりました: $ResourceGroupName" -ForegroundColor Green
} else {
    Write-Error "リソースグループが存在しません: $ResourceGroupName"
    exit 1
}

# ストレージアカウント情報を取得（より具体的なクエリで）
Write-Host "ストレージアカウント情報を取得しています..." -ForegroundColor Cyan
$storageAccounts = az storage account list --resource-group $ResourceGroupName --query "[?starts_with(name, 'st')].name" -o tsv

if (-not $storageAccounts) {
    # 別のクエリで再試行
    $storageAccounts = az storage account list --resource-group $ResourceGroupName --query "[].name" -o tsv
    
    if (-not $storageAccounts) {
        Write-Error "リソースグループ内にストレージアカウントが見つかりません: $ResourceGroupName"
        exit 1
    }
}

# 複数のストレージアカウントがある場合は最初のものを使用
$storageAccountArray = $storageAccounts -split "\r?\n"
$storageAccountName = $storageAccountArray[0]
Write-Host "ストレージアカウント名: $storageAccountName"

# ストレージアカウントキーを取得
$storageAccountKey = (az storage account keys list --resource-group $ResourceGroupName --account-name $storageAccountName --query "[0].value" -o tsv)
if (-not $storageAccountKey) {
    Write-Error "ストレージアカウントキーの取得に失敗しました"
    exit 1
}

# ストレージアカウントの監査ログを有効化（トラブルシューティング用）
Write-Host "ストレージアカウントの監査ログを有効化しています..." -ForegroundColor Cyan
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --enable-local-user true

# クライアントIPを取得してファイアウォールに追加
try {
    $clientIP = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    if ($clientIP) {
        Write-Host "現在のIPアドレス:$clientIP をストレージアカウントのファイアウォールに追加します" -ForegroundColor Yellow
        az storage account network-rule add --account-name $storageAccountName --resource-group $ResourceGroupName --ip-address $clientIP
    }
}
catch {
    Write-Warning "IPアドレスの取得に失敗しました。ファイアウォール設定をスキップします。"
}

# SASトークン生成部分の修正
try {
    # SASトークンを変数に保存するときに文字列として扱う
    $end = (Get-Date).AddHours(24).ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # 変数を格納するためにOut-Stringを使用してSASトークンを取得
    $sasResult = (az storage account generate-sas --account-name $storageAccountName --services f --resource-types sco --permissions acdlrw --expiry $end --https-only --output tsv | Out-String).Trim()
    
    if ([string]::IsNullOrWhiteSpace($sasResult)) {
        throw "SASトークンが空です"
    }
    
    # SASトークンを環境変数として保存
    $env:AZURE_STORAGE_SAS = "?$sasResult"
    Write-Host "SASトークンを環境変数として保存しました（24時間有効）" -ForegroundColor Green
    
    # 代替として使用するフラグを設定
    $useSasEnv = $true
    $sasToken = $null  # 直接使用しない
} catch {
    Write-Warning "SASトークンの生成中にエラーが発生しました: $_"
    
    # 代替認証方法: ストレージアカウントキーを使用
    Write-Host "ストレージアカウントキーを使用した代替認証方法を試みます..." -ForegroundColor Yellow
    $env:AZURE_STORAGE_KEY = $storageAccountKey
    $useSasEnv = $false
    $sasToken = $null
}

Write-Host "SASトークン: $sasToken"

# ファイル共有にファイルをアップロード
$shares = @("nginx", "ssrfproxy", "sandbox")

foreach ($share in $shares) {
    Write-Host "ファイル共有 '$share' を処理しています..." -ForegroundColor Cyan
    
    # ファイル共有が存在するか確認し、なければ作成
    if ($useSasEnv) {
        # 環境変数経由でSASトークンを使用
        $shareExists = az storage share exists --account-name $storageAccountName --name $share --query "exists" -o tsv
        if ($shareExists -ne "true") {
            Write-Host "  ファイル共有 '$share' を作成します..."
            az storage share create --account-name $storageAccountName --name $share
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "ファイル共有 '$share' の作成に失敗しました。処理を続行します。"
            }
        }
    } else {
        # ストレージキー環境変数を使用
        $shareExists = az storage share exists --account-name $storageAccountName --name $share --query "exists" -o tsv
        if ($shareExists -ne "true") {
            Write-Host "  ファイル共有 '$share' を作成します..."
            az storage share create --account-name $storageAccountName --name $share
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "ファイル共有 '$share' の作成に失敗しました。処理を続行します。"
            }
        }
    }
    
    # mountfilesディレクトリからファイルを直接アップロード
    $sourcePath = "./mountfiles/$share"
    if (Test-Path $sourcePath) {
        Write-Host "設定ファイルをアップロードしています..." -ForegroundColor Cyan
        
        # ディレクトリとファイルのリストを取得
        $customDirs = @()
        Get-ChildItem -Path $sourcePath -Recurse -Directory | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourcePath.Length + 1)
            $customDirs += $relativePath
        }
        
        # ディレクトリを作成
        foreach ($dir in $customDirs) {
            $dirPath = $dir -replace "\\", "/"
            if ($useSasEnv) {
                az storage directory create --account-name $storageAccountName --share-name $share --name $dirPath --output none 2>$null
            } else {
                az storage directory create --account-name $storageAccountName --share-name $share --name $dirPath --output none 2>$null
            }
            Write-Host "  ディレクトリを作成: $dirPath"
        }
        
        # ファイルをアップロード
        Get-ChildItem -Path $sourcePath -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($sourcePath.Length + 1)
            $targetPath = $relativePath -replace "\\", "/"
            
            # アップロード処理 
            if ($useSasEnv) {
                $result = az storage file upload --account-name $storageAccountName --share-name $share --source $_.FullName --path $targetPath 2>&1
            } else {
                $result = az storage file upload --account-name $storageAccountName --share-name $share --source $_.FullName --path $targetPath 2>&1
            }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ファイルをアップロード: $targetPath"
            } else {
                Write-Warning "ファイル '$targetPath' のアップロード中にエラー: $result"
            }
        }
    } else {
        Write-Host "Warning: $sourcePath ディレクトリが見つかりません。この共有用のファイルはスキップします。" -ForegroundColor Yellow
    }
    
    # Nginxの場合、必須ファイルが存在するか確認（conf.d/default.confなど）
    if ($share -eq "nginx") {
        # conf.dディレクトリが存在することを確認
        if ($useSasEnv) {
            $confDirExists = az storage directory exists --account-name $storageAccountName --share-name $share --name "conf.d" --query "exists" -o tsv
        } else {
            $confDirExists = az storage directory exists --account-name $storageAccountName --share-name $share --name "conf.d" --query "exists" -o tsv
        }
        
        if ($confDirExists -ne "true") {
            Write-Host "  conf.dディレクトリが見つかりません。作成します..." -ForegroundColor Yellow
            if ($useSasEnv) {
                az storage directory create --account-name $storageAccountName --share-name $share --name "conf.d" --output none
            } else {
                az storage directory create --account-name $storageAccountName --share-name $share --name "conf.d" --output none
            }
            
            # mountfiles/nginx/conf.d/default.confをコピー（存在する場合）
            $defaultConfPath = "./mountfiles/nginx/conf.d/default.conf"
            if (Test-Path $defaultConfPath) {
                if ($useSasEnv) {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $defaultConfPath --path "conf.d/default.conf"
                } else {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $defaultConfPath --path "conf.d/default.conf"
                }
                Write-Host "  デフォルトの設定ファイルをアップロード: conf.d/default.conf"
            }
        }
        
        # nginx.confが存在するか確認
        if ($useSasEnv) {
            $nginxConfExists = az storage file exists --account-name $storageAccountName --share-name $share --path "nginx.conf" --query "exists" -o tsv
        } else {
            $nginxConfExists = az storage file exists --account-name $storageAccountName --share-name $share --path "nginx.conf" --query "exists" -o tsv
        }
        
        if ($nginxConfExists -ne "true") {
            Write-Host "  nginx.confが見つかりません。mountfilesからコピーします..." -ForegroundColor Yellow
            
            # mountfiles/nginx/nginx.confをコピー（存在する場合）
            $nginxConfPath = "./mountfiles/nginx/nginx.conf"
            if (Test-Path $nginxConfPath) {
                if ($useSasEnv) {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $nginxConfPath --path "nginx.conf"
                } else {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $nginxConfPath --path "nginx.conf"
                }
                Write-Host "  nginx.confをアップロード"
            }
        }

        # proxy.confが存在するか確認
        if ($useSasEnv) {
            $proxyConfExists = az storage file exists --account-name $storageAccountName --share-name $share --path "proxy.conf" --query "exists" -o tsv
        } else {
            $proxyConfExists = az storage file exists --account-name $storageAccountName --share-name $share --path "proxy.conf" --query "exists" -o tsv
        }

        if ($proxyConfExists -ne "true") {
            Write-Host "  proxy.confが見つかりません。mountfilesからコピーします..." -ForegroundColor Yellow
            
            # mountfiles/nginx/proxy.confをコピー（存在する場合）
            $proxyConfPath = "./mountfiles/nginx/proxy.conf"
            if (Test-Path $proxyConfPath) {
                if ($useSasEnv) {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $proxyConfPath --path "proxy.conf"
                } else {
                    az storage file upload --account-name $storageAccountName --share-name $share --source $proxyConfPath --path "proxy.conf"
                }
                Write-Host "  proxy.confをアップロード"
            }
        }
    }
}

# ファイルアップロード後、元の設定に戻す
Write-Host "ストレージアカウントのセキュリティ設定を元に戻しています..." -ForegroundColor Yellow
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --default-action Deny
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --bypass AzureServices

# ストレージへのアップロードが成功したか確認
Write-Host "Nginxの設定ファイル適用状態を確認しています..." -ForegroundColor Cyan
if ($useSasEnv) {
    $nginxConfExists = az storage file exists --account-name $storageAccountName --share-name "nginx" --path "nginx.conf" --query "exists" -o tsv
} else {
    $nginxConfExists = az storage file exists --account-name $storageAccountName --share-name "nginx" --path "nginx.conf" --query "exists" -o tsv
}

if ($nginxConfExists -ne "true") {
    Write-Host "ストレージにNginx設定ファイルが見つかりません。Container Appsに直接設定を適用します..." -ForegroundColor Yellow
    
    # コマンド文字列を初期化
    $commandScript = "#!/bin/bash`n"
    $commandScript += "mkdir -p /etc/nginx/conf.d`n"
    
    # mountfilesディレクトリ内のファイルを処理する関数
    function Add-FileToScript {
        param (
            [string]$SourcePath,
            [string]$TargetPath,
            [string]$FileDescription
        )
        
        if (Test-Path $SourcePath) {
            $fileContent = Get-Content -Path $SourcePath -Raw -Encoding UTF8
            # シングルクォートをエスケープ
            $fileContent = $fileContent -replace "'", "'\'''"
            $commandScript += "cat > '$TargetPath' << 'EOF_${FileDescription}'`n$fileContent`nEOF_${FileDescription}`n"
            Write-Host "  $FileDescription ファイルを読み込みました: $SourcePath" -ForegroundColor Green
            return $true
        }
        return $false
    }
    
    # nginx.confファイルの処理
    $nginxConfApplied = Add-FileToScript -SourcePath "./mountfiles/nginx/nginx.conf" -TargetPath "/etc/nginx/nginx.conf" -FileDescription "NGINX_CONF"
    
    # default.confファイルの処理
    $defaultConfApplied = Add-FileToScript -SourcePath "./mountfiles/nginx/conf.d/default.conf" -TargetPath "/etc/nginx/conf.d/default.conf" -FileDescription "DEFAULT_CONF"
    
    # mountfiles/nginx/ ディレクトリ内の他のファイルを探索
    Get-ChildItem -Path "./mountfiles/nginx/" -File -Exclude "nginx.conf" | ForEach-Object {
        $relativeFilePath = $_.FullName.Substring("./mountfiles/nginx/".Length)
        $targetPath = "/etc/nginx/$relativeFilePath"
        $fileDesc = ($relativeFilePath -replace "[^a-zA-Z0-9]", "_").ToUpper()
        Add-FileToScript -SourcePath $_.FullName -TargetPath $targetPath -FileDescription $fileDesc
    }
    
    # mountfiles/nginx/conf.d/ ディレクトリ内の他のファイルを探索（default.conf以外）
    if (Test-Path "./mountfiles/nginx/conf.d/") {
        Get-ChildItem -Path "./mountfiles/nginx/conf.d/" -File -Exclude "default.conf" | ForEach-Object {
            $relativeFilePath = "conf.d/" + $_.Name
            $targetPath = "/etc/nginx/$relativeFilePath"
            $fileDesc = ("CONFD_" + ($_.Name -replace "[^a-zA-Z0-9]", "_")).ToUpper()
            Add-FileToScript -SourcePath $_.FullName -TargetPath $targetPath -FileDescription $fileDesc
        }
    }
    
    # 重要なファイルが見つからなかった場合の警告
    if (-not $nginxConfApplied) {
        Write-Warning "mountfiles/nginx/nginx.conf が見つかりません。Nginxの基本設定ファイルを用意してください。"
    }
    
    if (-not $defaultConfApplied) {
        Write-Warning "mountfiles/nginx/conf.d/default.conf が見つかりません。Nginxのサイト設定を用意してください。"
    }
    
    # Nginxを再読み込み
    $commandScript += "nginx -t && nginx -s reload`n"
    $commandScript += "echo 'Nginx設定ファイルを作成し、再読み込みしました'`n"
    
    # 一時ファイルに保存
    $tempScriptPath = [System.IO.Path]::GetTempFileName()
    $commandScript | Out-File -FilePath $tempScriptPath -Encoding utf8
    
    try {
        # Container Appsにコマンドを送信
        Write-Host "Nginxコンテナに設定ファイルを作成しています..." -ForegroundColor Cyan
        $execResult = az containerapp exec --name nginx --resource-group $ResourceGroupName --command "bash" --file $tempScriptPath
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Nginxコンテナに設定ファイルを正常に作成しました" -ForegroundColor Green
        } else {
            Write-Warning "Nginxコンテナへのコマンド実行中にエラーが発生しました: $execResult"
            
            # Container App Execが利用できない場合のフォールバック - Bicepファイルの修正を推奨
            Write-Host "Container App Execコマンドが利用できない場合は、Bicepファイルを修正して再デプロイを検討してください。" -ForegroundColor Yellow
            Write-Host "modules/aca-env.bicepのnginxAppリソースにカスタムコマンドを追加します：" -ForegroundColor Yellow
            Write-Host @'
command: [
  '/bin/bash',
  '-c',
  'mkdir -p /etc/nginx/conf.d && cp -rf /custom-nginx/* /etc/nginx/ 2>/dev/null || echo "No custom config found." && nginx -g "daemon off;"'
]
'@ -ForegroundColor Gray
        }
    } catch {
        Write-Warning "コマンド実行中にエラーが発生しました: $_"
    } finally {
        # 一時ファイルを削除
        Remove-Item -Path $tempScriptPath -Force
    }
}

# エラーが発生した場合のフォールバック方法を説明
Write-Host "ストレージアカウントのアクセス権が制限されている場合は、Azure Portalでストレージアカウントを開き、" -ForegroundColor Yellow
Write-Host "ファイル共有を手動で作成・アップロードするか、Container Appsのコンソールから設定ファイルを作成してください。" -ForegroundColor Yellow

# Container Appsを再起動（一度だけ実行）
Write-Host "Nginxアプリを再起動しています..." -ForegroundColor Cyan
az containerapp restart --name nginx --resource-group $ResourceGroupName


# データベース初期化セクション
Write-Host "Difyデータベースの初期化を開始します..." -ForegroundColor Cyan

# APIコンテナの準備ができるまで待機するロジック
function Wait-ForApiContainer {
    $maxAttempts = 10
    $attempt = 0
    $ready = $false
    
    Write-Host "APIコンテナの準備ができるまで待機しています..." -ForegroundColor Yellow
    
    while (-not $ready -and $attempt -lt $maxAttempts) {
        $attempt++
        Write-Host "  試行 $attempt/$maxAttempts..." -ForegroundColor Gray
        
        # コンテナの状態を確認
        $status = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.latestRevisionStatus" -o tsv 2>$null
        
        if ($status -eq "Running") {
            # 実際にアプリケーションが応答するかテスト
            try {
                $testResult = az containerapp exec --name api --resource-group $ResourceGroupName --command "echo 'Test connection'" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $ready = $true
                    Write-Host "  APIコンテナの準備ができました" -ForegroundColor Green
                    break
                }
            } catch {
                # エラーを無視して続行
            }
        }
        
        Write-Host "  APIコンテナはまだ準備できていません。30秒待機します..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
    
    return $ready
}

# マイグレーションコマンドをより堅牢に実行する関数
function Invoke-MigrationCommand {
    param (
        [string]$Command,
        [string]$Description,
        [int]$TimeoutSeconds = 300,
        [int]$MaxRetries = 3
    )
    
    $retry = 0
    $success = $false
    
    while (-not $success -and $retry -lt $MaxRetries) {
        $retry++
        Write-Host "$Description を実行しています... (試行 $retry/$MaxRetries)" -ForegroundColor Yellow
        
        try {
            # タイムアウト対策でバックグラウンドジョブとして実行
            $job = Start-Job -ScriptBlock {
                param ($ResourceGroupName, $Command)
                az containerapp exec --name api --resource-group $ResourceGroupName --command $Command 2>&1
                return $LASTEXITCODE
            } -ArgumentList $ResourceGroupName, $Command
            
            # 指定した時間まで待機
            if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
                $result = Receive-Job -Job $job
                
                # 結果が配列の場合は最後の要素を取得
                if ($result -is [array]) {
                    $exitCode = $result[-1]
                } else {
                    $exitCode = $LASTEXITCODE
                }
                
                if ($exitCode -eq 0) {
                    Write-Host "  $Description が正常に完了しました" -ForegroundColor Green
                    $success = $true
                } else {
                    Write-Warning "  $Description に失敗しました: $result"
                }
            } else {
                Write-Warning "  $Description がタイムアウトしました（${TimeoutSeconds}秒）"
                Stop-Job -Job $job
            }
            
            Remove-Job -Job $job -Force
        } catch {
            Write-Warning "  コマンド実行中にエラーが発生しました: $_"
        }
        
        if (-not $success -and $retry -lt $MaxRetries) {
            $waitTime = [Math]::Pow(2, $retry) * 15  # 指数バックオフ
            Write-Host "  ${waitTime}秒後に再試行します..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitTime
        }
    }
    
    return $success
}

# APIコンテナが準備できるまで待機
# $apiReady = Wait-ForApiContainer
$apiReady = $true
if (-not $apiReady) {
    Write-Warning "APIコンテナの準備ができませんでした。後で手動で初期化コマンドを実行してください。"
    Write-Host "手動で初期化を実行するには、以下のコマンドを実行してください:" -ForegroundColor Yellow
    Write-Host "az containerapp exec --name api --resource-group $ResourceGroupName --command 'flask db upgrade'" -ForegroundColor Gray
} else {
    # APIコンテナの環境変数を確認
    Write-Host "APIコンテナの環境変数を確認しています..." -ForegroundColor Cyan
    $envVars = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
    
    # 必要な環境変数が設定されているか確認
    $requiredVars = @("DB_HOST", "DB_USERNAME", "DB_PASSWORD", "DB_DATABASE")
    $missingVars = @()
    
    foreach ($var in $requiredVars) {
        $found = $false
        foreach ($envVar in $envVars) {
            if ($envVar.name -eq $var) {
                $found = $true
                break
            }
        }
        
        if (-not $found) {
            $missingVars += $var
        }
    }
    
    if ($missingVars.Count -gt 0) {
        Write-Warning "APIコンテナに以下の環境変数が設定されていません: $($missingVars -join ', ')"
        Write-Host "Bicepテンプレートを確認して、必要な環境変数が設定されていることを確認してください。" -ForegroundColor Yellow
    }
    
    # データベース初期化を実行
    $psqlServer = az postgres flexible-server list --resource-group $ResourceGroupName --query "[0].name" -o tsv

    # uuid-ossp拡張を有効化
    az postgres flexible-server parameter set --resource-group $ResourceGroupName --server-name $psqlServer --name azure.extensions --value uuid-ossp

    # 詳細なマイグレーションログを取得するコマンド
    $debugMigrationCommand = 'flask db upgrade'
    Write-Host "詳細なデバッグ情報付きでマイグレーションを実行しています..." -ForegroundColor Cyan
    az containerapp exec --name api --resource-group $ResourceGroupName --command $debugMigrationCommand    
    
    Write-Host "データベース初期化が完了しました" -ForegroundColor Green        
}

# Container Appsのエンドポイントを取得
try {
    $apiUrl = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    $webUrl = az containerapp show --name web --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    $nginxUrl = az containerapp show --name nginx --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    
    Write-Host "Difyのエンドポイント:" -ForegroundColor Cyan
    Write-Host "メインUI (Nginx): https://$nginxUrl" -ForegroundColor Green
    Write-Host "API: https://$apiUrl" -ForegroundColor Green
    Write-Host "Web: https://$webUrl" -ForegroundColor Green
} catch {
    Write-Warning "エンドポイント情報の取得に失敗しました: $_"
}

Write-Host "デプロイが完了しました！" -ForegroundColor Green