/**
 * Contract synchronisation contract: what ContractSyncJob needs from any contract source.
 *
 * This repository ships ONLY a mock source (MockContractSource, sample JSON in the static resource MockContracts):
 * no callouts, no endpoints, no credentials. To connect a real system, write another class implementing
 * ContractFeed.Source (e.g. an HTTP adapter using a Named Credential, so no secret lives in code) and return it
 * from source(). ContractSyncJob and the data model do not change.
 */
public with sharing class ContractFeed {
    @TestVisible private static Source sourceOverride;

    public interface Source {
        ResultPage fetchUpdatedSince(Datetime updatedSince, Integer page, Integer pageSize);
    }

    public class Item {
        public String id;
        public String reference;
        public String status;
        public String counterpartyName;
        public String counterpartyAccountNumber;
        public Date effectiveDate;
        public Date endDate;
        public Datetime updatedAt;
        public String documentUrl;
    }

    public class ResultPage {
        public List<Item> items = new List<Item>();
        public Boolean hasMore = false;
    }

    public static Source source() {
        return sourceOverride != null ? sourceOverride : new MockContractSource();
    }
}
