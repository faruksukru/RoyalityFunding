// MCAFunding_FundedAmountControllerTest.cls — Tests for the MCA Funded Amounts controller.

/**
 * Tests MCAFunding_FundedAmountController for MCA funded amount operations.
 *
 * Scenarios: populated-slot filtering, save and summary format, prefill from a saved summary,
 * clearing amounts, invalid input (negative, too many decimals, bad slot, missing record),
 * locale-independent formatting, tolerant parsing, and a user without Opportunity access.
 *
 * Bulk does not apply: the only entry point is a record page component acting on one Opportunity.
 *
 * @author Faruk Sukru Uslu
 * @date 2026-10-19
 * @version 1.0
 */
@isTest(SeeAllData=false)
private class MCAFunding_FundedAmountControllerTest {
    private static final String OPP_NAME = 'MCA Funded Amounts Test Opportunity';
    private static final String TEST_STAGE = 'Prospecting';
    private static final String MCA_1 = 'Northbridge Capital';
    private static final String MCA_2 = 'Summit Funding Group';
    private static final String MCA_4 = 'Harbor Lane Advance';
    private static final String MINIMUM_ACCESS_PROFILE = 'Minimum Access - Salesforce';

    @TestSetup
    static void setupTestData() {
        Opportunity opp = new Opportunity(
            Name = OPP_NAME,
            StageName = TEST_STAGE,
            CloseDate = Date.today().addDays(30),
            Dragin_Engine__MCA_Name_1__c = MCA_1,
            Dragin_Engine__MCA_Name_2__c = '  ' + MCA_2 + '  ',
            Dragin_Engine__MCA_Name_3__c = '   ',
            Dragin_Engine__MCA_Name_4__c = MCA_4
        );
        insert as system opp;
    }

    private static Opportunity getOpportunity() {
        return [
            SELECT Id, Funded_Amounts_Summary__c
            FROM Opportunity
            WHERE Name = :OPP_NAME
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    private static MCAFunding_FundedAmountController.FundedAmountInput buildInput(Integer mcaNumber, Decimal amount) {
        MCAFunding_FundedAmountController.FundedAmountInput input = new MCAFunding_FundedAmountController.FundedAmountInput();
        input.mcaNumber = mcaNumber;
        input.fundedAmount = amount;
        return input;
    }

    private static String saveExpectingError(Id recordId, List<MCAFunding_FundedAmountController.FundedAmountInput> amounts) {
        try {
            MCAFunding_FundedAmountController.saveFundedAmounts(recordId, amounts);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        return null;
    }

    @isTest
    static void getFundedAmounts_returnsOnlyPopulatedSlots() {
        Opportunity opp = getOpportunity();
        Test.startTest();
        List<MCAFunding_FundedAmountController.McaRow> rows = MCAFunding_FundedAmountController.getFundedAmounts(opp.Id);
        Test.stopTest();
        System.assertEquals(3, rows.size(), 'Blank and whitespace-only slots should be skipped');
        System.assertEquals(1, rows[0].mcaNumber, 'First row should be slot 1');
        System.assertEquals(MCA_1, rows[0].mcaName, 'Slot 1 name should be returned');
        System.assertEquals(MCA_2, rows[1].mcaName, 'Names should be trimmed');
        System.assertEquals(4, rows[2].mcaNumber, 'Slot 3 is blank, so the third row should be slot 4');
        System.assertEquals(null, rows[0].fundedAmount, 'No amount should be returned before anything is saved');
    }

    @isTest
    static void saveFundedAmounts_writesOneLinePerAmountInSlotOrder() {
        Opportunity opp = getOpportunity();
        List<MCAFunding_FundedAmountController.FundedAmountInput> amounts = new List<MCAFunding_FundedAmountController.FundedAmountInput>{
            buildInput(4, 1234.5),
            buildInput(1, 25000),
            buildInput(2, null)
        };
        Test.startTest();
        List<MCAFunding_FundedAmountController.McaRow> rows = MCAFunding_FundedAmountController.saveFundedAmounts(opp.Id, amounts);
        Test.stopTest();
        String expected = MCA_1 + ': $25,000.00\n' + MCA_4 + ': $1,234.50';
        System.assertEquals(expected, getOpportunity().Funded_Amounts_Summary__c, 'Summary should list amounts in slot order and skip blanks');
        System.assertEquals(25000, rows[0].fundedAmount, 'Returned rows should carry the saved amount for slot 1');
        System.assertEquals(null, rows[1].fundedAmount, 'Slot 2 had no amount and should stay empty');
        System.assertEquals(1234.50, rows[2].fundedAmount, 'Returned rows should carry the saved amount for slot 4');
    }

    @isTest
    static void getFundedAmounts_prefillsFromSavedSummary() {
        Opportunity opp = getOpportunity();
        opp.Funded_Amounts_Summary__c = MCA_1 + ': $10,500.25\r\nUnknown Funder: $99.00\n' + MCA_4 + ': $not-a-number';
        update as system opp;
        Test.startTest();
        List<MCAFunding_FundedAmountController.McaRow> rows = MCAFunding_FundedAmountController.getFundedAmounts(opp.Id);
        Test.stopTest();
        System.assertEquals(10500.25, rows[0].fundedAmount, 'Saved amount should prefill slot 1');
        System.assertEquals(null, rows[2].fundedAmount, 'An unparseable line should be skipped, not fail the load');
    }

    @isTest
    static void saveFundedAmounts_clearsSummaryWhenAllAmountsRemoved() {
        Opportunity opp = getOpportunity();
        opp.Funded_Amounts_Summary__c = MCA_1 + ': $500.00';
        update as system opp;
        Test.startTest();
        MCAFunding_FundedAmountController.saveFundedAmounts(opp.Id, new List<MCAFunding_FundedAmountController.FundedAmountInput>{
            buildInput(1, null)
        });
        Test.stopTest();
        System.assertEquals(null, getOpportunity().Funded_Amounts_Summary__c, 'Removing every amount should clear the summary');
    }

    @isTest
    static void saveFundedAmounts_ignoresAmountForEmptySlot() {
        Opportunity opp = getOpportunity();
        Test.startTest();
        MCAFunding_FundedAmountController.saveFundedAmounts(opp.Id, new List<MCAFunding_FundedAmountController.FundedAmountInput>{
            buildInput(3, 500),
            buildInput(1, 100)
        });
        Test.stopTest();
        System.assertEquals(MCA_1 + ': $100.00', getOpportunity().Funded_Amounts_Summary__c, 'An amount for a blank slot should not be written');
    }

    @isTest
    static void saveFundedAmounts_rejectsNegativeAmount() {
        Opportunity opp = getOpportunity();
        Test.startTest();
        String message = saveExpectingError(opp.Id, new List<MCAFunding_FundedAmountController.FundedAmountInput>{ buildInput(1, -1) });
        Test.stopTest();
        System.assertEquals('Funded amounts cannot be negative.', message, 'A negative amount should be rejected');
        System.assertEquals(null, getOpportunity().Funded_Amounts_Summary__c, 'Nothing should be written when validation fails');
    }

    @isTest
    static void saveFundedAmounts_rejectsMoreThanTwoDecimals() {
        Opportunity opp = getOpportunity();
        Test.startTest();
        String message = saveExpectingError(opp.Id, new List<MCAFunding_FundedAmountController.FundedAmountInput>{ buildInput(1, 10.555) });
        Test.stopTest();
        System.assertEquals('Funded amounts can have at most 2 decimal places.', message, 'Three decimals should be rejected');
    }

    @isTest
    static void saveFundedAmounts_rejectsSlotOutOfRange() {
        Opportunity opp = getOpportunity();
        Test.startTest();
        String message = saveExpectingError(opp.Id, new List<MCAFunding_FundedAmountController.FundedAmountInput>{ buildInput(9, 100) });
        Test.stopTest();
        System.assertNotEquals(null, message, 'Slot 9 does not exist and should be rejected');
        System.assert(message.contains('does not exist'), 'Message should explain the slot is invalid');
    }

    @isTest
    static void getFundedAmounts_rejectsMissingRecordId() {
        String message;
        Test.startTest();
        try {
            MCAFunding_FundedAmountController.getFundedAmounts(null);
        } catch (AuraHandledException e) {
            message = e.getMessage();
        }
        Test.stopTest();
        System.assertEquals('No record was provided to the MCA Funded Amounts component.', message, 'A null id should be rejected clearly');
    }

    @isTest
    static void getFundedAmounts_failsSafelyWithoutOpportunityAccess() {
        Opportunity opp = getOpportunity();
        Profile minimumAccess = [SELECT Id FROM Profile WHERE Name = :MINIMUM_ACCESS_PROFILE WITH SYSTEM_MODE LIMIT 1];
        String uniqueKey = String.valueOf(Math.abs(Crypto.getRandomInteger()));
        User restrictedUser = new User(
            Alias = 'mcatst',
            Email = 'mca.restricted@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Restricted',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = minimumAccess.Id,
            TimeZoneSidKey = 'America/New_York',
            Username = 'mca.restricted.' + uniqueKey + '@example.com.test'
        );
        insert as system restrictedUser;
        String message;
        Test.startTest();
        System.runAs(restrictedUser) {
            try {
                MCAFunding_FundedAmountController.getFundedAmounts(opp.Id);
            } catch (AuraHandledException e) {
                message = e.getMessage();
            }
        }
        Test.stopTest();
        System.assertNotEquals(null, message, 'A user without Opportunity access should get an error, not data');
        System.assert(!message.contains('Dragin_Engine__'), 'Raw platform detail should not reach the user');
    }

    @isTest
    static void formatAmount_isLocaleIndependent() {
        System.assertEquals('0.00', MCAFunding_FundedAmountController.formatAmount(0), 'Zero should format with 2 decimals');
        System.assertEquals('999.90', MCAFunding_FundedAmountController.formatAmount(999.9), 'No separator below 1,000');
        System.assertEquals('1,234,567.80', MCAFunding_FundedAmountController.formatAmount(1234567.8), 'Thousands should be grouped');
    }

    @isTest
    static void parseSummary_handlesNamesWithColonsAndBlankInput() {
        Map<String, Decimal> parsed = MCAFunding_FundedAmountController.parseSummary('Acme: West Capital: $2,000.00\nno separator here');
        System.assertEquals(1, parsed.size(), 'Only the well-formed line should parse');
        System.assertEquals(2000.00, parsed.get('Acme: West Capital'), 'The last separator on the line should be used');
        System.assert(MCAFunding_FundedAmountController.parseSummary(null).isEmpty(), 'A blank summary should parse to nothing');
    }
}
