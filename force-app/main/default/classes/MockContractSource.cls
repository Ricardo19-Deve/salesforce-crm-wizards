/**
 * Demo implementation of ContractFeed.Source: serves the sample contracts of the static resource MockContracts
 * (fictitious companies, no real data) with the same paging, "updated since" filter and oldest-change-first order a
 * real API would have.
 * Makes no callout.
 */
public with sharing class MockContractSource implements ContractFeed.Source {
    @TestVisible private static final String RESOURCE_NAME = 'MockContracts';

    public ContractFeed.ResultPage fetchUpdatedSince(Datetime updatedSince, Integer page, Integer pageSize) {
        Integer safePage = Math.max(page == null ? 1 : page, 1);
        Integer safeSize = Math.max(pageSize == null ? 100 : pageSize, 1);

        List<ContractFeed.Item> matching = new List<ContractFeed.Item>();
        for (ContractFeed.Item item : allItems()) {
            if (updatedSince == null || (item.updatedAt != null && item.updatedAt > updatedSince)) {
                matching.add(item);
            }
        }

        List<ByUpdate> ordered = new List<ByUpdate>();
        for (ContractFeed.Item item : matching) {
            ordered.add(new ByUpdate(item));
        }
        ordered.sort();
        matching.clear();
        for (ByUpdate wrapper : ordered) {
            matching.add(wrapper.item);
        }

        ContractFeed.ResultPage result = new ContractFeed.ResultPage();
        Integer first = (safePage - 1) * safeSize;
        for (Integer i = first; i < Math.min(first + safeSize, matching.size()); i++) {
            result.items.add(matching[i]);
        }
        result.hasMore = first + safeSize < matching.size();
        return result;
    }

    /** Oldest change first, then by id, as ContractFeed.Source requires. */
    private class ByUpdate implements Comparable {
        final ContractFeed.Item item;
        ByUpdate(ContractFeed.Item item) {
            this.item = item;
        }
        public Integer compareTo(Object other) {
            ContractFeed.Item that = ((ByUpdate) other).item;
            Long mine = item.updatedAt == null ? 0 : item.updatedAt.getTime();
            Long theirs = that.updatedAt == null ? 0 : that.updatedAt.getTime();
            if (mine != theirs) {
                return mine < theirs ? -1 : 1;
            }
            String myId = item.id == null ? '' : item.id;
            String theirId = that.id == null ? '' : that.id;
            return myId.compareTo(theirId);
        }
    }

    private static List<ContractFeed.Item> allItems() {
        List<StaticResource> resources = [SELECT Body FROM StaticResource WHERE Name = :RESOURCE_NAME LIMIT 1];
        if (resources.isEmpty()) {
            return new List<ContractFeed.Item>();
        }
        return (List<ContractFeed.Item>) JSON.deserialize(resources[0].Body.toString(), List<ContractFeed.Item>.class);
    }
}
