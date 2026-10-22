// MCAFunding_FundedAmountController.cls — Opportunity MCA funded amount reader and writer.
/**
 * Returns populated MCA slots and saves their funded amounts as a formatted Opportunity summary.
 * Runs with sharing and uses user-mode SOQL/DML to respect the running user's access.
 * The record-page component processes one Opportunity per request; bulk processing does not apply.
 *
 * @author Faruk Sukru Uslu
 * @date 2026-10-19
 * @version 1.0
 */
public with sharing class MCAFunding_FundedAmountController {
    private static final String AMOUNT_SEPARATOR = ': $';
    private static final String LINE_SEPARATOR = '\n';
    private static final String LINE_SPLIT_PATTERN = '\\r?\\n';
    private static final String THOUSANDS_SEPARATOR = ',';
    private static final Integer AMOUNT_SCALE = 2;
    private static final Integer DIGIT_GROUP_SIZE = 3;
    private static final Integer REFERENCE_LENGTH = 6;
    private static final List<Schema.SObjectField> MCA_NAME_FIELDS = new List<Schema.SObjectField>{
        Opportunity.Dragin_Engine__MCA_Name_1__c, Opportunity.Dragin_Engine__MCA_Name_2__c,
        Opportunity.Dragin_Engine__MCA_Name_3__c, Opportunity.Dragin_Engine__MCA_Name_4__c,
        Opportunity.Dragin_Engine__MCA_Name_5__c, Opportunity.Dragin_Engine__MCA_Name_6__c,
        Opportunity.Dragin_Engine__MCA_Name_7__c, Opportunity.Dragin_Engine__MCA_Name_8__c
    };
    private static final Schema.SObjectField SUMMARY_FIELD = Opportunity.Funded_Amounts_Summary__c;

    private static final String MSG_MISSING_RECORD = 'No record was provided to the MCA Funded Amounts component.';
    private static final String MSG_NO_ACCESS = 'This record could not be found, or you do not have access to it.';
    private static final String MSG_INVALID_SLOT = 'An amount was submitted for an MCA that does not exist on this record.';
    private static final String MSG_NEGATIVE = 'Funded amounts cannot be negative.';
    private static final String MSG_SCALE = 'Funded amounts can have at most 2 decimal places.';
    private static final String MSG_LOAD_FAILED = 'The MCA funded amounts could not be loaded. Reference: ';
    private static final String MSG_SAVE_FAILED = 'The funded amounts could not be saved. Reference: ';

    /** Represents a business validation failure that can be shown to the user. */
    public class FundedAmountException extends Exception {}

    /** Read-only MCA slot data returned to the LWC. */
    public class McaRow {
        @AuraEnabled public Integer mcaNumber;
        @AuraEnabled public String mcaName;
        @AuraEnabled public Decimal fundedAmount;
        /** Creates one display row with its MCA slot, name, and saved amount. */
        public McaRow(Integer mcaNumber, String mcaName, Decimal fundedAmount) {
            this.mcaNumber = mcaNumber; this.mcaName = mcaName; this.fundedAmount = fundedAmount;
        }
    }

    /** LWC request data; a null amount clears its MCA from the summary. */
    public class FundedAmountInput {
        @AuraEnabled public Integer mcaNumber { get; set; }
        @AuraEnabled public Decimal fundedAmount { get; set; }
    }

    /** Returns populated MCA slots and their saved values for an Opportunity record page. */
    @AuraEnabled(cacheable=true)
    public static List<McaRow> getFundedAmounts(Id recordId) {
        try { return getRows(recordId); }
        catch (FundedAmountException e) { throw buildException(e.getMessage()); }
        catch (QueryException e) { throw buildReferencedException(MSG_LOAD_FAILED, e); }
        catch (Exception e) { throw buildReferencedException(MSG_LOAD_FAILED, e); }
    }

    /** Validates submitted amounts, writes the summary, and returns refreshed MCA rows. */
    @AuraEnabled
    public static List<McaRow> saveFundedAmounts(Id recordId, List<FundedAmountInput> amounts) {
        try { writeSummary(recordId, amounts); return getRows(recordId); }
        catch (FundedAmountException e) { throw buildException(e.getMessage()); }
        catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) {
                throw buildException(e.getDmlMessage(0));
            }
            throw buildReferencedException(MSG_SAVE_FAILED, e);
        }
        catch (QueryException e) { throw buildReferencedException(MSG_SAVE_FAILED, e); }
        catch (Exception e) { throw buildReferencedException(MSG_SAVE_FAILED, e); }
    }

    /** Queries the Opportunity and builds display rows for nonblank MCA name slots. */
    private static List<McaRow> getRows(Id opportunityId) {
        Opportunity opp = queryOpportunity(opportunityId);
        Map<String, List<Decimal>> savedByName = parseSummaryOccurrences((String) opp.get(SUMMARY_FIELD));
        Map<String, Integer> nextOccurrence = new Map<String, Integer>();
        List<McaRow> rows = new List<McaRow>();
        for (Integer i = 0; i < MCA_NAME_FIELDS.size(); i++) {
            String mcaName = (String) opp.get(MCA_NAME_FIELDS[i]);
            if (String.isBlank(mcaName)) { continue; }
            String name = mcaName.trim();
            Integer occurrence = nextOccurrence.containsKey(name) ? nextOccurrence.get(name) : 0;
            List<Decimal> savedAmounts = savedByName.get(name);
            Decimal amount = savedAmounts != null && occurrence < savedAmounts.size()
                ? savedAmounts[occurrence] : null;
            rows.add(new McaRow(i + 1, name, amount));
            nextOccurrence.put(name, occurrence + 1);
        }
        return rows;
    }

    /** Rebuilds the saved summary in MCA slot order, omitting empty amounts and names. */
    private static void writeSummary(Id opportunityId, List<FundedAmountInput> amounts) {
        Opportunity opp = queryOpportunity(opportunityId);
        Map<Integer, Decimal> amountsBySlot = collectAmounts(amounts);
        List<String> lines = new List<String>();
        for (Integer i = 0; i < MCA_NAME_FIELDS.size(); i++) {
            String mcaName = (String) opp.get(MCA_NAME_FIELDS[i]);
            Decimal amount = amountsBySlot.get(i + 1);
            if (String.isBlank(mcaName) || amount == null) { continue; }
            lines.add(mcaName.trim() + AMOUNT_SEPARATOR + formatAmount(amount));
        }
        Opportunity toUpdate = new Opportunity(Id = opportunityId);
        toUpdate.put(SUMMARY_FIELD, lines.isEmpty() ? null : String.join(lines, LINE_SEPARATOR));
        update as user toUpdate;
    }

    /** Loads the Opportunity under the running user's access permissions. */
    private static Opportunity queryOpportunity(Id opportunityId) {
        if (opportunityId == null) { throw new FundedAmountException(MSG_MISSING_RECORD); }
        List<Opportunity> found = [
            SELECT Id,
                Dragin_Engine__MCA_Name_1__c, Dragin_Engine__MCA_Name_2__c,
                Dragin_Engine__MCA_Name_3__c, Dragin_Engine__MCA_Name_4__c,
                Dragin_Engine__MCA_Name_5__c, Dragin_Engine__MCA_Name_6__c,
                Dragin_Engine__MCA_Name_7__c, Dragin_Engine__MCA_Name_8__c,
                Funded_Amounts_Summary__c
            FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1
        ];
        if (found.isEmpty()) { throw new FundedAmountException(MSG_NO_ACCESS); }
        return found[0];
    }

    /** Collects non-null amounts by slot after server-side validation. */
    private static Map<Integer, Decimal> collectAmounts(List<FundedAmountInput> amounts) {
        Map<Integer, Decimal> amountsBySlot = new Map<Integer, Decimal>();
        if (amounts == null) { return amountsBySlot; }
        for (FundedAmountInput input : amounts) {
            if (input == null || input.fundedAmount == null) { continue; }
            validateInput(input);
            amountsBySlot.put(input.mcaNumber, input.fundedAmount);
        }
        return amountsBySlot;
    }

    /** Rejects invalid slot numbers, negative values and more than two decimals. */
    private static void validateInput(FundedAmountInput input) {
        if (input.mcaNumber == null || input.mcaNumber < 1 || input.mcaNumber > MCA_NAME_FIELDS.size()) {
            throw new FundedAmountException(MSG_INVALID_SLOT);
        }
        if (input.fundedAmount < 0) { throw new FundedAmountException(MSG_NEGATIVE); }
        // Ignore insignificant trailing zeros when checking the submitted precision.
        if (input.fundedAmount.stripTrailingZeros().scale() > AMOUNT_SCALE) {
            throw new FundedAmountException(MSG_SCALE);
        }
    }

    /** Formats values consistently as 1,234.50, regardless of user locale. */
    @TestVisible
    private static String formatAmount(Decimal amount) {
        String plain = amount.setScale(AMOUNT_SCALE).toPlainString();
        String wholePart = plain.substringBefore('.');
        String centsPart = plain.substringAfter('.');
        String grouped = '';
        while (wholePart.length() > DIGIT_GROUP_SIZE) {
            grouped = THOUSANDS_SEPARATOR + wholePart.right(DIGIT_GROUP_SIZE) + grouped;
            wholePart = wholePart.left(wholePart.length() - DIGIT_GROUP_SIZE);
        }
        return wholePart + grouped + '.' + centsPart;
    }

    /** Reads existing summary lines, ignoring malformed amounts. */
    @TestVisible
    private static Map<String, Decimal> parseSummary(String summary) {
        Map<String, Decimal> amountsByName = new Map<String, Decimal>();
        if (String.isBlank(summary)) { return amountsByName; }
        for (String line : summary.split(LINE_SPLIT_PATTERN)) {
            // Use the final separator so MCA names containing colons remain intact.
            Integer separatorIndex = line.lastIndexOf(AMOUNT_SEPARATOR);
            if (separatorIndex <= 0) { continue; }
            String mcaName = line.left(separatorIndex).trim();
            Decimal amount = toDecimalOrNull(line.substring(separatorIndex + AMOUNT_SEPARATOR.length()));
            if (amount != null && !amountsByName.containsKey(mcaName)) {
                amountsByName.put(mcaName, amount);
            }
        }
        return amountsByName;
    }

    /**
     * Keeps each occurrence of a repeated MCA name in the stored summary's line order.
     * Slot order must remain stable; the text format does not carry slot identifiers.
     */
    private static Map<String, List<Decimal>> parseSummaryOccurrences(String summary) {
        Map<String, List<Decimal>> amountsByName = new Map<String, List<Decimal>>();
        if (String.isBlank(summary)) { return amountsByName; }
        for (String line : summary.split(LINE_SPLIT_PATTERN)) {
            // Use the last separator because an MCA name itself can contain a colon.
            Integer separatorIndex = line.lastIndexOf(AMOUNT_SEPARATOR);
            if (separatorIndex <= 0) { continue; }
            String name = line.left(separatorIndex).trim();
            Decimal amount = toDecimalOrNull(line.substring(separatorIndex + AMOUNT_SEPARATOR.length()));
            if (amount == null) { continue; }
            if (!amountsByName.containsKey(name)) {
                amountsByName.put(name, new List<Decimal>());
            }
            amountsByName.get(name).add(amount);
        }
        return amountsByName;
    }

    /** Parses a stored amount, ignoring malformed hand-edited values. */
    private static Decimal toDecimalOrNull(String amountText) {
        String cleaned = amountText.remove(THOUSANDS_SEPARATOR).trim();
        if (String.isBlank(cleaned)) { return null; }
        try { return Decimal.valueOf(cleaned); }
        catch (TypeException e) {
            System.debug(LoggingLevel.WARN, 'MCAFunding_FundedAmountController skipped an unparseable summary amount');
            return null;
        }
    }

    /** Wraps a safe user-facing message for the LWC. */
    private static AuraHandledException buildException(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    /** Logs a platform error with a reference and returns a safe user message. */
    private static AuraHandledException buildReferencedException(String userMessage, Exception e) {
        String reference = String.valueOf(Math.abs(Crypto.getRandomInteger())).leftPad(REFERENCE_LENGTH, '0').right(REFERENCE_LENGTH);
        System.debug(LoggingLevel.ERROR, 'MCAFunding_FundedAmountController failed | Ref ' + reference
            + ' | ' + e.getTypeName() + ': ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString());
        return buildException(userMessage + reference);
    }
}
