/** Reads and saves MCA funded amounts on an Opportunity. */
public with sharing class MCAFunding_FundedAmountController {
    private static final String AMOUNT_SEPARATOR = ': $', LINE_SEPARATOR = '\n', LINE_SPLIT_PATTERN = '\\r?\\n', THOUSANDS_SEPARATOR = ',';
    private static final Integer AMOUNT_SCALE = 2, DIGIT_GROUP_SIZE = 3, REFERENCE_LENGTH = 6;
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

    public class FundedAmountException extends Exception {}

    public class McaRow {
        @AuraEnabled public Integer mcaNumber;
        @AuraEnabled public String mcaName;
        @AuraEnabled public Decimal fundedAmount;
        public McaRow(Integer mcaNumber, String mcaName, Decimal fundedAmount) {
            this.mcaNumber = mcaNumber; this.mcaName = mcaName; this.fundedAmount = fundedAmount;
        }
    }

    public class FundedAmountInput {
        @AuraEnabled public Integer mcaNumber { get; set; }
        @AuraEnabled public Decimal fundedAmount { get; set; }
    }

    /** Returns populated MCA slots with any previously saved amounts. */
    @AuraEnabled(cacheable=true)
    public static List<McaRow> getFundedAmounts(Id recordId) {
        try { return getRows(recordId); }
        catch (FundedAmountException e) { throw buildException(e.getMessage()); }
        catch (QueryException e) { throw buildReferencedException(MSG_LOAD_FAILED, e); }
        catch (Exception e) { throw buildReferencedException(MSG_LOAD_FAILED, e); }
    }

    /** Validates amounts, saves the summary and returns refreshed rows. */
    @AuraEnabled
    public static List<McaRow> saveFundedAmounts(Id recordId, List<FundedAmountInput> amounts) {
        try { writeSummary(recordId, amounts); return getRows(recordId); }
        catch (FundedAmountException e) { throw buildException(e.getMessage()); }
        catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) throw buildException(e.getDmlMessage(0));
            throw buildReferencedException(MSG_SAVE_FAILED, e);
        }
        catch (QueryException e) { throw buildReferencedException(MSG_SAVE_FAILED, e); }
        catch (Exception e) { throw buildReferencedException(MSG_SAVE_FAILED, e); }
    }

    private static List<McaRow> getRows(Id opportunityId) {
        Opportunity opp = queryOpportunity(opportunityId);
        Map<String, Decimal> savedByName = parseSummary((String) opp.get(SUMMARY_FIELD));
        List<McaRow> rows = new List<McaRow>();
        for (Integer i = 0; i < MCA_NAME_FIELDS.size(); i++) {
            String mcaName = (String) opp.get(MCA_NAME_FIELDS[i]);
            if (String.isBlank(mcaName)) continue;
            rows.add(new McaRow(i + 1, mcaName.trim(), savedByName.get(mcaName.trim())));
        }
        return rows;
    }

    private static void writeSummary(Id opportunityId, List<FundedAmountInput> amounts) {
        Opportunity opp = queryOpportunity(opportunityId);
        Map<Integer, Decimal> amountsBySlot = collectAmounts(amounts);
        List<String> lines = new List<String>();
        for (Integer i = 0; i < MCA_NAME_FIELDS.size(); i++) {
            String mcaName = (String) opp.get(MCA_NAME_FIELDS[i]);
            Decimal amount = amountsBySlot.get(i + 1);
            if (String.isBlank(mcaName) || amount == null) continue;
            lines.add(mcaName.trim() + AMOUNT_SEPARATOR + formatAmount(amount));
        }
        Opportunity toUpdate = new Opportunity(Id = opportunityId);
        toUpdate.put(SUMMARY_FIELD, lines.isEmpty() ? null : String.join(lines, LINE_SEPARATOR));
        update as user toUpdate;
    }

    private static Opportunity queryOpportunity(Id opportunityId) {
        if (opportunityId == null) throw new FundedAmountException(MSG_MISSING_RECORD);
        List<Opportunity> found = [
            SELECT Id,
                Dragin_Engine__MCA_Name_1__c, Dragin_Engine__MCA_Name_2__c,
                Dragin_Engine__MCA_Name_3__c, Dragin_Engine__MCA_Name_4__c,
                Dragin_Engine__MCA_Name_5__c, Dragin_Engine__MCA_Name_6__c,
                Dragin_Engine__MCA_Name_7__c, Dragin_Engine__MCA_Name_8__c,
                Funded_Amounts_Summary__c
            FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1
        ];
        if (found.isEmpty()) throw new FundedAmountException(MSG_NO_ACCESS);
        return found[0];
    }

    private static Map<Integer, Decimal> collectAmounts(List<FundedAmountInput> amounts) {
        Map<Integer, Decimal> amountsBySlot = new Map<Integer, Decimal>();
        if (amounts == null) return amountsBySlot;
        for (FundedAmountInput input : amounts) {
            if (input == null || input.fundedAmount == null) continue;
            validateInput(input);
            amountsBySlot.put(input.mcaNumber, input.fundedAmount);
        }
        return amountsBySlot;
    }

    private static void validateInput(FundedAmountInput input) {
        if (input.mcaNumber == null || input.mcaNumber < 1 || input.mcaNumber > MCA_NAME_FIELDS.size())
            throw new FundedAmountException(MSG_INVALID_SLOT);
        if (input.fundedAmount < 0) throw new FundedAmountException(MSG_NEGATIVE);
        if (input.fundedAmount.stripTrailingZeros().scale() > AMOUNT_SCALE) throw new FundedAmountException(MSG_SCALE);
    }

    /** Formats values consistently as 1,234.50, regardless of user locale. */
    @TestVisible
    private static String formatAmount(Decimal amount) {
        String plain = amount.setScale(AMOUNT_SCALE).toPlainString();
        String wholePart = plain.substringBefore('.'), centsPart = plain.substringAfter('.');
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
        if (String.isBlank(summary)) return amountsByName;
        for (String line : summary.split(LINE_SPLIT_PATTERN)) {
            Integer separatorIndex = line.lastIndexOf(AMOUNT_SEPARATOR);
            if (separatorIndex <= 0) continue;
            String mcaName = line.left(separatorIndex).trim();
            Decimal amount = toDecimalOrNull(line.substring(separatorIndex + AMOUNT_SEPARATOR.length()));
            if (amount != null && !amountsByName.containsKey(mcaName)) amountsByName.put(mcaName, amount);
        }
        return amountsByName;
    }

    private static Decimal toDecimalOrNull(String amountText) {
        String cleaned = amountText.remove(THOUSANDS_SEPARATOR).trim();
        if (String.isBlank(cleaned)) return null;
        try { return Decimal.valueOf(cleaned); }
        catch (TypeException e) {
            System.debug(LoggingLevel.WARN, 'MCAFunding_FundedAmountController skipped an unparseable summary amount');
            return null;
        }
    }

    private static AuraHandledException buildException(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    private static AuraHandledException buildReferencedException(String userMessage, Exception e) {
        String reference = String.valueOf(Math.abs(Crypto.getRandomInteger())).leftPad(REFERENCE_LENGTH, '0').right(REFERENCE_LENGTH);
        System.debug(LoggingLevel.ERROR, 'MCAFunding_FundedAmountController failed | Ref ' + reference
            + ' | ' + e.getTypeName() + ': ' + e.getMessage() + ' | Stack: ' + e.getStackTraceString());
        return buildException(userMessage + reference);
    }
}
