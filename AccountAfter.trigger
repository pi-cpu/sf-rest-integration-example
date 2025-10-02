trigger AccountAfter on Account (after insert, after update) {
    if (Trigger.isAfter) {
        AccountTriggerHandler.afterSave(Trigger.new, Trigger.oldMap);
    }
}