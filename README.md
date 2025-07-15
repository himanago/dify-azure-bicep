## dify-azure-bicep
Deploy [langgenius/dify](https://github.com/langgenius/dify), an LLM based chat bot app on Azure with Bicep.

> **Note**: This repository rewrites the contents of [dify-azure-terraform](https://github.com/nikawang/dify-azure-terraform) in Bicep and supports Dify 1.x.

### Topology
Front-end access:
- nginx -> Azure Container Apps (Serverless)

Back-end components:
- web -> Azure Container Apps (Serverless)
- api -> Azure Container Apps (Serverless)
- worker -> Azure Container Apps (minimum of 1 instance)
- sandbox -> Azure Container Apps (Serverless)
- ssrf_proxy -> Azure Container Apps (Serverless)
- db -> Azure Database for PostgreSQL
- vectordb -> Azure Database for PostgreSQL
- redis -> Azure Cache for Redis

Before you provision Dify, please check and set the variables in parameters.json file.

### Bicep Variables Documentation

This document provides detailed descriptions of the variables used in the Bicep configuration for setting up the Dify environment.
### Kick Start
```bash
az login
az account set --subscription <subscription-id>
./deploy.ps1
```

### Deployment Parameters

#### Region

- **Parameter Name**: `location`
- **Type**: `string`
- **Default Value**: `japaneast`

#### Resource Group Prefix

- **Parameter Name**: `resourceGroupPrefix`
- **Type**: `string`
- **Default Value**: `rg-dify`

### Network Parameters

#### VNET Address IP Prefix

- **Parameter Name**: `ipPrefix`
- **Type**: `string`
- **Default Value**: `10.99`

#### Storage Account

- **Parameter Name**: `storageAccountBase`
- **Type**: `string`
- **Default Value**: `acadifytest`

#### Storage Account Container

- **Parameter Name**: `storageAccountContainer`
- **Type**: `string`
- **Default Value**: `dfy`

### Redis

- **Parameter Name**: `redisNameBase`
- **Type**: `string`
- **Default Value**: `acadifyredis`

#### PostgreSQL Flexible Server

- **Parameter Name**: `psqlFlexibleBase`
- **Type**: `string`
- **Default Value**: `acadifypsql`

#### PostgreSQL User

- **Parameter Name**: `pgsqlUser`
- **Type**: `string`
- **Default Value**: `adminuser`

#### PostgreSQL Password

- **Parameter Name**: `pgsqlPassword`
- **Type**: `string`
- **Default Value**: `DFE%S_FgrgeA143Sdx`
- **Note**: Specified as a secure parameter

### ACA Environment Parameters

#### ACA Environment

- **Parameter Name**: `acaEnvName`
- **Type**: `string`
- **Default Value**: `dify-aca-env`

#### ACA Log Analytics Workspace

- **Parameter Name**: `acaLogaName`
- **Type**: `string`
- **Default Value**: `dify-loga`

#### IF BRING YOUR OWN CERTIFICATE

- **Parameter Name**: `isProvidedCert`
- **Type**: `bool`
- **Default Value**: `false`


##### ACA Certificate Path (if isProvidedCert is true)

- **Parameter Name**: `acaCertBase64Value`
- **Type**: `string`
- **Default Value**: ``
- **Note**: Specified as a secure parameter

##### ACA Certificate Password (if isProvidedCert is true)

- **Parameter Name**: `acaCertPassword`
- **Type**: `string`
- **Default Value**: `fergEAR#FSr!eg`
- **Note**: Specified as a secure parameter

##### ACA Dify Customer Domain (if isProvidedCert is false)

- **Parameter Name**: `acaDifyCustomerDomain`
- **Type**: `string`
- **Default Value**: `dify.example.com`

#### ACA App Minimum Instance Count

- **Parameter Name**: `acaAppMinCount`
- **Type**: `int`
- **Default Value**: `1`

#### Container Images

##### Dify API Image

- **Parameter Name**: `difyApiImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-api:1.6.0`

#### Dify Sandbox Image

- **Parameter Name**: `difySandboxImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-sandbox:0.2.12`

##### Dify Web Image

- **Parameter Name**: `difyWebImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-web:1.6.0`

##### Dify Plugin Daemon Image

- **Parameter Name**: `difyPluginDaemonImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-plugin-daemon:0.1.3-local`
