targetScope = 'subscription'

@description('デプロイするリージョン')
param location string = 'japaneast'

@description('リソースグループ名のプレフィックス')
param resourceGroupPrefix string = 'rg'

@description('IPアドレスのプレフィックス')
param ipPrefix string = '10.99'

@description('ストレージアカウント名のベース')
param storageAccountBase string = 'acadifytest'

@description('ストレージアカウントのコンテナ名')
param storageAccountContainer string = 'dfy'

@description('Redis名のベース')
param redisNameBase string = 'acadifyredis'

@description('PostgreSQL名のベース')
param psqlFlexibleBase string = 'acadifypsql'

@description('PostgreSQLユーザー名')
param pgsqlUser string = 'user'

@description('PostgreSQLパスワード')
@secure()
param pgsqlPassword string = '#QWEASDasdqwe'

@description('ACA環境名')
param acaEnvName string = 'dify-aca-env'

@description('ACA Log Analyticsワークスペース名')
param acaLogaName string = 'dify-loga'

@description('独自証明書を提供するかどうか')
param isProvidedCert bool = true

@description('証明書の内容 (Base64エンコード)')
@secure()
param acaCertBase64Value string = ''

@description('証明書のパスワード')
@secure()
param acaCertPassword string = 'password'

@description('Difyのカスタムドメイン')
param acaDifyCustomerDomain string = 'dify.example.com'

@description('ACAアプリの最小インスタンス数')
param acaAppMinCount int = 0

@description('ACAを有効にするかどうか')
param isAcaEnabled bool = false

@description('Dify APIイメージ')
param difyApiImage string = 'langgenius/dify-api:1.9.0'

@description('Dify サンドボックスイメージ')
param difySandboxImage string = 'langgenius/dify-sandbox:0.2.12'

@description('Dify Webイメージ')
param difyWebImage string = 'langgenius/dify-web:1.9.0'

@description('Dify Plugin Daemonイメージ')
param difyPluginDaemonImage string = 'langgenius/dify-plugin-daemon:0.3.0-local'


// リソースグループを作成
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: '${resourceGroupPrefix}-${location}'
  location: location
}

// 一意のリソース名のためのハッシュを生成
var rgNameHex = uniqueString(subscription().id, rg.name)

// ネットワーク関連のリソースをデプロイ
module vnetModule './modules/vnet.bicep' = {
  name: 'vnetDeploy'
  scope: rg
  params: {
    location: location
    ipPrefix: ipPrefix
  }
}

// ストレージアカウントとファイル共有をデプロイ
module storageModule './modules/storage.bicep' = {
  name: 'storageDeploy'
  scope: rg
  params: {
    location: location
    storageAccountName: '${storageAccountBase}${rgNameHex}'
    containerName: storageAccountContainer
    privateLinkSubnetId: vnetModule.outputs.privateLinkSubnetId
    vnetId: vnetModule.outputs.vnetId
  }
}

// ファイル共有をデプロイ
module nginxFileShareModule './modules/fileshare.bicep' = {
  name: 'nginxFileShareDeploy'
  scope: rg
  params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'nginx'
    localMountDir: 'mountfiles/nginx'
  }
}

module sandboxFileShareModule './modules/fileshare.bicep' = {
  name: 'sandboxFileShareDeploy'
  scope: rg
  params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'sandbox'
    localMountDir: 'mountfiles/sandbox'
  }
}

module ssrfProxyFileShareModule './modules/fileshare.bicep' = {
  name: 'ssrfProxyFileShareDeploy'
  scope: rg
  params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'ssrfproxy'
    localMountDir: 'mountfiles/ssrfproxy'
  }
}

module pluginStorageFileShareModule './modules/fileshare.bicep' = {
  name: 'pluginStorageFileShareDeploy'
  scope: rg
  params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'pluginstorage'
    localMountDir: 'mountfiles/pluginstorage'
  }
}

// PostgreSQLサーバーをデプロイ
module postgresqlModule './modules/postgresql.bicep' = {
  name: 'postgresqlDeploy'
  scope: rg
  params: {
    location: location
    serverName: '${psqlFlexibleBase}${rgNameHex}'
    administratorLogin: pgsqlUser
    administratorLoginPassword: pgsqlPassword
    postgresSubnetId: vnetModule.outputs.postgresSubnetId
    vnetId: vnetModule.outputs.vnetId
  }
}

// Redisキャッシュをデプロイ (条件付き)
module redisModule './modules/redis-cache.bicep' = if (isAcaEnabled) {
  name: 'redisDeploy'
  scope: rg
  params: {
    location: location
    redisName: '${redisNameBase}${rgNameHex}'
    privateLinkSubnetId: vnetModule.outputs.privateLinkSubnetId
    vnetId: vnetModule.outputs.vnetId
  }
}

// ACA環境とアプリをデプロイ
module acaModule './modules/aca-env.bicep' = {
  name: 'acaEnvDeploy'
  scope: rg
  params: {
    location: location
    acaEnvName: acaEnvName
    acaLogaName: acaLogaName
    acaSubnetId: vnetModule.outputs.acaSubnetId
    isProvidedCert: isProvidedCert
    acaCertBase64Value: acaCertBase64Value
    acaCertPassword: acaCertPassword
    acaDifyCustomerDomain: acaDifyCustomerDomain
    acaAppMinCount: acaAppMinCount
    storageAccountName: storageModule.outputs.storageAccountName
    storageAccountKey: storageModule.outputs.storageAccountKey
    storageContainerName: storageAccountContainer
    nginxShareName: nginxFileShareModule.outputs.shareName
    sandboxShareName: sandboxFileShareModule.outputs.shareName
    ssrfProxyShareName: ssrfProxyFileShareModule.outputs.shareName
    pluginStorageShareName: pluginStorageFileShareModule.outputs.shareName
    postgresServerFqdn: postgresqlModule.outputs.serverFqdn
    postgresAdminLogin: pgsqlUser
    postgresAdminPassword: pgsqlPassword
    postgresDifyDbName: postgresqlModule.outputs.difyDbName
    postgresVectorDbName: postgresqlModule.outputs.vectorDbName
    redisHostName: isAcaEnabled ? redisModule.outputs.redisHostName : ''
    redisPrimaryKey: isAcaEnabled ? redisModule.outputs.redisPrimaryKey : ''
    difyApiImage: difyApiImage
    difySandboxImage: difySandboxImage
    difyWebImage: difyWebImage
    difyPluginDaemonImage: difyPluginDaemonImage
    blobEndpoint: storageModule.outputs.blobEndpoint
  }
}

// デプロイ後の出力
output difyAppUrl string = acaModule.outputs.difyAppUrl
