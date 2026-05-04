# ERC20 + Anonymous Governance Governor — Design Spec

**Date:** 2026-05-04
**Cairo / Scarb:** 2.18.0
**OpenZeppelin fork:** https://github.com/PhilippeR26/OZ-contracts (branch: `anonym-vote`)
**snforge_std:** 0.60.0

---

## 1. Objectif

Créer un projet Scarb contenant deux contrats Cairo :

1. **Token** — ERC20 avec voting power (ERC20Votes), mintable par un owner, upgradeable.
2. **Governor** — Contrat de gouvernance avec vote anonyme via SNIP-36
   (`GovernorCountingAnonymousComponent`), paramètres configurables, upgradeable.

Les tests d'intégration couvrent uniquement le Governor, en particulier la partie vote anonyme.

---

## 2. Structure du projet

```
ERC20-anonym-governance-vote/
├── Scarb.toml
├── src/
│   ├── lib.cairo          # déclare les modules token et governor
│   ├── token.cairo        # contrat ERC20Votes
│   └── governor.cairo     # contrat Governor anonyme
└── tests/
    └── test_governor.cairo
```

### Scarb.toml

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

[[target.starknet-contract]]
allowed-libfuncs-list.name = "experimental"
sierra = true
casm = false
```

`allowed-libfuncs-list.name = "experimental"` est requis car `GovernorCountingAnonymousComponent`
utilise `get_execution_info_v3_syscall`.

---

## 3. Contrat Token (`src/token.cairo`)

### Composants

| Composant | Rôle |
|---|---|
| `ERC20Component` | Standard ERC20 (transfer, approve, balanceOf, etc.) |
| `VotesComponent` | Checkpoints de voting power (`get_past_votes`) |
| `NoncesComponent` | Nonces pour `delegate_by_sig` |
| `OwnableComponent` | Contrôle d'accès pour mint et upgrade |
| `UpgradeableComponent` | Mise à jour de la class hash |

### Interface publique

- `ERC20MixinImpl` — toutes les fonctions ERC20 standard
- `VotesImpl` — `delegate`, `get_votes`, `get_past_votes`, `get_past_total_supply`
- `NoncesImpl` — `nonces`
- `OwnableMixinImpl` — `owner`, `transfer_ownership`, `renounce_ownership`
- `fn mint(ref self, recipient: ContractAddress, amount: u256)` — restreint à l'owner
- `fn upgrade(ref self, new_class_hash: ClassHash)` — restreint à l'owner

### Hook ERC20

`after_update` appelle `votes.transfer_voting_units(from, recipient, amount)` à chaque
transfert pour synchroniser les checkpoints de voting power.

### Clock

`ERC6372BlockNumberClock` — checkpoints basés sur le numéro de bloc.

### SNIP-12 Metadata

Nom et version définis comme constantes dans le contrat (requis pour `delegate_by_sig`).

### Constructeur

```cairo
fn constructor(
    ref self: ContractState,
    name: ByteArray,
    symbol: ByteArray,
    initial_supply: u256,
    recipient: ContractAddress,
    owner: ContractAddress,
)
```

Mint `initial_supply` vers `recipient`, initialise `owner`.

---

## 4. Contrat Governor (`src/governor.cairo`)

### Composants

| Composant | Rôle |
|---|---|
| `GovernorComponent` | Cycle de vie des proposals (propose, execute, cancel, state) |
| `GovernorVotesComponent` | Lit le voting power depuis l'ERC20Votes token |
| `GovernorCountingAnonymousComponent` | Vote anonyme SNIP-36 (remplace CountingSimple) |
| `GovernorSettingsComponent` | voting_delay, voting_period, proposal_threshold configurables |
| `GovernorCoreExecutionComponent` | Exécution des proposals (appels on-chain) |
| `SRC5Component` | Introspection d'interfaces |
| `OwnableComponent` | Contrôle pour upgrade |
| `UpgradeableComponent` | Mise à jour de la class hash |

### Interface publique

- `GovernorImpl` — `propose`, `execute`, `cancel`, `state`, `cast_vote`, `cast_vote_with_reason`, `cast_vote_with_reason_and_params`, `cast_vote_by_sig`
- `GovernorCountingAnonymousImpl` — `create_proof`, `cast_anonymous_vote`, `is_nullifier_used`
- `VotesTokenImpl` — `token` (adresse du token ERC20Votes)
- `GovernorSettingsImpl` — `voting_delay`, `voting_period`, `proposal_threshold` (+ setters via proposal)
- `SRC5Impl`
- `OwnableMixinImpl`
- `fn upgrade(ref self, new_class_hash: ClassHash)` — restreint à l'owner

### Quorum

`GovernorQuorumTrait` est implémenté localement. Le quorum est passé en paramètre du
constructeur et stocké dans le storage du contrat.

### SNIP-12 Metadata

Nom et version définis comme constantes dans le contrat.

### Constructeur

```cairo
fn constructor(
    ref self: ContractState,
    votes_token: ContractAddress,
    owner: ContractAddress,
    voting_delay: u64,
    voting_period: u64,
    proposal_threshold: u256,
    quorum: u256,
)
```

### Flux de vote anonyme

1. **Off-chain** (OS virtuel Starknet) : l'électeur appelle `create_proof(proposal_id, support, private_input)`
   — calcule un nullifier depuis sa signature, émet un message L2→L1 engageant le vote.
2. **On-chain** : l'électeur appelle `cast_anonymous_vote(public_message)` — vérifie que le
   `public_message` correspond au message prouvé via `proof_facts` (SNIP-36), consomme le
   nullifier pour prévenir le rejeu.

Le nullifier est dérivé par `poseidon(NULLIFIER_DOMAIN, proposal_id, poseidon(signature))`,
ce qui lie le vote à la proposition sans révéler l'identité du votant.

---

## 5. Tests d'intégration (`tests/test_governor.cairo`)

Tests avec `snforge_std` 0.60.0 — contrats déployés en environnement simulé.

### Setup commun

Fonction utilitaire `setup()` qui :
- Déploie le token ERC20Votes (`initial_supply = 1_000_000 * 10^18`, `recipient = OWNER`)
- Déploie le Governor avec les paramètres de test :
  - `voting_delay = 1` bloc
  - `voting_period = 50` blocs
  - `proposal_threshold = 1 * 10^18`
  - `quorum = 100_000 * 10^18`
- Délègue les votes à un compte test (VOTER)
- Crée une proposal active (avance les blocs pour passer le voting_delay)

### Cas testés

| Test | Description |
|---|---|
| `test_cast_anonymous_vote_ok` | Vote valide accepté, tally mis à jour (for/against/abstain) |
| `test_cast_anonymous_vote_nullifier_replay` | Deuxième vote avec même nullifier → panic `Nullifier already used` |
| `test_cast_anonymous_vote_invalid_proof` | `proof_facts` incorrect → panic `Proof message mismatch` |
| `test_cast_anonymous_vote_wrong_proof_count` | `proof_facts` vide → panic `Expected 1 proof msg` |
| `test_is_nullifier_used` | État du nullifier false avant vote, true après |
| `test_quorum_reached` | Quorum atteint quand for + abstain ≥ quorum |
| `test_vote_succeeded` | Succès si for > against |
| `test_propose_and_full_lifecycle` | propose → avance blocs → vote anonyme → execute |
| `test_counting_mode` | Vérifie `"support=bravo&quorum=for,abstain&params=snip36-anon"` |

### Simulation SNIP-36 en test

`cast_anonymous_vote` lit les `proof_facts` via `get_execution_info_v3_syscall`.
snforge_std 0.60.0 expose `cheat_execution_info` pour injecter des `proof_facts` synthétiques
contenant le hash du message attendu, permettant de tester le flux complet sans OS virtuel.

---

## 6. Contraintes et points d'attention

- **Sécurité** : `GovernorCountingAnonymousComponent` n'est pas audité (avertissement dans le source).
  Ce projet est à vocation expérimentale/recherche.
- **cast_vote désactivé** : en mode anonyme, les fonctions `cast_vote*` standard paniquent avec
  `Use cast_anonymous_vote`. Seul `cast_anonymous_vote` est fonctionnel.
- **has_voted** : retourne toujours `false` en mode anonyme — utiliser `is_nullifier_used`
  pour vérifier si un nullifier a été consommé.
- **libfuncs expérimentales** : nécessaires pour `get_execution_info_v3_syscall`.
- **Quorum** : non modifiable par governance (contrairement à voting_delay/period/threshold).
  Si besoin de quorum dynamique, envisager `GovernorVotesQuorumFractionComponent` dans
  une évolution future.
