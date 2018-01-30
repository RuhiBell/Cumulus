/*
    Copyright (c) 2018, Salesforce.org
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2018
* @group Rollups
* @group-content ../../ApexDocContent/Rollups2.htm
* @description Abstract base class for all Customizable Rollup batch jobs
*/
public abstract class CRLP_AbstractRollup_BATCH {

    /** @description Set to True if the batch job is of an LDV type; where the primary object is the detail */
    protected Boolean isLdvBatchJob = false;

    /** @description Because Salesforce may call the execute method with sorted blocks of data out of sequence
     * it's necessary to store the working rollup data in a stateful map. Rather than write the current state to
     * the parent record multiple times, the code will keep uncommited rollup data in the stateful var for up to
     * this number of batch iterations. After that number, the record will be committed to the database. There
     * are a couple of assumptions here: a) Salesforce will not likely put data so much out of sequence that there
     * are more than 30 batches of data between two batches for the same parent id; b) 30 is an acceptable number
     * for heap size.
     */
    protected Integer NUMBER_OF_BATCHES_TO_HOLD_COMMITS = 30;

    /**
    * @description Stateful collection of Rollups used to hold Rollups for Contacts and Accounts that
    * span beyond a single batch iteration
    */
    protected Map<Id, List<CRLP_Rollup>> statefulRollupsById;

    /**
    * @description This list is effectively the keyset of statefulRollupsById, but it's used to keep the list of
    * Id's in a specific sequence so that element 0 can be dropped when the 1000th element is added. When dropped,
    * that key is also removed from the statefulRollupsById map. The intent is to keep the heap size for the stateful
    * Map of CRLP_Rollup data limited to avoid a governor limit when dealing with millions of records.
    */
    protected List<Id> statefulListOfSavedIds;

    /**
     * @description Map of Opportunity Id's already processed by Account to avoid duplicating a donation amount
     * to the Account when rolling up soft credits by the Contact.AccountId
     */
    protected Map<Id,Set<Id>> statefulMapOfOppIdsByAcct;

    /** @description Rather than commit the parent record every time the lastParentIdProcessed is changed,
     * which can cause a single parent to be committed multiple times, this is used to track which parent records
     * have not yet been committed. This is useful when Salesforce calls the execute() method with blocks of data
     * out of sequence.
     */
    protected Map<Id, Integer> parentIdsNotCommittedWithBatch = new Map<Id, Integer>();

    /** @description Simple counters used to track state */
    protected Integer batchIteration = 0;
    protected Integer totalRecordsModified = 0;

    /** @description Are there Soft Credits to Contact-Account rollups to execute? */
    protected Boolean hasAccountSoftCreditRollups = false;

    /** @description Are there Soft Credits to Contact rollups to execute? */
    protected Boolean hasContactSoftCreditRollups = false;

    /** @description Specified list of Summary (Account, Contact or GAU) Id's to roll up */
    protected List<Id> recordIds;

    /** @description The Summary Object Type this batch job will process */
    protected SObjectType summaryObjectType;

    /*******************************************************************************************************
     * @description Constructs the class, inits the class instance vars used across all CRLP batch jobs
     */
    public CRLP_AbstractRollup_BATCH() {
        this.statefulRollupsById = new Map<Id, List<CRLP_Rollup>>();
        this.statefulMapOfOppIdsByAcct = new Map<Id, Set<Id>>();
        this.statefulListOfSavedIds = new List<Id>();
        initSoftCreditRollupTypes();
    }

    /*******************************************************************************************************
     * @description Constructs the class - rollup is for a specific Summary SObject
     */
    public CRLP_AbstractRollup_BATCH(SObjectType objType) {
        this();
        this.summaryObjectType = objType;
    }

    /*******************************************************************************************************
     * @description Constructs the class - Rollup is for a specific set of Summary Object Id's
     */
    public CRLP_AbstractRollup_BATCH(List<Id> recordIds) {
        this();
        this.summaryObjectType = recordIds[0].getSobjectType();
        this.recordIds = recordIds;
    }

    /**
     * @description Set the hasAccountSoftCreditRollups and hasContactSoftCreditRollups instance vars based on
     * the current active customizable rollups in the org
     */
    private void initSoftCreditRollupTypes() {
        String pscObjectName = UTIL_Describe.getObjectDescribe(UTIL_Namespace.StrAllNSPrefix('Partial_Soft_Credit__c')).getName();

        // Loop through all the Active Rollup Definitions to determine if there are Soft Credit Rollups
        // definitions for either the Account and/or Contact object
        for (Rollup__mdt r : CRLP_Rollup_SEL.getRollupDefinitions()) {
            // Due to how PartialSoftCredit and Opportunity interact with Rollups, the Detail Object
            // can still be set to Opportunity for some of the PartialSoftCredit rollups. As a result,
            // the only reliable ObjectField to check against is AmountObject since that will always point
            // to the PartialSoftCredit object for these types of rollups.
            if (r.Amount_Object__r.QualifiedApiName == pscObjectName && r.Active__c == true) {
                this.hasAccountSoftCreditRollups = (this.hasAccountSoftCreditRollups || r.Summary_Object__r.QualifiedApiName == 'Account');
                this.hasContactSoftCreditRollups = (this.hasContactSoftCreditRollups || r.Summary_Object__r.QualifiedApiName == 'Contact');
            }
        }
    }

    /**
     * @description Resequence the Parent (Summary) records to be in the exact order of the detail records
     * using the defined parent Id
     * @param parentIds
     * @param summaryRecords
     * @return a list of Parent (Summary) SObject records in the proper order
     */
    protected List<SObject> resequenceSummaryRecords(List<Id> parentIds, List<SObject> summaryRecords) {
        // Resequence the Parent (Summary) records to be in the exact order of the detail records
        // using the defined parent Id
        List<SObject> reorderedSummaryRecords = new List<SObject>();
        Map<Id, SObject> mapOfSummaryRecords = new Map<Id, SObject>(summaryRecords);
        for (Id parentId : parentIds) {
            reorderedSummaryRecords.add(mapOfSummaryRecords.get(parentId));
        }
        return reorderedSummaryRecords;
    }

    /********************************************************************************************************
     * @description Create an instance of the CRLP_RollupProcessor_SVC.ProcessingOptions class to use with the
     * CRLP_RollupProcessor_SVC.startRollupProcess() calls.
     * @return CRLP_RollupProcessor_SVC.ProcessingOptions
     */
    protected CRLP_RollupProcessor_SVC.ProcessingOptions initOptionsInstance() {
        CRLP_RollupProcessor_SVC.ProcessingOptions options = new CRLP_RollupProcessor_SVC.ProcessingOptions();
        options.mode = (this.isLdvBatchJob ? CRLP_RollupProcessor_SVC.ProcessingMode.LDV : CRLP_RollupProcessor_SVC.ProcessingMode.NonLDV);
        options.detailObjType = Opportunity.SObjectType;    // the default type
        options.parentObjType = this.summaryObjectType;

        options.mapOfRollupsByParentId = this.statefulRollupsById;
        options.mapOfProcessedOppIdsByAcctId = this.statefulMapOfOppIdsByAcct;

        if (this.summaryObjectType == Account.SObjectType) {
            options.parentKeyField = SObjectType.Opportunity.fields.AccountId.getName();
        } else if (this.summaryObjectType == Contact.SObjectType) {
            options.parentKeyField = SObjectType.Opportunity.fields.Primary_Contact__c.getName();
        } else if (this.summaryObjectType == General_Accounting_Unit__c.SObjectType) {
            options.parentKeyField = SObjectType.Allocation__c.fields.General_Accounting_Unit__c.getName();
            options.detailObjType = Allocation__c.SObjectType;
        }

        return options;
    }

    /**
     * @description Retrieve a list of unique parent Id records from a set of detail records, taking into account
     * parent id records from previous batches that may be in the stateful collection of id's not yet committed.
     * @param objType
     * @param detailRecords
     * @param keyField
     * @return List of Unique Parent (Summary) record Id's
     */
    protected List<Id> getUniqueParentIds(SObjectType objType, List<SObject> detailRecords, String keyField) {
        // Get all parent records to be processed by this batch iteration
        List<Id> parentIds = getParentIdsFromDetailRecords(detailRecords, keyField);
        if (!this.parentIdsNotCommittedWithBatch.isEmpty()) {
            Set<Id> uniqueParentIds = new Set<Id>(parentIds);
            // Don't add the last parent Id to the list UNLESS at least four batches have gone by. This is way of
            // handling Salesforce's out of sequence baches while avoiding too many commits for a single record
            for (Id lastId : this.parentIdsNotCommittedWithBatch.keySet()) {
                if (lastId.getSobjectType() == objType) {
                    if (this.batchIteration - this.parentIdsNotCommittedWithBatch.get(lastId) > NUMBER_OF_BATCHES_TO_HOLD_COMMITS) {
                        if (!uniqueParentIds.contains(lastId)) {
                            parentIds.add(lastId);
                            uniqueParentIds.add(lastId);
                            this.parentIdsNotCommittedWithBatch.remove(lastId);
                        }
                    }
                }
            }
        }
        return parentIds;
    }

    /**
     * @description For a given set of records, returns a Set<Id> of parent records using the passed field name as the parent
     * @param detailRecords List<SObject>
     * @param parentKeyField API Name of the parent field to use for the Id
     * @return List<Id>
     */
    protected List<Id> getParentIdsFromDetailRecords(List<SObject> detailRecords, String parentKeyField) {
        Set<Id> parentIdSet = new Set<Id>();
        List<Id> parentIds = new List<Id>();
        // If the parentKeyField is something like Contact.AccountId, then have to retrieve the parent SObject
        // first and then get the field value.
        String parentObjectField;
        if (parentKeyField.contains('.')) {
            parentObjectField = parentKeyField.split('\\.')[0];
            parentKeyField = parentKeyField.split('\\.')[1];
        }
        for (SObject dtl : detailRecords) {
            SObject dtlRecord = dtl;
            if (parentObjectField != null) {
                dtlRecord = dtl.getSObject(parentObjectField);
            }
            if (dtlRecord.get(parentKeyField) != null) {
                Id parentId = (Id)dtlRecord.get(parentKeyField);
                // Use a set to ensure that the parentId is only in the collection one time since there is no
                // contains() yet, but use a List to keep the parentId records in the exact same sequence
                // that they are in the details collection
                if (!parentIdSet.contains(parentId)) {
                    parentIds.add(parentId);
                    parentIdSet.add(parentId);
                }
            }
        }
        return parentIds;
    }

    /** @description FOR TESTING ONLY */
    protected String getHeapSize() {
        Decimal remainingHeapSize = (Limits.getLimitHeapSize() - Limits.getHeapSize())*1000;
        Decimal maxHeapSize = Limits.getLimitHeapSize()*1000;
        Decimal pctUsed = remainingHeapSize.divide(maxHeapSize, 3, System.RoundingMode.HALF_UP)/1000;
        return pctUsed.format() + '% used of ' + Limits.getLimitHeapSize().format();
    }
}