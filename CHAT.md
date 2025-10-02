# チャット内容（Salesforce双方向連携）

このファイルには、外部システムとSalesforceをREST APIで双方向に連携するための設計とコードに関するチャット内容が記録されています。実務レベルで耐えられる最小構成を示し、すぐに動かせるコードとともに解説しています。

---

## 1) 外部 → Salesforce（JWT + REST APIでAccountをUpsert）

### 1-1. 前提（Salesforce側設定）

- Connected Appを作成  
  - OAuth設定：`Use digital signatures`にチェック、**証明書（署名鍵）**登録  
  - OAuth Scopes：`Full` または `api`, `refresh_token`など  
  - **JWTクライアントID（Consumer Key）**を取得
- 対象オブジェクト：`Account`  
  - 外部ID用のカスタム項目 `External_Id__c`（External ID + Unique）を作成

### 1-2. 外部（Node.js/Express）からSalesforce標準RESTでUpsert

Node.js/ExpressのサーバーからJWTベアラー方式でSalesforceにログインし、標準REST APIで`Account`を外部IDでupsertする例です。

#### パッケージインストール例

```bash
mkdir ext-sf-jwt && cd ext-sf-jwt
npm init -y
npm i express axios jsonwebtoken node-forge
```

#### server.js

```js
const express = require('express');
const axios = require('axios');
const jwt = require('jsonwebtoken');
const fs = require('fs');

const app = express();
app.use(express.json());

// ==== 環境変数 ====
const SF_DOMAIN = process.env.SF_DOMAIN || 'https://login.salesforce.com'; // sandboxはtest.salesforce.com
const SF_AUDIENCE = SF_DOMAIN; // JWTのaud
const SF_CLIENT_ID = process.env.SF_CLIENT_ID; // Connected AppのConsumer Key
const SF_USERNAME = process.env.SF_USERNAME;   // 連携用ユーザのLogin Name
const SF_PRIVATE_KEY_PATH = process.env.SF_PRIVATE_KEY_PATH || './private.key'; // RS256秘密鍵

async function getSalesforceAccessToken() {
  const privateKey = fs.readFileSync(SF_PRIVATE_KEY_PATH, 'utf8');

  // JWTクレーム
  const token = jwt.sign(
    {
      iss: SF_CLIENT_ID,
      sub: SF_USERNAME,
      aud: SF_AUDIENCE,
      exp: Math.floor(Date.now() / 1000) + 60 * 3, // 3分
    },
    privateKey,
    { algorithm: 'RS256' }
  );

  const params = new URLSearchParams();
  params.append('grant_type', 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  params.append('assertion', token);

  const res = await axios.post(`${SF_DOMAIN}/services/oauth2/token`, params);
  return res.data; // { access_token, instance_url, ... }
}

// 外部→Salesforce: AccountのUpsert（External_Id__cで）
app.post('/sync/account', async (req, res) => {
  try {
    const { External_Id__c, Name, Phone, Industry } = req.body;
    if (!External_Id__c) {
      return res.status(400).json({ error: 'External_Id__c is required' });
    }

    const { access_token, instance_url } = await getSalesforceAccessToken();

    // sobjects Upsert
    const url = `${instance_url}/services/data/v61.0/sobjects/Account/External_Id__c/${encodeURIComponent(External_Id__c)}`;
    const result = await axios.patch(url, { Name, Phone, Industry }, {
      headers: { Authorization: `Bearer ${access_token}` }
    });

    return res.status(result.status).json({ upserted: true, sfStatus: result.status });
  } catch (err) {
    // エラーハンドリング（Salesforceからのエラーもここに来る）
    const status = err.response?.status || 500;
    const data = err.response?.data || { message: err.message };
    return res.status(status).json({ error: 'Salesforce upsert failed', detail: data });
  }
});

// Salesforce -> 外部 受け口（署名検証やAuthトークン検証は実環境で必須！）
app.post('/webhook/salesforce', async (req, res) => {
  // ここでAuthヘッダ検証やIP制限、署名検証などを行う
  console.log('Received from Salesforce:', req.body);

  // ここでDB保存や他システムへの連携など実施
  // 2xxを返せばSalesforce側は成功扱い（上のQueueableはログして終了）
  res.status(200).json({ ok: true });
});

app.listen(3000, () => console.log('External app listening on :3000'));
```

### 1-3. Apex REST（任意の業務バリデーションを入れたい場合）

Salesforce側で標準RESTではなく独自のApex RESTエンドポイントを用意する場合の例です。

```apex
// Apex REST: /services/apexrest/v1/accounts
@RestResource(urlMapping='/v1/accounts/*')
global with sharing class AccountSyncRest {
    global class UpsertRequest {
        public String External_Id__c;
        public String Name;
        public String Phone;
        public String Industry;
    }
    global class UpsertResponse {
        public Boolean success;
        public String accountId;
        public String message;
    }

    @HttpPost
    global static UpsertResponse doPost() {
        RestRequest req = RestContext.request;
        UpsertRequest body = (UpsertRequest) JSON.deserialize(req.requestBody.toString(), UpsertRequest.class);

        if (String.isBlank(body.External_Id__c)) {
            RestContext.response.statusCode = 400;
            UpsertResponse r = new UpsertResponse();
            r.success = false;
            r.message = 'External_Id__c is required';
            return r;
        }

        Account a = new Account();
        a.External_Id__c = body.External_Id__c;
        a.Name = body.Name;
        a.Phone = body.Phone;
        a.Industry = body.Industry;

        try {
            upsert a External_Id__c;
            UpsertResponse r = new UpsertResponse();
            r.success = true;
            r.accountId = a.Id;
            r.message = 'Upserted';
            return r;
        } catch (Exception e) {
            RestContext.response.statusCode = 500;
            UpsertResponse r = new UpsertResponse();
            r.success = false;
            r.message = e.getMessage();
            return r;
        }
    }
}
```

---

## 2) Salesforce → 外部（Named Credential + Queueable + Trigger）

### 2-1. 事前（Salesforce側）設定

- **Named Credential**（例：`callout.ExternalAPI`）  
  - URL: `https://example.com`（外部のベースURL）  
  - 認証：相手のAPI仕様に合わせてOAuth 2.0 / API Key / Basicなど  
  - 相手がJWTクライアントクレデンシャルを要求する場合は**External Credential**/**Auth Provider**を使い、**Principal**を設定  
- **Permission Set**でApexクラスやExternal Credentialにアクセス許可  
- **Custom Object（統合ログ）** `Integration_Log__c`（Fields: `Direction__c(Picklist: Outbound/Inbound)`, `Endpoint__c(Text)`, `StatusCode__c(Number)`, `RequestBody__c(LongText)`, `ResponseBody__c(LongText)`, `RelatedRecordId__c(Lookup/Id)`, `RetryCount__c(Number)` など）

### 2-2. Apex: 外部RESTにPOSTするQueueable

外部システムへのPOSTを非同期で実行し、5xxエラー時には再試行するQueueableクラスの例です。

```apex
public with sharing class OutboundPoster implements Queueable, Database.AllowsCallouts {
    private Id recordId;
    private String payload;
    private String endpointPath;
    private Integer attempt;

    public OutboundPoster(Id recordId, String endpointPath, String payload, Integer attempt) {
        this.recordId = recordId;
        this.endpointPath = endpointPath; // 例: '/webhook/salesforce'
        this.payload = payload;
        this.attempt = attempt == null ? 1 : attempt;
    }

    public void execute(QueueableContext ctx) {
        Integer status;
        String respBody;

        try {
            HttpRequest req = new HttpRequest();
            // Named Credential: callout.ExternalAPI
            req.setEndpoint('callout:ExternalAPI' + endpointPath);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json; charset=UTF-8');
            req.setBody(payload);

            Http http = new Http();
            HTTPResponse resp = http.send(req);
            status = resp.getStatusCode();
            respBody = resp.getBody();

            // ログ
            Integration_Log__c log = new Integration_Log__c(
                Direction__c = 'Outbound',
                Endpoint__c = endpointPath,
                StatusCode__c = status,
                RequestBody__c = payload,
                ResponseBody__c = respBody,
                RelatedRecordId__c = recordId,
                RetryCount__c = attempt
            );
            insert log;

            // 5xxや一時エラーは指数バックオフで再試行（最大3回）
            if (status >= 500 && attempt < 3) {
                System.enqueueJob(new OutboundPoster(recordId, endpointPath, payload, attempt + 1));
            }
        } catch (Exception e) {
            // 例外もログ
            insert new Integration_Log__c(
                Direction__c = 'Outbound',
                Endpoint__c = endpointPath,
                StatusCode__c = -1,
                RequestBody__c = payload,
                ResponseBody__c = e.getMessage(),
                RelatedRecordId__c = recordId,
                RetryCount__c = attempt
            );
            if (attempt < 3) {
                System.enqueueJob(new OutboundPoster(recordId, endpointPath, payload, attempt + 1));
            }
        }
    }
}
```

### 2-3. Trigger → Handler（更新時のみ外部通知）

トリガは薄く保ち、DMLトランザクションと外部呼び出しを分離するためにQueueableに委譲します。

```apex
trigger AccountAfter on Account (after insert, after update) {
    if (Trigger.isAfter) {
        AccountTriggerHandler.afterSave(Trigger.new, Trigger.oldMap);
    }
}

public with sharing class AccountTriggerHandler {
    public static void afterSave(List<Account> newList, Map<Id, Account> oldMap) {
        List<Account> targets = new List<Account>();
        for (Account a : newList) {
            // 例: Nameの変更時のみ通知
            if (oldMap == null || oldMap.get(a.Id) == null || a.Name != oldMap.get(a.Id).Name) {
                targets.add(a);
            }
        }
        if (targets.isEmpty()) return;

        for (Account a : targets) {
            // 通知JSON（最小）
            Map<String, Object> payload = new Map<String, Object>{
                'sfId' => a.Id,
                'externalId' => a.External_Id__c,
                'name' => a.Name,
                'phone' => a.Phone,
                'industry' => a.Industry,
                'updatedAt' => String.valueOf(System.now())
            };
            String body = JSON.serialize(payload);

            // 外部の受け口: /webhook/salesforce
            System.enqueueJob(new OutboundPoster(a.Id, '/webhook/salesforce', body, 1));
        }
    }
}
```

### 2-4. 外部（Express）側の受け口

SalesforceからのPOSTを受け取るエンドポイントの例です。署名検証や認証ヘッダの検証は実運用では必須です。

```js
// Salesforce -> 外部 受け口（署名検証やAuthトークン検証は実環境で必須！）
app.post('/webhook/salesforce', async (req, res) => {
  // ここでAuthヘッダ検証やIP制限、署名検証などを行う
  console.log('Received from Salesforce:', req.body);

  // ここでDB保存や他システムへの連携など実施
  // 2xxを返せばSalesforce側は成功扱い（上のQueueableはログして終了）
  res.status(200).json({ ok: true });
});
```

---

## 3) 運用ポイント（実務メモ）

- **認証/認可**  
  - 外部→Salesforceは **JWTベアラー**推奨（パスワードフローは非推奨）。  
  - Salesforce→外部は **Named Credential / External Credential** で“設定駆動”に。キーのローテは設定で完結。  
- **非同期化**  
  - Salesforce→外部コールは **Queueable**/**Future** でトランザクションと分離。トリガで同期Calloutは避ける。  
- **再送/冪等性**  
  - 一時エラー（5xx）は指数バックオフで再送。外部側は `externalId` や `sfId` で冪等処理。  
- **可観測性**  
  - `Integration_Log__c` に全リクエスト/レスポンスを保存（PII配慮）。  
  - 失敗閾値超えで **Platform Event** や **メール通知** など運用アラート。  
- **スキーマ進化**  
  - JSONは **バージョン** を付けるか、**Apex REST** に集約して内部変換する層を設けると後方互換が楽。  
- **大量データ**  
  - 同期の初期ロードは **Bulk API**、それ以降の変更は本稿のREST/Queueableで増分同期。  
- **セキュリティ**  
  - 外部受け口は **署名付きWebhook** や **mTLS**、**IP allowlist** で堅牢化。  
  - 機微情報はログに残さない。  

---

## 4) まとめ（すぐ動かせる最小構成）

- **外部→Salesforce**：上記 `/sync/account` で **JWT→標準REST Upsert**  
- **Salesforce→外部**：**Named Credential** + `OutboundPoster`（Queueable） + Trigger で **非同期POST**  
- **外部受け口**：`/webhook/salesforce`（Express）

この形で「双方向REST」が成立します。テストクラス（Apex）や署名検証、Bulk APIを用いた初期ロードなど、さらに発展させることも可能です。