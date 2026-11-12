/**
 * Demo implementation of ContractFeed.Source: serves the sample contracts of the static resource MockContracts
 * (fictitious companies, no real data) with the same paging and "updated since" behaviour a real API would have.
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

        ContractFeed.ResultPage result = new ContractFeed.ResultPage();
        Integer first = (safePage - 1) * safeSize;
        for (Integer i = first; i < Math.min(first + safeSize, matching.size()); i++) {
            result.items.add(matching[i]);
        }
        result.hasMore = first + safeSize < matching.size();
        return result;
    }

    private static List<ContractFeed.Item> allItems() {
        List<StaticResource> resources = [SELECT Body FROM StaticResource WHERE Name = :RESOURCE_NAME LIMIT 1];
        if (resources.isEmpty()) {
            return new List<ContractFeed.Item>();
        }
        return (List<ContractFeed.Item>) JSON.deserialize(resources[0].Body.toString(), List<ContractFeed.Item>.class);
    }
}
