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