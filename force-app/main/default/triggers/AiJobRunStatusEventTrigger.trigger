trigger AiJobRunStatusEventTrigger on AiJobRunStatusEvent (after insert) {
    Set<String> finished = new Set<String>();
    for (AiJobRunStatusEvent e : Trigger.new) {
        if ((e.Status == 'Completed' || e.Status == 'Failed') && String.isNotBlank(e.AiJobRunIdentifier)) {
            finished.add(String.valueOf((Id) e.AiJobRunIdentifier));
        }
    }
    if (!finished.isEmpty()) {
        try {
            AiJobRunEventHandler.handleFinished(finished);
        } catch (Exception ex) {
            // Never let this throw: after repeated failures the platform disables the subscription.
            System.debug(LoggingLevel.ERROR, 'AiJobRunStatusEventTrigger failed: ' + ex.getMessage());
        }
    }
}
