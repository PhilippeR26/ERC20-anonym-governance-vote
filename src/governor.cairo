// SPDX-License-Identifier: MIT
#[starknet::interface]
pub trait IAnonGovernor<TState> {
    fn upgrade(ref self: TState, new_class_hash: starknet::ClassHash);
    fn quorum_reached(self: @TState, proposal_id: felt252) -> bool;
    fn vote_succeeded(self: @TState, proposal_id: felt252) -> bool;
}

#[starknet::contract]
pub mod AnonGovernor {
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::governance::governor::extensions::{
        GovernorCoreExecutionComponent, GovernorCountingAnonymousComponent,
        GovernorSettingsComponent, GovernorVotesComponent,
    };
    use openzeppelin::governance::governor::{DefaultConfig, GovernorComponent};
    use openzeppelin::governance::governor::GovernorComponent::GovernorCountingTrait;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::utils::cryptography::snip12::SNIP12Metadata;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ClassHash, ContractAddress};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: GovernorComponent, storage: governor, event: GovernorEvent);
    component!(
        path: GovernorCountingAnonymousComponent,
        storage: governor_counting_anonymous,
        event: GovernorCountingAnonymousEvent,
    );
    component!(path: GovernorVotesComponent, storage: governor_votes, event: GovernorVotesEvent);
    component!(
        path: GovernorSettingsComponent,
        storage: governor_settings,
        event: GovernorSettingsEvent,
    );
    component!(
        path: GovernorCoreExecutionComponent,
        storage: governor_core_execution,
        event: GovernorCoreExecutionEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Ownable
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // SRC5
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    // Governor — interface principale
    #[abi(embed_v0)]
    impl GovernorImpl = GovernorComponent::GovernorImpl<ContractState>;
    impl GovernorInternalImpl = GovernorComponent::InternalImpl<ContractState>;

    // Vote anonyme — interface externe (create_proof, cast_anonymous_vote, is_nullifier_used)
    #[abi(embed_v0)]
    impl GovernorCountingAnonymousImpl =
        GovernorCountingAnonymousComponent::GovernorCountingAnonymousImpl<ContractState>;

    // GovernorCountingTrait requis par GovernorComponent
    impl GovernorCountingImpl = GovernorCountingAnonymousComponent::GovernorCounting<ContractState>;

    // Token de votes — expose token()
    #[abi(embed_v0)]
    impl VotesTokenImpl = GovernorVotesComponent::VotesTokenImpl<ContractState>;

    // GovernorVotesTrait requis par GovernorComponent
    impl GovernorVotesImpl = GovernorVotesComponent::GovernorVotes<ContractState>;
    impl GovernorVotesInternalImpl = GovernorVotesComponent::InternalImpl<ContractState>;

    // Settings externes (set_voting_delay, set_voting_period, set_proposal_threshold)
    #[abi(embed_v0)]
    impl GovernorSettingsAdminImpl =
        GovernorSettingsComponent::GovernorSettingsAdminImpl<ContractState>;

    // GovernorSettingsTrait requis par GovernorComponent
    impl GovernorSettingsImpl = GovernorSettingsComponent::GovernorSettings<ContractState>;
    impl GovernorSettingsInternalImpl = GovernorSettingsComponent::InternalImpl<ContractState>;

    // GovernorExecutionTrait requis par GovernorComponent
    impl GovernorExecutionImpl = GovernorCoreExecutionComponent::GovernorExecution<ContractState>;

    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        governor: GovernorComponent::Storage,
        #[substorage(v0)]
        governor_counting_anonymous: GovernorCountingAnonymousComponent::Storage,
        #[substorage(v0)]
        governor_votes: GovernorVotesComponent::Storage,
        #[substorage(v0)]
        governor_settings: GovernorSettingsComponent::Storage,
        #[substorage(v0)]
        governor_core_execution: GovernorCoreExecutionComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        // Quorum stocké séparément (non géré par GovernorSettings)
        Governor_quorum: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        GovernorEvent: GovernorComponent::Event,
        #[flat]
        GovernorCountingAnonymousEvent: GovernorCountingAnonymousComponent::Event,
        #[flat]
        GovernorSettingsEvent: GovernorSettingsComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        GovernorVotesEvent: GovernorVotesComponent::Event,
        #[flat]
        GovernorCoreExecutionEvent: GovernorCoreExecutionComponent::Event,
    }

    pub impl SNIP12MetadataImpl of SNIP12Metadata {
        fn name() -> felt252 {
            'AnonGovernor'
        }
        fn version() -> felt252 {
            '1'
        }
    }

    // Quorum lu depuis le storage custom
    impl GovernorQuorum of GovernorComponent::GovernorQuorumTrait<ContractState> {
        fn quorum(
            self: @GovernorComponent::ComponentState<ContractState>, timepoint: u64,
        ) -> u256 {
            let contract = self.get_contract();
            contract.Governor_quorum.read()
        }
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        votes_token: ContractAddress,
        owner: ContractAddress,
        voting_delay: u64,
        voting_period: u64,
        proposal_threshold: u256,
        quorum: u256,
    ) {
        self.ownable.initializer(owner);
        self.governor.initializer();
        self.governor_votes.initializer(votes_token);
        self.governor_settings.initializer(voting_delay, voting_period, proposal_threshold);
        self.Governor_quorum.write(quorum);
    }

    #[abi(embed_v0)]
    impl AnonGovernorImpl of super::IAnonGovernor<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }

        fn quorum_reached(self: @ContractState, proposal_id: felt252) -> bool {
            self.governor.quorum_reached(proposal_id)
        }

        fn vote_succeeded(self: @ContractState, proposal_id: felt252) -> bool {
            self.governor.vote_succeeded(proposal_id)
        }
    }
}
