/// This contract defines resources which enable storage of contract code for the purposes of updating at or beyond 
/// some blockheight boundary either by the containing resource's owner or by some delegated party.
///
/// The two primary resources involved in this are the @Updater and @Delegatee resources. As their names suggest, the
/// @Updater contains Capabilities for all deployment accounts as well as the corresponding contract code + names in
/// the order of their update deployment as well as a blockheight at or beyond which the update can be performed. The
/// @Delegatee resource can receive Capabilities to the @Updater resource and can perform the update on behalf of the
/// @Updater resource's owner.
///
/// At the time of this writing, failed updates are not handled gracefully and will result in the halted iteration, but
/// recent conversations point to the possibility of amending the AuthAccount.Contract API to allow for a graceful
/// recovery from failed updates. If this method is not added, we'll want to reconsider the approach in favor of a 
/// single update() call per transaction.
/// See the following issue for more info: https://github.com/onflow/cadence/issues/2700
///
pub contract ContractUpdater {

    pub let inboxAccountCapabilityNamePrefix: String

    /* --- Canonical Paths --- */
    //
    pub let UpdaterStoragePath: StoragePath
    pub let DelegatedUpdaterPrivatePath: PrivatePath
    pub let UpdaterPublicPath: PublicPath
    pub let UpdaterContractAccountPrivatePath: PrivatePath
    pub let DelegateeStoragePath: StoragePath
    pub let DelegateePrivatePath: PrivatePath
    pub let DelegateePublicPath: PublicPath

    /* --- Events --- */
    //
    pub event UpdaterCreated(updaterUUID: UInt64, blockUpdateBoundary: UInt64)
    pub event UpdaterUpdated(
        updaterUUID: UInt64,
        updaterAddress: Address?,
        blockUpdateBoundary: UInt64,
        updatedAddresses: [Address],
        updatedContracts: [String],
        failedAddresses: [Address],
        failedContracts: [String]
    )
    pub event UpdaterDelegationChanged(updaterUUID: UInt64, updaterAddress: Address?, delegated: Bool)

    /// Represents contract and its corresponding code
    ///
    pub struct ContractUpdate {
        pub let address: Address
        pub let name: String
        pub let code: [UInt8]

        init(address: Address, name: String, code: [UInt8]) {
            self.address = address
            self.name = name
            self.code = code
        }

        /// Serializes the address and name into a string
        pub fun toString(): String {
            return self.address.toString().concat(".").concat(self.name)
        }

        /// Returns code as a String
        pub fun stringifyCode(): String {
            return String.fromUTF8(self.code) ?? panic("Problem stringifying code!")
        }
    }

    /* --- Updater --- */
    //
    /// Private Capability enabling delegated updates
    ///
    pub resource interface DelegatedUpdater {
        pub fun update(): Bool
    }

    /// Public interface enabling queries about the Updater
    ///
    pub resource interface UpdaterPublic {
        pub fun getID(): UInt64
        pub fun getBlockUpdateBoundary(): UInt64
        pub fun getContractAccountAddresses(): [Address]
        pub fun getDeployment(): [ContractUpdate]
        pub fun hasBeenUpdated(): Bool
    }

    /// Resource that enables delayed contract updates to a wrapped account at or beyond a specified block height
    ///
    pub resource Updater : UpdaterPublic, DelegatedUpdater {
        /// Update to occur at or beyond this block height
        // TODO: Consider making this a contract-owned value as it's reflective of the spork height
        access(self) let blockUpdateBoundary: UInt64
        /// Update status for each contract
        access(self) var updated: Bool
        /// Capabilities for contract hosting accounts
        access(self) let accounts: {Address: Capability<&AuthAccount>}
        /// Order of updates to be performed
        /// NOTE: Dev should be careful to validate their dependency tree such that updates are performed from root 
        /// to leaf dependencies
        access(self) let deployment: [ContractUpdate]

        init(
            blockUpdateBoundary: UInt64,
            accounts: [Capability<&AuthAccount>],
            deployment: [ContractUpdate]
        ) {
            self.blockUpdateBoundary = blockUpdateBoundary
            self.updated = false
            self.accounts = {}
            // Validate given Capabilities
            for account in accounts {
                if !account.check() {
                    panic("Account capability is invalid for account: ".concat(account.address.toString()))
                }
                self.accounts.insert(key: account.borrow()!.address, account)
            }
            // Validate given deployment
            for contractUpdate in deployment {
                if !self.accounts.containsKey(contractUpdate.address) {
                    panic("Contract address not found in given accounts: ".concat(contractUpdate.address.toString()))
                }
            }
            self.deployment = deployment
        }

        /// Executes the update using Account.Contracts.update__experimental() for all contracts defined in deployment,
        /// returning true if either update was previously completed or all updates succeed, and false if any update
        /// fails
        ///
        pub fun update(): Bool {
            // Return early if we've already updated
            if self.updated {
                return true
            }
            
            let updatedAddresses: [Address] = []
            let failedAddresses: [Address] = []
            let updatedContracts: [String] = []
            let failedContracts: [String] = []

            // Update the contracts as specified in the deployment
            for contractUpdate in self.deployment {
                // Borrow the contract account
                if let account = self.accounts[contractUpdate.address]!.borrow() {
                    // Update the contract
                    // TODO: Swap out optional/Bool API tryUpdate() (or similar) and do stuff if update fails
                    // if account.contracts.tryUpdate(name: contractUpdate.name, code: contractUpdate.code) == false {
                    //     failedAddresses.append(account.address)
                    //     failedContracts.append(contractUpdate.toString())
                    //     continue
                    // } else {
                    //     if !updatedAddresses.contains(account.address) {
                    //         updatedAddresses.append(account.address)
                    //     }
                    //     if !updatedContracts.contains(contractUpdate.toString()) {
                    //         updatedContracts.append(contractUpdate.toString())
                    //     }
                    // }
                    account.contracts.update__experimental(name: contractUpdate.name, code: contractUpdate.code)
                    if !updatedAddresses.contains(account.address) {
                        updatedAddresses.append(account.address)
                    }
                    if !updatedContracts.contains(contractUpdate.toString()) {
                        updatedContracts.append(contractUpdate.toString())
                    }
                }
            }
            if failedContracts.length == 0 {
                self.updated = true
            }
            emit UpdaterUpdated(
                updaterUUID: self.uuid,
                updaterAddress: self.owner?.address,
                blockUpdateBoundary: self.blockUpdateBoundary,
                updatedAddresses: updatedAddresses,
                updatedContracts: updatedContracts,
                failedAddresses: failedAddresses,
                failedContracts: failedContracts
            )
            return self.updated
        }

        /* --- Public getters --- */

        pub fun getID(): UInt64 {
            return self.uuid
        }

        pub fun getBlockUpdateBoundary(): UInt64 {
            return self.blockUpdateBoundary
        }

        pub fun getContractAccountAddresses(): [Address] {
            return self.accounts.keys
        }

        pub fun getDeployment(): [ContractUpdate] {
            return self.deployment
        }

        pub fun hasBeenUpdated(): Bool {
            return self.updated
        }
    }

    /* --- Delegatee --- */
    //
    /// Public interface for Delegatee
    ///
    pub resource interface DelegateePublic {
        pub fun check(id: UInt64): Bool?
        pub fun getUpdaterIDs(): [UInt64]
        pub fun delegate(updaterCap: Capability<&Updater{DelegatedUpdater, UpdaterPublic}>)
        pub fun removeAsUpdater(updaterCap: Capability<&Updater{DelegatedUpdater, UpdaterPublic}>)
    }

    /// Resource that executed delegated updates
    ///
    pub resource Delegatee : DelegateePublic {
        // TODO: Block Height - All DelegatedUpdaters must be updated at or beyond this block height
        // access(self) let blockUpdateBoundary: UInt64
        /// Track all delegated updaters
        access(self) let delegatedUpdaters: {UInt64: Capability<&Updater{DelegatedUpdater, UpdaterPublic}>}

        init() {
            self.delegatedUpdaters = {}
        }

        /// Checks if the specified DelegatedUpdater Capability is contained and valid
        ///
        pub fun check(id: UInt64): Bool? {
            return self.delegatedUpdaters[id]?.check() ?? nil
        }

        /// Returns the IDs of the delegated updaters 
        ///
        pub fun getUpdaterIDs(): [UInt64] {
            return self.delegatedUpdaters.keys
        }

        /// Allows for the delegation of updates to a contract
        ///
        pub fun delegate(updaterCap: Capability<&Updater{DelegatedUpdater, UpdaterPublic}>) {
            pre {
                updaterCap.check(): "Invalid DelegatedUpdater Capability!"
            }
            let updater = updaterCap.borrow()!
            if self.delegatedUpdaters.containsKey(updater.getID()) {
                // Upsert if updater already exists
                self.delegatedUpdaters[updater.getID()] = updaterCap
            } else {
                // Insert if updater does not exist
                self.delegatedUpdaters.insert(key: updater.getID(), updaterCap)
            }
            emit UpdaterDelegationChanged(updaterUUID: updater.getID(), updaterAddress: updater.owner?.address, delegated: true)
        }

        /// Enables Updaters to remove their delegation
        ///
        pub fun removeAsUpdater(updaterCap: Capability<&Updater{DelegatedUpdater, UpdaterPublic}>) {
            pre {
                updaterCap.check(): "Invalid DelegatedUpdater Capability!"
                self.delegatedUpdaters.containsKey(updaterCap.borrow()!.getID()): "No Updater found for ID!"
            }
            let updater = updaterCap.borrow()!
            self.removeDelegatedUpdater(id: updater.getID())
        }

        /// Executes update on the specified Updater
        ///
        pub fun update(updaterIDs: [UInt64]): [UInt64] {
            let failed: [UInt64] = []

            for id in updaterIDs {
                if self.delegatedUpdaters[id] == nil {
                    failed.append(id)
                    continue
                }
                let updaterCap = self.delegatedUpdaters[id]!
                if !updaterCap.check() {
                    failed.append(id)
                    continue
                }
                let success = updaterCap.borrow()!.update()
                if !success {
                    failed.append(id)
                }
            }
            return failed
        }

        /// Enables admin removal of a DelegatedUpdater Capability
        pub fun removeDelegatedUpdater(id: UInt64) {
            if !self.delegatedUpdaters.containsKey(id) {
                return
            }
            let updaterCap = self.delegatedUpdaters.remove(key: id)!
            emit UpdaterDelegationChanged(updaterUUID: id, updaterAddress: updaterCap.borrow()?.owner?.address, delegated: false)
        }
    }

    /// Returns the Address of the Delegatee associated with this contract
    ///
    pub fun getContractDelegateeAddress(): Address {
        return self.account.address
    }

    /// Helper method that returns the ordered array reflecting order of deployment, with each contract update
    /// deployment represented by a ContractUpdate struct.
    ///
    /// NOTES: deploymentConfig is ordered, and the order is used to determine the order of the contracts in the
    /// deployment. Each entry in the array must be exactly one key-value pair, where the key is the address of the
    /// associated contract name and code.
    ///
    pub fun getDeploymentFromConfig(_ deploymentConfig: [{Address: {String: String}}]): [ContractUpdate] {
        let deployment: [ContractUpdate] = []
        for contractConfig in deploymentConfig {
            // Claim the AuthAccount Capability for this contract account
            assert(contractConfig.length == 1, message: "Invalid contract config")
            let address = contractConfig.keys[0]
            assert(contractConfig[address]!.length == 1, message: "Invalid contract config")
            // Build the deployment
            let nameAndCode = contractConfig[address]!
            deployment.append(
                ContractUpdater.ContractUpdate(
                    address: address,
                    name: nameAndCode.keys[0],
                    code: nameAndCode.values[0].decodeHex()
                )
            )
        }
        return deployment
    }

    /// Returns a new Updater resource
    ///
    pub fun createNewUpdater(
        blockUpdateBoundary: UInt64,
        accounts: [Capability<&AuthAccount>],
        deployment: [ContractUpdate]
    ): @Updater {
        let updater <- create Updater(blockUpdateBoundary: blockUpdateBoundary, accounts: accounts, deployment: deployment)
        emit UpdaterCreated(updaterUUID: updater.uuid, blockUpdateBoundary: blockUpdateBoundary)
        return <- updater
    }

    init() {
        self.inboxAccountCapabilityNamePrefix = "ContractUpdaterAccountCapability_"

        self.UpdaterStoragePath = StoragePath(identifier: "ContractUpdater_".concat(self.account.address.toString()))!
        self.DelegatedUpdaterPrivatePath = PrivatePath(identifier: "ContractUpdaterDelegated_".concat(self.account.address.toString()))!
        self.UpdaterPublicPath = PublicPath(identifier: "ContractUpdaterPublic_".concat(self.account.address.toString()))!
        self.UpdaterContractAccountPrivatePath = PrivatePath(identifier: "UpdaterContractAccount_".concat(self.account.address.toString()))!
        self.DelegateeStoragePath = StoragePath(identifier: "ContractUpdaterDelegatee_".concat(self.account.address.toString()))!
        self.DelegateePrivatePath = PrivatePath(identifier: "ContractUpdaterDelegatee_".concat(self.account.address.toString()))!
        self.DelegateePublicPath = PublicPath(identifier: "ContractUpdaterDelegateePublic_".concat(self.account.address.toString()))!

        self.account.save(<-create Delegatee(), to: self.DelegateeStoragePath)
        self.account.link<&Delegatee{DelegateePublic}>(self.DelegateePublicPath, target: self.DelegateeStoragePath)
    }
}