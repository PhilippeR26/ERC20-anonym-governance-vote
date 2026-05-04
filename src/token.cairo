// SPDX-License-Identifier: MIT
#[starknet::interface]
pub trait IGovToken<TState> {
    fn mint(ref self: TState, recipient: starknet::ContractAddress, amount: u256);
    fn upgrade(ref self: TState, new_class_hash: starknet::ClassHash);
}

#[starknet::contract]
pub mod GovToken {
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::governance::votes::VotesComponent;
    use openzeppelin::token::erc20::{DefaultConfig, ERC20Component};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::utils::contract_clock::ERC6372BlockNumberClock;
    use openzeppelin::utils::cryptography::snip12::SNIP12Metadata;
    use openzeppelin::utils::nonces::NoncesComponent;
    use starknet::{ClassHash, ContractAddress};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);
    component!(path: VotesComponent, storage: votes, event: VotesEvent);
    component!(path: NoncesComponent, storage: nonces, event: NoncesEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Ownable
    #[abi(embed_v0)]
    impl OwnableMixinImpl = OwnableComponent::OwnableMixinImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ERC20
    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    // Votes (block number clock)
    #[abi(embed_v0)]
    impl VotesImpl = VotesComponent::VotesImpl<ContractState>;
    impl VotesInternalImpl = VotesComponent::InternalImpl<ContractState>;

    // Nonces
    #[abi(embed_v0)]
    impl NoncesImpl = NoncesComponent::NoncesImpl<ContractState>;

    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    pub struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        #[substorage(v0)]
        votes: VotesComponent::Storage,
        #[substorage(v0)]
        nonces: NoncesComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ERC20Event: ERC20Component::Event,
        #[flat]
        VotesEvent: VotesComponent::Event,
        #[flat]
        NoncesEvent: NoncesComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
    }

    pub impl SNIP12MetadataImpl of SNIP12Metadata {
        fn name() -> felt252 {
            'GovToken'
        }
        fn version() -> felt252 {
            '1'
        }
    }

    // Hook: synchronise les checkpoints Votes à chaque transfert ERC20.
    impl ERC20VotesHooksImpl of ERC20Component::ERC20HooksTrait<ContractState> {
        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) {
            let mut contract_state = self.get_contract_mut();
            contract_state.votes.transfer_voting_units(from, recipient, amount);
        }
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        name: ByteArray,
        symbol: ByteArray,
        initial_supply: u256,
        recipient: ContractAddress,
        owner: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self.erc20.initializer(name, symbol);
        self.erc20.mint(recipient, initial_supply);
    }

    #[abi(embed_v0)]
    impl GovTokenImpl of super::IGovToken<ContractState> {
        fn mint(ref self: ContractState, recipient: ContractAddress, amount: u256) {
            self.ownable.assert_only_owner();
            self.erc20.mint(recipient, amount);
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }
    }
}
