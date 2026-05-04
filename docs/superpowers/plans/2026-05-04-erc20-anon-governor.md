# ERC20 + Anonymous Governance Governor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Créer un projet Scarb Cairo 2.18.0 contenant un token ERC20Votes et un Governor avec vote anonyme SNIP-36, testés avec snforge_std 0.60.0.

**Architecture:** Deux contrats dans un package unique. `GovToken` (ERC20 + Votes + Ownable + Upgradeable) sert de source de voting power. `AnonGovernor` (Governor + GovernorVotes + GovernorCountingAnonymous + GovernorSettings + GovernorCoreExecution + SRC5 + Ownable + Upgradeable) gère les proposals et le vote anonyme. Les tests d'intégration snforge simulent les `proof_facts` SNIP-36 via `start_cheat_proof_facts`.

**Tech Stack:** Cairo 2.18.0, Scarb 2.18.0, snforge_std 0.60.0, openzeppelin fork `anonym-vote` branch.

---

## File Map

| Fichier | Rôle |
|---|---|
| `Scarb.toml` | Configuration package, dépendances git OZ fork |
| `src/lib.cairo` | Déclaration des modules token et governor |
| `src/token.cairo` | Contrat GovToken (ERC20Votes mintable upgradeable) |
| `src/governor.cairo` | Contrat AnonGovernor (Governor + vote anonyme) |
| `tests/test_governor.cairo` | Tests d'intégration snforge |

---

## Task 1: Scaffold — Scarb.toml + src/lib.cairo

**Files:**
- Create: `Scarb.toml`
- Create: `src/lib.cairo`

- [ ] **Step 1: Créer Scarb.toml**

```toml
[package]
name = "erc20_anon_gov"
version = "0.1.0"
edition = "2024_07"
cairo-version = "2.18.0"
scarb-version = "2.18.0"

[dependencies]
starknet = "2.18.0"
openzeppelin = { git = "https://github.com/PhilippeR26/OZ-contracts", branch = "anonym-vote" }

[dev-dependencies]
snforge_std = "0.60.0"

[lib]

[[target.starknet-contract]]
allowed-libfuncs-list.name = "experimental"
sierra = true
casm = false

[[test]]
name = "erc20_anon_gov_tests"
```

- [ ] **Step 2: Créer src/lib.cairo**

```cairo
pub mod token;
pub mod governor;
```

- [ ] **Step 3: Vérifier que scarb fetch ne plante pas**

```bash
cd /D/Starknet/ERC20-anonym-governance-vote
scarb fetch
```

Expected: résolution des dépendances OZ depuis le fork git, pas d'erreur.

- [ ] **Step 4: Commit**

```bash
git add Scarb.toml src/lib.cairo
git commit -m "feat: scaffold Scarb project with OZ anonym-vote dependency"
```

---

## Task 2: Token contract — src/token.cairo

**Files:**
- Create: `src/token.cairo`

- [ ] **Step 1: Créer src/token.cairo**

```cairo
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
    impl VotesImpl = VotesComponent::VotesImpl<ContractState, ERC6372BlockNumberClock>;
    impl VotesInternalImpl = VotesComponent::InternalImpl<ContractState, ERC6372BlockNumberClock>;

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
```

- [ ] **Step 2: Vérifier la compilation**

```bash
scarb build
```

Expected: `Compiling erc20_anon_gov ...` puis `Finished`. Corriger toute erreur de compilation avant de continuer.

- [ ] **Step 3: Commit**

```bash
git add src/token.cairo
git commit -m "feat: add GovToken ERC20Votes mintable upgradeable contract"
```

---

## Task 3: Governor contract — src/governor.cairo

**Files:**
- Create: `src/governor.cairo`

- [ ] **Step 1: Créer src/governor.cairo**

```cairo
// SPDX-License-Identifier: MIT
#[starknet::interface]
pub trait IAnonGovernor<TState> {
    fn upgrade(ref self: TState, new_class_hash: starknet::ClassHash);
}

#[starknet::contract]
pub mod AnonGovernor {
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::governance::governor::extensions::{
        GovernorCoreExecutionComponent, GovernorCountingAnonymousComponent,
        GovernorSettingsComponent, GovernorVotesComponent,
    };
    use openzeppelin::governance::governor::{DefaultConfig, GovernorComponent};
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

    // Settings externes (voting_delay, voting_period, proposal_threshold)
    #[abi(embed_v0)]
    impl GovernorSettingsExternalImpl =
        GovernorSettingsComponent::GovernorSettingsImpl<ContractState>;

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
        pub Governor_quorum: u256,
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
            self: @GovernorComponent::ComponentState<ContractState>, _timepoint: u64,
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
    }
}
```

- [ ] **Step 2: Vérifier la compilation**

```bash
scarb build
```

Expected: `Finished` sans erreur. Si erreur de trait non satisfait ou impl manquant, vérifier les noms des impls dans le fork OZ local (`/D/Starknet/OZ-contracts/packages/governance/src/governor/extensions/`).

- [ ] **Step 3: Commit**

```bash
git add src/governor.cairo
git commit -m "feat: add AnonGovernor with GovernorCountingAnonymous and GovernorSettings"
```

---

## Task 4: Test foundation — setup + helpers SNIP-36

**Files:**
- Create: `tests/test_governor.cairo`

- [ ] **Step 1: Créer tests/test_governor.cairo avec infrastructure de base**

```cairo
use core::poseidon::poseidon_hash_span;
use openzeppelin::governance::governor::extensions::GovernorCountingAnonymousComponent::AnonVoteMessage;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare,
    start_cheat_block_number_global, stop_cheat_block_number_global,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_proof_facts, stop_cheat_proof_facts,
};
use starknet::{ContractAddress, contract_address_const};
use erc20_anon_gov::governor::AnonGovernor;
use erc20_anon_gov::token::GovToken;

// ── Constantes de test ────────────────────────────────────────────────────────

fn OWNER() -> ContractAddress { contract_address_const::<0x1>() }
fn VOTER() -> ContractAddress { contract_address_const::<0x2>() }

const INITIAL_SUPPLY: u256 = 1_000_000_000_000_000_000_000_000; // 1_000_000 * 1e18
const VOTING_DELAY: u64 = 1;
const VOTING_PERIOD: u64 = 50;
const PROPOSAL_THRESHOLD: u256 = 1_000_000_000_000_000_000; // 1 * 1e18
const QUORUM: u256 = 100_000_000_000_000_000_000_000; // 100_000 * 1e18

const NULLIFIER_DOMAIN: felt252 = 'anon_governor_nullifier_v1';

// ── Interfaces dispatchers ────────────────────────────────────────────────────

use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin::governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin::governance::governor::interface::{IGovernorDispatcher, IGovernorDispatcherTrait};
use openzeppelin::governance::governor::extensions::governor_counting_anonymous::{
    IGovernorCountingAnonymousDispatcher, IGovernorCountingAnonymousDispatcherTrait,
};
use erc20_anon_gov::token::{IGovTokenDispatcher, IGovTokenDispatcherTrait};
use erc20_anon_gov::governor::{IAnonGovernorDispatcher, IAnonGovernorDispatcherTrait};

// ── Setup ─────────────────────────────────────────────────────────────────────

struct Deployment {
    token_addr: ContractAddress,
    gov_addr: ContractAddress,
    token: IERC20Dispatcher,
    votes: IVotesDispatcher,
    governor: IGovernorDispatcher,
    anon_governor: IGovernorCountingAnonymousDispatcher,
}

fn setup() -> Deployment {
    // Déployer le token
    let token_class = declare("GovToken").unwrap().contract_class();
    let mut token_calldata: Array<felt252> = array![];
    let name: ByteArray = "GovToken";
    let symbol: ByteArray = "GT";
    name.serialize(ref token_calldata);
    symbol.serialize(ref token_calldata);
    INITIAL_SUPPLY.serialize(ref token_calldata);
    OWNER().serialize(ref token_calldata); // recipient
    OWNER().serialize(ref token_calldata); // owner
    let (token_addr, _) = token_class.deploy(@token_calldata).unwrap();

    // Déployer le governor
    let gov_class = declare("AnonGovernor").unwrap().contract_class();
    let mut gov_calldata: Array<felt252> = array![];
    token_addr.serialize(ref gov_calldata);
    OWNER().serialize(ref gov_calldata);
    VOTING_DELAY.serialize(ref gov_calldata);
    VOTING_PERIOD.serialize(ref gov_calldata);
    PROPOSAL_THRESHOLD.serialize(ref gov_calldata);
    QUORUM.serialize(ref gov_calldata);
    let (gov_addr, _) = gov_class.deploy(@gov_calldata).unwrap();

    // OWNER délègue ses votes à VOTER
    start_cheat_caller_address(token_addr, OWNER());
    IVotesDispatcher { contract_address: token_addr }.delegate(VOTER());
    stop_cheat_caller_address(token_addr);

    Deployment {
        token_addr,
        gov_addr,
        token: IERC20Dispatcher { contract_address: token_addr },
        votes: IVotesDispatcher { contract_address: token_addr },
        governor: IGovernorDispatcher { contract_address: gov_addr },
        anon_governor: IGovernorCountingAnonymousDispatcher { contract_address: gov_addr },
    }
}

// ── Helpers SNIP-36 ────────────────────────────────────────────────────────────

/// Recalcule le nullifier tel que _compute_nullifier dans le contrat.
fn compute_nullifier(proposal_id: felt252, signature: Span<felt252>) -> felt252 {
    let sig_hash = poseidon_hash_span(signature);
    poseidon_hash_span(array![NULLIFIER_DOMAIN, proposal_id, sig_hash].span())
}

/// Recalcule le hash du message tel que _compute_proof_message_hash dans le contrat.
fn compute_message_hash(governor_addr: ContractAddress, msg: @AnonVoteMessage) -> felt252 {
    let mut payload: Array<felt252> = array![];
    (*msg).serialize(ref payload);
    let mut data: Array<felt252> = array![
        governor_addr.into(),
        0_felt252, // L1 destination = 0x00
        payload.len().into(),
    ];
    for f in payload.span() {
        data.append(*f);
    };
    poseidon_hash_span(data.span())
}

/// Sérialise un ProofFacts synthétique contenant un seul message hash.
/// Layout ProofFacts (Serde) :
///   PROOF0_marker(bytes31=felt252), VIRTUAL_SNOS_marker, virtual_OS_program_hash,
///   VIRTUAL_SNOS0_marker, block_number, block_hash, OS_config_hash,
///   l1l2messages.len(), l1l2messages[0]
fn build_proof_facts(message_hash: felt252) -> Array<felt252> {
    array![
        0, // PROOF0_marker
        0, // VIRTUAL_SNOS_marker
        0, // virtual_OS_program_hash
        0, // VIRTUAL_SNOS0_marker
        0, // block_number
        0, // block_hash
        0, // OS_config_hash
        1, // l1l2messages.len()
        message_hash,
    ]
}

/// Crée une proposal vide (no-op) et retourne son proposal_id.
/// Advance le block pour dépasser le voting_delay.
fn create_active_proposal(d: @Deployment) -> felt252 {
    // Avancer un bloc pour que la délégation soit enregistrée (checkpoint)
    start_cheat_block_number_global(2);

    start_cheat_caller_address(*d.gov_addr, VOTER());
    let proposal_id = d
        .governor
        .propose(array![].span(), "Test proposal");
    stop_cheat_caller_address(*d.gov_addr);

    // Avancer pour dépasser le voting_delay (1 bloc)
    start_cheat_block_number_global(4);
    proposal_id
}
```

- [ ] **Step 2: Vérifier que snforge compile le fichier**

```bash
snforge test --list
```

Expected: liste les tests sans erreur de compilation. Si erreur de dispatcher non trouvé, vérifier les chemins d'import des interfaces dans le fork OZ.

- [ ] **Step 3: Commit**

```bash
git add tests/test_governor.cairo
git commit -m "test: add test foundation, setup helpers, and SNIP-36 simulation utilities"
```

---

## Task 5: Tests d'état de base

**Files:**
- Modify: `tests/test_governor.cairo`

- [ ] **Step 1: Ajouter les tests d'état (append à la fin du fichier)**

```cairo
// ── Tests counting_mode ───────────────────────────────────────────────────────

#[test]
fn test_counting_mode() {
    let d = setup();
    // counting_mode est exposé via GovernorImpl
    let mode = d.governor.counting_mode();
    assert_eq!(mode, "support=bravo&quorum=for,abstain&params=snip36-anon");
}

// ── Tests is_nullifier_used ───────────────────────────────────────────────────

#[test]
fn test_is_nullifier_used_false_by_default() {
    let d = setup();
    let result = d.anon_governor.is_nullifier_used(0_felt252, 0xdeadbeef_felt252);
    assert_eq!(result, false);
}

// ── Tests quorum_reached via vote_tally ───────────────────────────────────────

#[test]
fn test_quorum_not_reached_with_empty_votes() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);
    // Aucun vote : quorum non atteint
    assert_eq!(d.governor.quorum_reached(proposal_id), false);
}

// ── Tests vote_succeeded ──────────────────────────────────────────────────────

#[test]
fn test_vote_not_succeeded_with_no_votes() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);
    assert_eq!(d.governor.vote_succeeded(proposal_id), false);
}
```

- [ ] **Step 2: Lancer les tests**

```bash
snforge test test_counting_mode test_is_nullifier_used_false_by_default test_quorum_not_reached_with_empty_votes test_vote_not_succeeded_with_no_votes
```

Expected: 4 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/test_governor.cairo
git commit -m "test: add counting_mode, is_nullifier_used, quorum, and vote_succeeded base tests"
```

---

## Task 6: Tests vote anonyme — flux complet

**Files:**
- Modify: `tests/test_governor.cairo`

- [ ] **Step 1: Ajouter test_cast_anonymous_vote_ok**

```cairo
// ── Tests cast_anonymous_vote ─────────────────────────────────────────────────

#[test]
fn test_cast_anonymous_vote_ok() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let weight = INITIAL_SUPPLY; // VOTER a tout le supply délégué

    let msg = AnonVoteMessage {
        proposal_id,
        nullifier,
        support: 1, // For
        weight,
    };

    let message_hash = compute_message_hash(d.gov_addr, @msg);
    let proof_facts = build_proof_facts(message_hash);
    start_cheat_proof_facts(d.gov_addr, proof_facts.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
    stop_cheat_caller_address(d.gov_addr);

    stop_cheat_proof_facts(d.gov_addr);

    // Le nullifier est maintenant consommé
    assert_eq!(d.anon_governor.is_nullifier_used(proposal_id, nullifier), true);
    // Le quorum est atteint (INITIAL_SUPPLY >> QUORUM)
    assert_eq!(d.governor.quorum_reached(proposal_id), true);
    // Le vote est un succès (for > against)
    assert_eq!(d.governor.vote_succeeded(proposal_id), true);
}
```

- [ ] **Step 2: Lancer le test**

```bash
snforge test test_cast_anonymous_vote_ok
```

Expected: PASS.

- [ ] **Step 3: Ajouter test replay de nullifier**

```cairo
#[test]
#[should_panic(expected: 'Nullifier already used')]
fn test_cast_anonymous_vote_nullifier_replay() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let weight = INITIAL_SUPPLY;

    let msg = AnonVoteMessage { proposal_id, nullifier, support: 1, weight };

    let message_hash = compute_message_hash(d.gov_addr, @msg);
    let proof_facts = build_proof_facts(message_hash);

    // Premier vote
    start_cheat_proof_facts(d.gov_addr, proof_facts.span());
    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);

    // Deuxième vote avec le même nullifier → doit paniquer
    let msg2 = AnonVoteMessage { proposal_id, nullifier, support: 1, weight };
    d.anon_governor.cast_anonymous_vote(msg2);
    stop_cheat_caller_address(d.gov_addr);
    stop_cheat_proof_facts(d.gov_addr);
}
```

- [ ] **Step 4: Lancer le test**

```bash
snforge test test_cast_anonymous_vote_nullifier_replay
```

Expected: PASS.

- [ ] **Step 5: Ajouter tests proof invalides**

```cairo
#[test]
#[should_panic(expected: 'Proof message mismatch')]
fn test_cast_anonymous_vote_invalid_proof() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let msg = AnonVoteMessage {
        proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY,
    };

    // proof_facts avec un hash incorrect
    let wrong_proof = build_proof_facts(0xdeadbeef_felt252);
    start_cheat_proof_facts(d.gov_addr, wrong_proof.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
    stop_cheat_caller_address(d.gov_addr);
    stop_cheat_proof_facts(d.gov_addr);
}

#[test]
#[should_panic(expected: 'Expected 1 proof msg')]
fn test_cast_anonymous_vote_wrong_proof_count() {
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let msg = AnonVoteMessage {
        proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY,
    };

    // proof_facts vide (0 messages) → Serde échoue ou assertion
    // On construit un ProofFacts avec l1l2messages.len() = 0
    let empty_proof: Array<felt252> = array![0, 0, 0, 0, 0, 0, 0, 0]; // len=0
    start_cheat_proof_facts(d.gov_addr, empty_proof.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
    stop_cheat_caller_address(d.gov_addr);
    stop_cheat_proof_facts(d.gov_addr);
}
```

- [ ] **Step 6: Lancer les tests**

```bash
snforge test test_cast_anonymous_vote_invalid_proof test_cast_anonymous_vote_wrong_proof_count
```

Expected: 2 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add tests/test_governor.cairo
git commit -m "test: add anonymous vote flow tests (ok, replay, invalid proof, wrong count)"
```

---

## Task 7: Test cycle de vie complet — propose → vote → execute

**Files:**
- Modify: `tests/test_governor.cairo`

- [ ] **Step 1: Ajouter test_propose_and_full_lifecycle**

```cairo
// ── Test cycle de vie complet ─────────────────────────────────────────────────

#[test]
fn test_propose_and_full_lifecycle() {
    let d = setup();

    // Bloc 2 : checkpoint délégation enregistrée
    start_cheat_block_number_global(2);

    // Proposer (VOTER a le threshold requis)
    start_cheat_caller_address(d.gov_addr, VOTER());
    let proposal_id = d.governor.propose(array![].span(), "Lifecycle test");
    stop_cheat_caller_address(d.gov_addr);

    // Vérifier état Pending → Active après voting_delay (1 bloc)
    // État actuel : Pending (bloc 2, vote_start = 2 + 1 = 3)
    let state_pending = d.governor.state(proposal_id);
    assert_eq!(state_pending, 0_u8); // ProposalState::Pending = 0

    // Avancer au-delà du vote_start
    start_cheat_block_number_global(4);
    let state_active = d.governor.state(proposal_id);
    assert_eq!(state_active, 1_u8); // ProposalState::Active = 1

    // Voter anonymement
    let signature = array![0x111_felt252, 0x222_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let msg = AnonVoteMessage {
        proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY,
    };

    let message_hash = compute_message_hash(d.gov_addr, @msg);
    let proof_facts = build_proof_facts(message_hash);
    start_cheat_proof_facts(d.gov_addr, proof_facts.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
    stop_cheat_caller_address(d.gov_addr);
    stop_cheat_proof_facts(d.gov_addr);

    // Avancer au-delà du voting_period (vote_start + 50 blocs)
    // vote_start = 3, vote_end = 3 + 50 = 53 → avancer à 54
    start_cheat_block_number_global(54);
    let state_succeeded = d.governor.state(proposal_id);
    assert_eq!(state_succeeded, 4_u8); // ProposalState::Succeeded = 4

    // Exécuter la proposal (appels vides)
    start_cheat_caller_address(d.gov_addr, VOTER());
    d.governor.execute(array![].span(), "Lifecycle test");
    stop_cheat_caller_address(d.gov_addr);

    // Vérifier état final : Executed
    let state_executed = d.governor.state(proposal_id);
    assert_eq!(state_executed, 6_u8); // ProposalState::Executed = 6
}
```

- [ ] **Step 2: Lancer le test**

```bash
snforge test test_propose_and_full_lifecycle
```

Expected: PASS. Si l'état `ProposalState` a des valeurs différentes, vérifier l'enum dans `openzeppelin::governance::governor::interface` et ajuster les assertions.

- [ ] **Step 3: Lancer tous les tests**

```bash
snforge test
```

Expected: tous les tests PASS.

- [ ] **Step 4: Commit final**

```bash
git add tests/test_governor.cairo
git commit -m "test: add full propose→vote→execute lifecycle test"
```

---

## Notes d'implémentation

### Si les noms d'impl ne compilent pas (Task 3)

Vérifier les noms exacts des impls dans le fork local :
```bash
grep -n "pub impl\|#\[embeddable_as\]" /D/Starknet/OZ-contracts/packages/governance/src/governor/extensions/governor_counting_anonymous.cairo
grep -n "pub impl\|#\[embeddable_as\]" /D/Starknet/OZ-contracts/packages/governance/src/governor/extensions/governor_settings.cairo
grep -n "pub impl\|#\[embeddable_as\]" /D/Starknet/OZ-contracts/packages/governance/src/governor/extensions/governor_votes.cairo
grep -n "pub impl\|#\[embeddable_as\]" /D/Starknet/OZ-contracts/packages/governance/src/governor/extensions/governor_core_execution.cairo
```

### Si les chemins d'import des interfaces dispatcher ne compilent pas (Task 4)

Vérifier les interfaces dans le fork :
```bash
grep -rn "IGovernorCountingAnonymous\|IGovernorDispatcher\|IVotesDispatcher" /D/Starknet/OZ-contracts/packages/interfaces/src/ | head -20
grep -rn "IGovernorCountingAnonymousDispatcher" /D/Starknet/OZ-contracts/packages/governance/src/ | head -10
```

### Sur ProposalState (Task 7)

Vérifier les valeurs numériques :
```bash
grep -A 15 "pub enum ProposalState" /D/Starknet/OZ-contracts/packages/interfaces/src/governance/governor.cairo
```

### Sur start_cheat_proof_facts (snforge 0.60.0)

La cheatcode `start_cheat_proof_facts(contract_address, proof_facts)` injecte directement `proof_facts` dans le champ `proof_facts` de `TxInfoV3`. Le tableau de 9 éléments correspond à la sérialisation Serde de la struct `ProofFacts` interne au composant.

Si `start_cheat_proof_facts` n'est pas exporté depuis `snforge_std`, chercher via :
```bash
grep -rn "cheat_proof_facts" ~/.scarb/registry/ 2>/dev/null | head -10
```
