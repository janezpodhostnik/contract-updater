/// This contract is intended for use in the Cadence 1.0 contract migration across the Flow network.
///
/// In preparation for this milestone, your contract will NEED to be updated! Once you've updated your code for
/// Cadence 1.0, you MUST stage your contract code in this contract so that the update can be executed as a part of the
/// network-wide state migration.
///
/// To stage your contract update:
/// 1. create a Host & save in your contract-hosting account
/// 2. call stageContract() passing a reference to you Host, the contract name, and the updated Cadence code
///
/// This can be done in a single transaction! For more code context, see https://github.com/onflow/contract-updater
///
access(all) contract MigrationContractStaging {

    // Path constants
    //
    access(self) let delimiter: String
    access(self) let capsulePathPrefix: String
    access(all) let HostStoragePath: StoragePath
    access(all) let AdminStoragePath: StoragePath
    /// Maps contract addresses to an array of staged contract names
    access(self) let stagedContracts: {Address: [String]}
    /// The block height at which updates can no no longer be staged. If nil, updates can be staged indefinitely until
    /// the cutoff value is set.
    access(self) var stagingCutoff: UInt64?

    /// Event emitted when a contract's code is staged
    /// `action` ∈ {"stage", "replace", "unstage"} each denoting the action being taken on the staged contract
    /// NOTE: Does not guarantee that the contract code is valid Cadence
    access(all) event StagingStatusUpdated(
        capsuleUUID: UInt64,
        address: Address,
        codeHash: [UInt8],
        contract: String,
        action: String
    )
    /// Emitted when the stagingCutoff value is updated
    access(all) event StagingCutoffUpdated(old: UInt64?, new: UInt64?)

    /********************
        Public Methods
     ********************/

    /* --- Staging Methods --- */

    /// 1 - Create a host and save it in your contract-hosting account at MigrationContractStaging.HostStoragePath
    ///
    /// Creates a Host serving as identification for the contract account. Reference to this resource identifies the
    /// calling address so it must be saved in account storage before being used to stage a contract update.
    ///
    access(all) fun createHost(): @Host {
        return <- create Host()
    }

    /// 2 - Call stageContract() with the host reference and contract name and contract code you wish to stage
    ///
    /// Stages the contract code for the given contract name at the host address. If the contract is already staged,
    /// the code will be replaced.
    ///
    access(all) fun stageContract(host: &Host, name: String, code: String) {
        pre {
            self.isActiveStagingPeriod(): "Staging period has ended"
        }
        let capsulePath = self.deriveCapsuleStoragePath(contractAddress: host.address(), contractName: name)
        if self.stagedContracts[host.address()] == nil {
            // First time we're seeing contracts from this address - insert the address and contract name
            self.stagedContracts.insert(key: host.address(), [name])
            // Create a new Capsule to store the staged code
            let capsule <- self.createCapsule(host: host, name: name, code: code)
            self.account.save(<-capsule, to: capsulePath)
            return
        }
        // We've seen contracts from this host address before - check if the contract is already staged
        if let contractIndex = self.stagedContracts[host.address()]!.firstIndex(of: name) {
            // The contract is already staged - replace the code
            let capsule: &Capsule = self.account.borrow<&Capsule>(from: capsulePath)
                ?? panic("Could not borrow existing Capsule from storage for staged contract")
            capsule.replaceCode(code: code)
            return
        }
        // First time staging this contract - add the contract name to the list of contracts staged for host
        self.stagedContracts[host.address()]!.append(name)
        self.account.save(<-self.createCapsule(host: host, name: name, code: code), to: capsulePath)
    }

    /// Removes the staged contract code from the staging environment.
    ///
    access(all) fun unstageContract(host: &Host, name: String) {
        pre {
            self.isActiveStagingPeriod(): "Staging period has ended"
        }
        post {
            !self.isStaged(address: host.address(), name: name): "Contract is still staged"
        }
        let address: Address = host.address()
        if self.stagedContracts[address] == nil {
            return
        }
        let capsuleUUID: UInt64 = self.removeStagedContract(address: address, name: name)
            ?? panic("Problem destroying update Capsule")
        emit StagingStatusUpdated(
            capsuleUUID: capsuleUUID,
            address: address,
            codeHash: [],
            contract: name,
            action: "unstage"
        )
    }

    /* --- Public Getters --- */

    /// Returns the last block height at which updates can be staged
    ///
    access(all) fun getStagingCutoff(): UInt64? {
        return self.stagingCutoff
    }

    /// Returns whether the staging period is currently active
    ///
    access(all) fun isActiveStagingPeriod(): Bool {
        return self.stagingCutoff == nil || getCurrentBlock().height <= self.stagingCutoff!
    }

    /// Returns true if the contract is currently staged.
    ///
    access(all) view fun isStaged(address: Address, name: String): Bool {
        return self.stagedContracts[address]?.contains(name) ?? false
    }

    /// Returns the names of all staged contracts for the given address.
    ///
    access(all) view fun getStagedContractNames(forAddress: Address): [String] {
        return self.stagedContracts[forAddress] ?? []
    }

    /// Returns the staged contract Cadence code for the given address and name.
    ///
    access(all) fun getStagedContractCode(address: Address, name: String): String? {
        let capsulePath: StoragePath = self.deriveCapsuleStoragePath(contractAddress: address, contractName: name)
        if let capsule = self.account.borrow<&Capsule>(from: capsulePath) {
            return capsule.getContractUpdate().codeAsCadence()
        } else {
            return nil
        }
    }

    /// Returns an array of all staged contract host addresses.
    ///
    access(all) view fun getAllStagedContractHosts(): [Address] {
        return self.stagedContracts.keys
    }

    /// Returns a dictionary of all staged contract code for the given address.
    ///
    access(all) view fun getAllStagedContractCode(forAddress: Address): {String: String} {
        if self.stagedContracts[forAddress] == nil {
            return {}
        }
        let capsulePaths: [StoragePath] = []
        let stagedCode: {String: String} = {}
        let contractNames: [String] = self.stagedContracts[forAddress]!
        for name in contractNames {
            capsulePaths.append(self.deriveCapsuleStoragePath(contractAddress: forAddress, contractName: name))
        }
        for path in capsulePaths {
            if let capsule = self.account.borrow<&Capsule>(from: path) {
                let update: ContractUpdate = capsule.getContractUpdate()
                stagedCode[update.name] = update.codeAsCadence()
            }
        }
        return stagedCode
    }

    /// Returns a StoragePath to store the Capsule of the form:
    ///     /storage/self.capsulePathPrefix_ADDRESS_NAME
    access(all) view fun deriveCapsuleStoragePath(contractAddress: Address, contractName: String): StoragePath {
        let identifier = self.capsulePathPrefix
            .concat(self.delimiter)
            .concat(contractAddress.toString())
            .concat(self.delimiter)
            .concat(contractName)
        return StoragePath(identifier: identifier)
            ?? panic("Could not derive Capsule StoragePath for given address")
    }

    /* ------------------------------------------------------------------------------------------------------------ */
    /* ------------------------------------------------ Constructs ------------------------------------------------ */
    /* ------------------------------------------------------------------------------------------------------------ */

    /********************
        ContractUpdate
     ********************/

    /// Represents contract and its corresponding code.
    ///
    access(all) struct ContractUpdate {
        access(all) let address: Address
        access(all) let name: String
        access(all) var code: String

        init(address: Address, name: String, code: String) {
            self.address = address
            self.name = name
            self.code = code
        }

        /// Validates that the named contract exists at the target address.
        ///
        access(all) view fun isValid(): Bool {
            return getAccount(self.address).contracts.names.contains(self.name)
        }

        /// Serializes the address and name into a string of the form 0xADDRESS.NAME
        ///
        access(all) view fun toString(): String {
            return self.address.toString().concat(".").concat(self.name)
        }

        /// Returns human-readable string of the Cadence code.
        ///
        access(all) view fun codeAsCadence(): String {
            return String.fromUTF8(self.code.decodeHex()) ?? panic("Problem stringifying code!")
        }

        /// Replaces the ContractUpdate code with that provided.
        ///
        access(contract) fun replaceCode(_ code: String) {
            self.code = code
        }
    }

    /********************
            Host
     ********************/

    /// Serves as identification for a caller's address.
    /// NOTE: Should be saved in storage and access safeguarded as reference grants access to contract staging. If a
    /// contract host wishes to delegate staging to another account (e.g. multisig account setup enabling a developer
    /// to stage on its behalf), it should create a PRIVATE Host capability and publish it to the receiving account.
    ///
    access(all) resource Host {
        /// Returns the resource owner's address
        ///
        access(all) view fun address(): Address {
            return self.owner?.address ?? panic("Host is unowned!")
        }
    }

    /********************
            Capsule
     ********************/

    /// Resource that stores pending contract updates in a ContractUpdate struct. On staging a contract update for the
    /// first time, a Capsule will be created and stored in this contract account. Any time a stageContract() call is
    /// made again for the same contract, the code in the Capsule will be replaced. As you see, the Capsule is merely
    /// intended to store the code, as contract updates will be executed by state migration across the network at the
    /// Cadence 1.0 milestone.
    ///
    access(all) resource Capsule {
        /// The address, name and code of the contract that will be updated.
        access(self) let update: ContractUpdate

        init(update: ContractUpdate) {
            pre {
                update.codeAsCadence() != nil: "Staged update code must be valid Cadence"
                update.isValid(): "Target contract does not exist"
            }
            self.update = update
        }

        /// Returns the staged contract update in the form of a ContractUpdate struct.
        ///
        access(all) view fun getContractUpdate(): ContractUpdate {
            return self.update
        }

        /// Replaces the staged contract code with the given updated Cadence code.
        ///
        access(contract) fun replaceCode(code: String) {
            post {
                self.update.codeAsCadence() != nil: "Staged update code must be valid Cadence"
            }
            self.update.replaceCode(code)
            emit StagingStatusUpdated(
                capsuleUUID: self.uuid,
                address: self.update.address,
                codeHash: code.decodeHex(),
                contract: self.update.name,
                action: "replace"
            )
        }
    }

    /********************
            Admin
     ********************/

    /// Admin resource for updating the stagingCutoff value
    ///
    access(all) resource Admin {

        /// Sets the block height at which updates can no longer be staged
        ///
        access(all) fun setStagingCutoff(at height: UInt64?) {
            pre {
                height == nil || height! > getCurrentBlock().height:
                    "Height must be nil or greater than current block height"
            }
            emit StagingCutoffUpdated(old: MigrationContractStaging.stagingCutoff, new: height)
            MigrationContractStaging.stagingCutoff = height
        }
    }

    /*********************
        Internal Methods
     *********************/

    /// Creates a Capsule resource with the given Host and ContractUpdate. Will be stored at the derived path in this
    /// contract's account storage.
    ///
    access(self) fun createCapsule(host: &Host, name: String, code: String): @Capsule {
        let update = ContractUpdate(address: host.address(), name: name, code: code)
        let capsule <- create Capsule(update: update)
        emit StagingStatusUpdated(
            capsuleUUID: capsule.uuid,
            address: host.address(),
            codeHash: code.decodeHex(),
            contract: name,
            action: "stage"
        )
        return <- capsule
    }

    /// Removes the staged update's Capsule from storage and returns the UUID of the removed Capsule or nil if it
    /// wasn't found. Also removes the contract name from the stagedContracts mapping.
    ///
    access(self) fun removeStagedContract(address: Address, name: String): UInt64? {
        let contractIndex: Int = self.stagedContracts[address]!.firstIndex(of: name)!
        self.stagedContracts[address]!.remove(at: contractIndex)
        // Remove the Address from the stagedContracts mapping if it has no staged contracts remain for the host address
        if self.stagedContracts[address]!.length == 0 {
            self.stagedContracts.remove(key: address)
        }
        return self.destroyCapsule(address: address, name: name)
    }

    /// Destroys the Capsule resource at the derived path in this contract's account storage and returns the UUID of
    /// the destroyed Capsule if it existed.
    ///
    access(self) fun destroyCapsule(address: Address, name: String): UInt64? {
        let capsulePath: StoragePath = self.deriveCapsuleStoragePath(contractAddress: address, contractName: name)
        if let capsule <- self.account.load<@Capsule>(from: capsulePath) {
            let capsuleUUID = capsule.uuid
            destroy capsule
            return capsuleUUID
        }
        return nil
    }

    init() {
        self.delimiter = "_"
        self.HostStoragePath = StoragePath(
                identifier: "MigrationContractStagingHost".concat(self.delimiter).concat(self.account.address.toString())
            ) ?? panic("Could not derive Host StoragePath")
        self.AdminStoragePath = /storage/MigrationContractStagingAdmin
        self.capsulePathPrefix = "MigrationContractStagingCapsule"
            .concat(self.delimiter)
            .concat(self.account.address.toString())
        self.stagedContracts = {}
        self.stagingCutoff = nil

        self.account.save(<-create Admin(), to: self.AdminStoragePath)
    }
}
