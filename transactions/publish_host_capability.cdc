#allowAccountLinking

import "StagedContractUpdates"

/// Publishes an Capability on the signer's AuthAccount for the specified recipient
///
transaction(publishFor: Address) {

    prepare(signer: AuthAccount) {

        let accountCapPrivatePath: PrivatePath = /private/StagedContractUpdatesAccountCap
        let hostPrivatePath: PrivatePath = /private/StagedContractUpdatesHost

        // Setup Capability on underlying signing host account
        if !signer.getCapability<&AuthAccount>(accountCapPrivatePath).check() {
            signer.unlink(accountCapPrivatePath)
            signer.linkAccount(accountCapPrivatePath)
                ?? panic("Problem linking AuthAccount Capability")
        }
        let accountCap = signer.getCapability<&AuthAccount>(accountCapPrivatePath)

        assert(accountCap.check(), message: "Invalid AuthAccount Capability retrieved")

        // Setup Host resource, wrapping the previously configured account capabaility
        if signer.type(at: StagedContractUpdates.HostStoragePath) == nil {
            signer.save(
                <- StagedContractUpdates.createNewHost(accountCap: accountCap),
                to: StagedContractUpdates.HostStoragePath
            )
        }
        if !signer.getCapability<&StagedContractUpdates.Host>(hostPrivatePath).check() {
            signer.unlink(hostPrivatePath)
            signer.link<&StagedContractUpdates.Host>(hostPrivatePath, target: StagedContractUpdates.HostStoragePath)
        }
        let hostCap = signer.getCapability<&StagedContractUpdates.Host>(hostPrivatePath)

        assert(hostCap.check(), message: "Invalid Host Capability retrieved")

        // Finally publish the Host Capability to the account that will store the Updater
        signer.inbox.publish(
            hostCap,
            name: StagedContractUpdates.inboxHostCapabilityNamePrefix.concat(publishFor.toString()),
            recipient: publishFor
        )
    }
}
