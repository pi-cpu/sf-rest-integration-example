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