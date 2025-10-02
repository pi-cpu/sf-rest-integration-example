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