/**
 * Daily trigger of the contract synchronisation (a Queueable cannot also be Schedulable).
 *   System.schedule('Contract sync', '0 0 2 * * ?', new ContractSyncScheduler());
 */
public with sharing class ContractSyncScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        System.enqueueJob(ContractSyncJob.fromLastSync());
    }
}
