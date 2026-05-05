use core::poseidon::poseidon_hash_span;
use openzeppelin::governance::governor::extensions::GovernorCountingAnonymousComponent::AnonVoteMessage;
use openzeppelin::interfaces::governance::governor::ProposalState;
use openzeppelin::utils::bytearray::ByteArrayExtTrait;
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

use openzeppelin::interfaces::token::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin::interfaces::governance::votes::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin::interfaces::governance::governor::{IGovernorDispatcher, IGovernorDispatcherTrait};
use openzeppelin::governance::governor::extensions::GovernorCountingAnonymousComponent::{
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
    let token_class = declare("GovToken").unwrap().contract_class();
    let mut token_calldata: Array<felt252> = array![];
    let name: ByteArray = "GovToken";
    let symbol: ByteArray = "GT";
    name.serialize(ref token_calldata);
    symbol.serialize(ref token_calldata);
    INITIAL_SUPPLY.serialize(ref token_calldata);
    OWNER().serialize(ref token_calldata);
    OWNER().serialize(ref token_calldata);
    let (token_addr, _) = token_class.deploy(@token_calldata).unwrap();

    let gov_class = declare("AnonGovernor").unwrap().contract_class();
    let mut gov_calldata: Array<felt252> = array![];
    token_addr.serialize(ref gov_calldata);
    OWNER().serialize(ref gov_calldata);
    VOTING_DELAY.serialize(ref gov_calldata);
    VOTING_PERIOD.serialize(ref gov_calldata);
    PROPOSAL_THRESHOLD.serialize(ref gov_calldata);
    QUORUM.serialize(ref gov_calldata);
    let (gov_addr, _) = gov_class.deploy(@gov_calldata).unwrap();

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

fn compute_nullifier(proposal_id: felt252, signature: Span<felt252>) -> felt252 {
    let sig_hash = poseidon_hash_span(signature);
    poseidon_hash_span(array![NULLIFIER_DOMAIN, proposal_id, sig_hash].span())
}

fn compute_message_hash(governor_addr: ContractAddress, msg: @AnonVoteMessage) -> felt252 {
    let mut payload: Array<felt252> = array![];
    (*msg).serialize(ref payload);
    let mut data: Array<felt252> = array![
        governor_addr.into(),
        0_felt252,
        payload.len().into(),
    ];
    for f in payload.span() {
        data.append(*f);
    };
    poseidon_hash_span(data.span())
}

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

fn create_active_proposal(d: @Deployment) -> felt252 {
    start_cheat_block_number_global(2);

    start_cheat_caller_address(*d.gov_addr, VOTER());
    let proposal_id = d.governor.propose(array![].span(), "Test proposal");
    stop_cheat_caller_address(*d.gov_addr);

    start_cheat_block_number_global(4);
    proposal_id
}

// ── Drop impl for Deployment (required in integration tests) ─────────────────

impl DeploymentDrop of Drop<Deployment> {}

// ── Tests counting_mode ───────────────────────────────────────────────────────

#[test]
fn test_counting_mode() {
    let d = setup();
    let mode = d.governor.COUNTING_MODE();
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
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);
    let gov = IAnonGovernorDispatcher { contract_address: d.gov_addr };
    assert_eq!(gov.quorum_reached(proposal_id), false);
}

// ── Tests vote_succeeded ──────────────────────────────────────────────────────

#[test]
fn test_vote_not_succeeded_with_no_votes() {
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);
    let gov = IAnonGovernorDispatcher { contract_address: d.gov_addr };
    assert_eq!(gov.vote_succeeded(proposal_id), false);
}

// ── Tests cast_anonymous_vote ─────────────────────────────────────────────────

#[test]
fn test_cast_anonymous_vote_ok() {
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());

    let msg = AnonVoteMessage {
        proposal_id,
        nullifier,
        support: 1,
        weight: INITIAL_SUPPLY,
    };

    let message_hash = compute_message_hash(d.gov_addr, @msg);
    let proof_facts = build_proof_facts(message_hash);
    start_cheat_proof_facts(d.gov_addr, proof_facts.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
    stop_cheat_caller_address(d.gov_addr);

    stop_cheat_proof_facts(d.gov_addr);

    let gov = IAnonGovernorDispatcher { contract_address: d.gov_addr };
    assert_eq!(d.anon_governor.is_nullifier_used(proposal_id, nullifier), true);
    assert_eq!(gov.quorum_reached(proposal_id), true);
    assert_eq!(gov.vote_succeeded(proposal_id), true);
}

#[test]
#[should_panic(expected: 'Nullifier already used')]
fn test_cast_anonymous_vote_nullifier_replay() {
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());

    let msg = AnonVoteMessage { proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY };

    let message_hash = compute_message_hash(d.gov_addr, @msg);
    let proof_facts = build_proof_facts(message_hash);

    start_cheat_proof_facts(d.gov_addr, proof_facts.span());
    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);

    let msg2 = AnonVoteMessage { proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY };
    d.anon_governor.cast_anonymous_vote(msg2);
}

#[test]
#[should_panic(expected: 'Proof message mismatch')]
fn test_cast_anonymous_vote_invalid_proof() {
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let msg = AnonVoteMessage {
        proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY,
    };

    let wrong_proof = build_proof_facts(0xdeadbeef_felt252);
    start_cheat_proof_facts(d.gov_addr, wrong_proof.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
}

#[test]
#[should_panic(expected: 'Expected 1 proof msg')]
fn test_cast_anonymous_vote_wrong_proof_count() {
    start_cheat_block_number_global(1);
    let d = setup();
    let proposal_id = create_active_proposal(@d);

    let signature = array![0xaaa_felt252, 0xbbb_felt252];
    let nullifier = compute_nullifier(proposal_id, signature.span());
    let msg = AnonVoteMessage {
        proposal_id, nullifier, support: 1, weight: INITIAL_SUPPLY,
    };

    let empty_proof: Array<felt252> = array![0, 0, 0, 0, 0, 0, 0, 0];
    start_cheat_proof_facts(d.gov_addr, empty_proof.span());

    start_cheat_caller_address(d.gov_addr, VOTER());
    d.anon_governor.cast_anonymous_vote(msg);
}

// ── Test cycle de vie complet ─────────────────────────────────────────────────

#[test]
fn test_propose_and_full_lifecycle() {
    start_cheat_block_number_global(1);
    let d = setup();

    start_cheat_block_number_global(2);

    start_cheat_caller_address(d.gov_addr, VOTER());
    let proposal_id = d.governor.propose(array![].span(), "Lifecycle test");
    stop_cheat_caller_address(d.gov_addr);

    // Pending state (vote_start = 2 + 1 = 3, current block = 2)
    let state_pending = d.governor.state(proposal_id);
    assert_eq!(state_pending, ProposalState::Pending);

    // Advance past vote_start → Active
    start_cheat_block_number_global(4);
    let state_active = d.governor.state(proposal_id);
    assert_eq!(state_active, ProposalState::Active);

    // Vote anonymement
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

    // Advance past vote_end (vote_start=3 + period=50 = 53 → advance to 54)
    start_cheat_block_number_global(54);
    let state_succeeded = d.governor.state(proposal_id);
    assert_eq!(state_succeeded, ProposalState::Succeeded);

    // Execute the proposal
    let description: ByteArray = "Lifecycle test";
    let description_hash = description.hash();
    start_cheat_caller_address(d.gov_addr, VOTER());
    d.governor.execute(array![].span(), description_hash);
    stop_cheat_caller_address(d.gov_addr);

    let state_executed = d.governor.state(proposal_id);
    assert_eq!(state_executed, ProposalState::Executed);
}
