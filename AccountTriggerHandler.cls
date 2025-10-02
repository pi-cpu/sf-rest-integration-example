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