// OpportunityRenewalCloneController.cls — Follow-on Opportunity creation and renewal tracking.
/**
 * @description Controller class for cloning an existing Opportunity into a Renewal or Addon
 *              follow-on Opportunity. Handles file linking, note prepending, bank statement
 *              processing enqueue, and credit/background third-party callouts.
 * @author Zehra Koc
 * @date 2026-05-14
 * @version 1.1 — CS-680: Stores the original Opportunity and flags its Funded Deals on Renewal finalization.
 */
public with sharing class OpportunityRenewalCloneController {

    /**
     * @description Wrapper class used to expose ContentDocument file metadata to the LWC.
     */
    public class FileOptionWrapper {
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public String title;
        @AuraEnabled public String fileType;
        @AuraEnabled public Long contentSize;
        @AuraEnabled public Datetime createdDate;
    }

    /**
     * @description Lightweight DTO used to deserialize the credit/background API response body.
     */
    public class ApiResponse {
        public String message;
    }

    /**
     * @description Queueable job that triggers bank statement processing asynchronously for the
     *              newly created follow-on Opportunity. Delegates to BankStatementController.
     */
    public class BankStatementQueueable implements Queueable, Database.AllowsCallouts {
        private Id opportunityId;

        /**
         * @description Constructor that stores the target Opportunity Id.
         * @param opportunityId Id of the Opportunity to process bank statements for.
         */
        public BankStatementQueueable(Id opportunityId) {
            this.opportunityId = opportunityId;
        }

        /**
         * @description Queueable execute method. Invokes BankStatementController processing
         *              when an Opportunity Id is provided.
         * @param context Standard Queueable context (unused).
         */
        public void execute(QueueableContext context) {
            if (opportunityId == null) {
                return;
            }

            System.debug('BankStatementQueueable started for Opportunity Id: ' + opportunityId);
           BankStatementController.processBankStatements(String.valueOf(opportunityId));
      
            System.debug('BankStatementQueueable finished for Opportunity Id: ' + opportunityId);
        }
    }

    /**
     * @description Queueable job that runs the credit and background third-party callout
     *              asynchronously to avoid DML + callout conflicts in the same transaction.
     */
    public class CreditBackgroundQueueable implements Queueable, Database.AllowsCallouts {
        private Id opportunityId;

        /**
         * @description Constructor that stores the target Opportunity Id.
         * @param opportunityId Id of the Opportunity to run credit/background checks for.
         */
        public CreditBackgroundQueueable(Id opportunityId) {
            this.opportunityId = opportunityId;
        }

        /**
         * @description Queueable execute method. Calls the internal credit/background routine,
         *              logging any exceptions instead of rethrowing to prevent job failure.
         * @param context Standard Queueable context (unused).
         */
        public void execute(QueueableContext context) {
            if (opportunityId == null) {
                System.debug('CreditBackgroundQueueable skipped because Opportunity Id is null.');
                return;
            }

            System.debug('CreditBackgroundQueueable started for Opportunity Id: ' + opportunityId);

            try {
                startCreditAndBackgroundInternal(opportunityId);
                System.debug('Credit/background call completed for Opportunity Id: ' + opportunityId);
            } catch (Exception e) {
                System.debug('Credit/background queueable failed for Opportunity Id: ' + opportunityId);
                System.debug('Error message: ' + e.getMessage());
                System.debug('Stack trace: ' + e.getStackTraceString());
            }
        }
    }

    /**
     * @description Creates a follow-on Opportunity (Renewal or Addon) by cloning selected fields
     *              from a source Opportunity. The new Opportunity is assigned to the running user
     *              and defaults StageName to Underwriting.
     * @param opportunityId Source Opportunity Id to clone from.
     * @param selectedType Either 'Renewal' or 'Addon'.
     * @return Id of the newly created Opportunity.
     */
    @AuraEnabled
    public static Id createFollowOnOpportunity(Id opportunityId, String selectedType) {
        if (opportunityId == null) {
            throw new AuraHandledException('Opportunity Id is required.');
        }

        if (String.isBlank(selectedType)) {
            throw new AuraHandledException('Please select Renewal or Addon.');
        }

        if (selectedType != 'Renewal' && selectedType != 'Addon') {
            throw new AuraHandledException('Invalid selection.');
        }

        Opportunity sourceOpp = [
            SELECT Id,
                   Name,
                   StageName,
                   CloseDate,
                   AccountId,
                   Dragin_Engine__Contact__c,
                   Dragin_Engine__Secondary_Contact__c,
                   Dragin_Engine__ISO__c,
                   Dragin_Engine__ISO_Email__c,
                   Dragin_Engine__Pre_Underwriting_Notes__c,
                   Dragin_Engine__ISO_Representative__c,
                   Dragin_Engine__ISO_Rep_Email__c,
                   Dragin_Engine__ISO_Rep_Phone__c,
                   Dragin_Engine__Underwriting_Notes__c,
                   Dragin_Engine__Adjustment_Request__c 
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];

        Opportunity newOpp = new Opportunity();
        newOpp.Name = sourceOpp.Name + ' - ' + selectedType;
        newOpp.AccountId = sourceOpp.AccountId;
        newOpp.Dragin_Engine__Contact__c = sourceOpp.Dragin_Engine__Contact__c;
        newOpp.Dragin_Engine__Secondary_Contact__c = sourceOpp.Dragin_Engine__Secondary_Contact__c;
        newOpp.Dragin_Engine__ISO__c = sourceOpp.Dragin_Engine__ISO__c;
        newOpp.Dragin_Engine__ISO_Email__c = sourceOpp.Dragin_Engine__ISO_Email__c;
        newOpp.Dragin_Engine__Pre_Underwriting_Notes__c = sourceOpp.Dragin_Engine__Pre_Underwriting_Notes__c;
        newOpp.Dragin_Engine__ISO_Representative__c = sourceOpp.Dragin_Engine__ISO_Representative__c;
        newOpp.Dragin_Engine__ISO_Rep_Email__c = sourceOpp.Dragin_Engine__ISO_Rep_Email__c;
        newOpp.Dragin_Engine__ISO_Rep_Phone__c = sourceOpp.Dragin_Engine__ISO_Rep_Phone__c;
        newOpp.Dragin_Engine__Underwriting_Notes__c = sourceOpp.Dragin_Engine__Underwriting_Notes__c;

        newOpp.Dragin_Engine__Deal_Type__c = selectedType;
        newOpp.StageName = 'Underwriting';
        newOpp.Dragin_Engine__Adjustment_Request__c = 'Renewal';
        newOpp.CloseDate = sourceOpp.CloseDate == null ? Date.today().addDays(30) : sourceOpp.CloseDate;
        newOpp.OwnerId = UserInfo.getUserId();

        // Record the source for both Renewal and Addon follow-on Opportunities (CS-680).
        newOpp.Original_Opportunity__c = sourceOpp.Id;

        insert newOpp;

        return newOpp.Id;
    }

    /**
     * @description Returns all ContentDocument files linked to the given source Opportunity,
     *              ordered by created date descending, for selection in the LWC.
     * @param sourceOpportunityId Source Opportunity Id whose files should be retrieved.
     * @return List of FileOptionWrapper representing the linked files.
     */
    @AuraEnabled(cacheable=true)
    public static List<FileOptionWrapper> getSourceOpportunityFiles(Id sourceOpportunityId) {
        if (sourceOpportunityId == null) {
            throw new AuraHandledException('Source Opportunity Id is required.');
        }

        List<FileOptionWrapper> results = new List<FileOptionWrapper>();

        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId,
                   ContentDocument.Title,
                   ContentDocument.FileType,
                   ContentDocument.LatestPublishedVersionId,
                   ContentDocument.ContentSize,
                   ContentDocument.CreatedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :sourceOpportunityId
            ORDER BY ContentDocument.CreatedDate DESC
        ]) {
            FileOptionWrapper row = new FileOptionWrapper();
            row.contentDocumentId = cdl.ContentDocumentId;
            row.contentVersionId = cdl.ContentDocument.LatestPublishedVersionId;
            row.title = cdl.ContentDocument.Title;
            row.fileType = cdl.ContentDocument.FileType;
            row.contentSize = cdl.ContentDocument.ContentSize;
            row.createdDate = cdl.ContentDocument.CreatedDate;
            results.add(row);
        }

        return results;
    }

    /**
     * @description Finalizes the follow-on Opportunity by linking selected files, updating
     *              renewal balance, prepending notes, and optionally enqueueing bank statement
     *              processing. For Renewal, flags all Funded Deals related to the source
     *              Opportunity as renewed (CS-680; business-owner confirmation pending).
     * @param sourceOpportunityId Source Opportunity Id (origin of files).
     * @param newOpportunityId Newly created follow-on Opportunity Id.
     * @param contentDocumentIds List of ContentDocument Ids to link to the new Opportunity.
     * @param selectedType Either 'Renewal' or 'Addon'.
     * @param renewalBalance Payoff/Buy Off amount applied only when selectedType is 'Renewal'.
     * @param shouldRunBankStatements If true, enqueues BankStatementQueueable for processing.
     * @param followOnNotes Notes to prepend to the new Opportunity's pre-underwriting notes.
     */
    @AuraEnabled
    public static void finalizeFollowOnOpportunity(
        Id sourceOpportunityId,
        Id newOpportunityId,
        List<Id> contentDocumentIds,
        String selectedType,
        Decimal renewalBalance,
        Boolean shouldRunBankStatements,
        String followOnNotes
    ) {
        if (sourceOpportunityId == null || newOpportunityId == null) {
            throw new AuraHandledException('Source and new Opportunity Ids are required.');
        }

        // CS-680: Never flag an unrelated source deal based only on client-supplied IDs/type.
        List<Opportunity> followOnOpps = [
            SELECT Id, Original_Opportunity__c, Dragin_Engine__Deal_Type__c
            FROM Opportunity
            WHERE Id = :newOpportunityId
            LIMIT 1
        ];
        if (followOnOpps.isEmpty() ||
            followOnOpps[0].Original_Opportunity__c != sourceOpportunityId ||
            followOnOpps[0].Dragin_Engine__Deal_Type__c != selectedType ||
            (selectedType != 'Renewal' && selectedType != 'Addon')) {
            throw new AuraHandledException('Invalid follow-on Opportunity or original Opportunity relationship.');
        }

        if (contentDocumentIds != null && !contentDocumentIds.isEmpty()) {
            Set<Id> documentIds = new Set<Id>(contentDocumentIds);

            Map<Id, ContentDocumentLink> existingOnNewOpp = new Map<Id, ContentDocumentLink>();
            for (ContentDocumentLink cdl : [
                SELECT Id, ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :newOpportunityId
                AND ContentDocumentId IN :documentIds
            ]) {
                existingOnNewOpp.put(cdl.ContentDocumentId, cdl);
            }

            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
            for (Id docId : documentIds) {
                if (!existingOnNewOpp.containsKey(docId)) {
                    ContentDocumentLink newLink = new ContentDocumentLink();
                    newLink.LinkedEntityId = newOpportunityId;
                    newLink.ContentDocumentId = docId;
                    newLink.ShareType = 'V';
                    newLink.Visibility = 'AllUsers';
                    linksToInsert.add(newLink);
                }
            }

            if (!linksToInsert.isEmpty()) {
                insert linksToInsert;
            }
        }

        Opportunity oppToUpdate = [
            SELECT Id, Dragin_Engine__Pre_Underwriting_Notes__c
            FROM Opportunity
            WHERE Id = :newOpportunityId
            LIMIT 1
        ];

        Boolean needsUpdate = false;

        if (selectedType == 'Renewal' && renewalBalance != null) {
            oppToUpdate.Dragin_Engine__Renewal_Payoff_Amount__c = renewalBalance;
            needsUpdate = true;
        }

        if (!String.isBlank(followOnNotes)) {
            String trimmedNotes = followOnNotes.trim();
            String noteHeader = selectedType + ' Notes';
            String newTopNote = noteHeader + ':' + '\n' + trimmedNotes;

            if (String.isBlank(oppToUpdate.Dragin_Engine__Pre_Underwriting_Notes__c)) {
                oppToUpdate.Dragin_Engine__Pre_Underwriting_Notes__c = newTopNote;
            } else {
                oppToUpdate.Dragin_Engine__Pre_Underwriting_Notes__c =
                    newTopNote + '\n\n' + oppToUpdate.Dragin_Engine__Pre_Underwriting_Notes__c;
            }
            needsUpdate = true;
        }

        if (needsUpdate) {
            update oppToUpdate;
        }

        // CS-680: System-mode update is deliberate: this automation-maintained flag
        // must not depend on the running user's direct field edit access.
        // Action authorization must be verified separately before production deployment.
        // Source/new Opportunity relationship and selected type are validated above.
        // All Funded Deals on the source are flagged; business-owner sign-off is pending.
        if (selectedType == 'Renewal') {
            List<Dragin_Engine__Funded__c> fundedDeals = [
                SELECT Id, Is_Renewed__c
                FROM Dragin_Engine__Funded__c
                WHERE Dragin_Engine__Opportunity__c = :sourceOpportunityId
                AND Is_Renewed__c = false
            ];
            for (Dragin_Engine__Funded__c fundedDeal : fundedDeals) {
                fundedDeal.Is_Renewed__c = true;
            }
            if (!fundedDeals.isEmpty()) {
                update as system fundedDeals;
            }
        }

        if (shouldRunBankStatements == true) {
            System.enqueueJob(new BankStatementQueueable(newOpportunityId));
        }
    }

    /**
     * @description Entry point invoked from the LWC to enqueue the credit/background callout
     *              asynchronously, avoiding mixed DML/callout transaction errors.
     * @param recordIds List containing the Opportunity Id to process (first element used).
     */
    @AuraEnabled
    public static void startCreditAndBackground(List<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty() || recordIds[0] == null) {
            throw new AuraHandledException('A valid Opportunity Id is required.');
        }

        System.debug('Request received to start credit/background for Opportunity Id: ' + recordIds[0]);
        System.enqueueJob(new CreditBackgroundQueueable(recordIds[0]));
    }

    /**
     * @description Performs the credit/background third-party callout, updates Dragin_Engine__Process_Check__c,
     *              and advances StageName to Underwriting unless the deal is Not Funded.
     * @param recordId Id of the Opportunity to run the callout for.
     */
    public static void startCreditAndBackgroundInternal(Id recordId) {
        System.debug('startCreditAndBackgroundInternal entered for Opportunity Id: ' + recordId);

        Dragin_Engine__SF_DND_Keys__mdt dndKeys = [
            SELECT Dragin_Engine__Consumer_Secret__c
            FROM Dragin_Engine__SF_DND_Keys__mdt
            LIMIT 1
        ];

        String endpointUrl = 'callout:DragAndDropAPI/api/v1/auto_email/run_reports/';

        Map<String, Object> requestBodyMap = new Map<String, Object>();
        requestBodyMap.put('id', recordId);
        String requestBody = JSON.serialize(requestBodyMap);

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpointUrl);
        request.setMethod('POST');
        request.setBody(requestBody);
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Authorization', 'Bearer ' + dndKeys.Dragin_Engine__Consumer_Secret__c);
        request.setTimeout(60000);

        System.debug('Credit/background endpoint: ' + endpointUrl);
        System.debug('Credit/background request body: ' + requestBody);

        Http http = new Http();
        HttpResponse response = http.send(request);

        System.debug('Credit/background status code: ' + response.getStatusCode());
        System.debug('Credit/background status: ' + response.getStatus());
        System.debug('Credit/background response body: ' + response.getBody());

        if (response.getStatusCode() == 200) {
            try {
                ApiResponse apiResponse = (ApiResponse) JSON.deserialize(response.getBody(), ApiResponse.class);
                System.debug('Credit/background API success message: ' + apiResponse.message);
            } catch (Exception ex) {
                System.debug('Response returned 200 but could not deserialize into ApiResponse.');
                System.debug('Deserialize error: ' + ex.getMessage());
            }
        } else {
            System.debug('Error starting credit/background in third-party system.');
        }

        Opportunity opp = [
            SELECT Id, Dragin_Engine__Process_Check__c, StageName
            FROM Opportunity
            WHERE Id = :recordId
            LIMIT 1
        ];

        opp.Dragin_Engine__Process_Check__c = true;

        if (opp.StageName == 'Not Funded') {
            update opp;
            System.debug('Updated Opportunity Dragin_Engine__Process_Check__c only because stage is Not Funded.');
        } else {
            opp.StageName = 'Underwriting';
            update opp;
            System.debug('Updated Opportunity Dragin_Engine__Process_Check__c and StageName to Underwriting.');
        }
    }
}