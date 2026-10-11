# Verdict two-collateral adaptation (after Sepolia launch 1296)

This is the contracts-only Sepolia adaptation of the audited settler-reward Verdict contracts
(launch 1296). Each market now takes bets in one of two collateral tokens fixed at construction,
IMD (slot 0) or WETH (slot 1), while bounties, oracle fees and settler rewards stay in IMD. No
other behaviour changes except the one reproduced audit finding fixed below. No token, pool,
proxy, initializer, external library or new authority is introduced. Solidity 0.8.26, the Foundry
configuration, vendored OpenZeppelin v5 and forge-std are unchanged. `web/` and `dist/` are
untouched. No dependency was installed.

## Changes and reasons

| File | Change | Required by |
| --- | --- | --- |
| `src/VerdictMarkets.sol` | Constructor becomes `VerdictMarkets(oracle, treasury, burnSink, guardian, token0, creatorBps0, burnBps0, treasuryBps0, maxPool0, token1, creatorBps1, burnBps1, treasuryBps1, maxPool1, maxSettlerReward)` (15 arguments). Both tokens nonzero and different (`InvalidAddress`, `InvalidCollateral`), each slot's fees at most 500 bps (`InvalidFees`), each cap above zero (`InvalidCap`). Slots are immutable. | Brief: exactly two fixed collateral slots; the launch's 15-argument constructor. |
| `src/VerdictMarkets.sol` | New `Collateral` struct and `collateralConfig(uint8)`; `collateral`, `creatorFeeBps`, `burnFeeBps`, `treasuryFeeBps`, `maxPoolPerMarket` take a slot and revert `InvalidCollateral` for slots other than 0 and 1. | Brief: per-slot getters. |
| `src/VerdictMarkets.sol` | `Params.collateralId` (uint8, appended last); `createMarket` reverts `InvalidCollateral` for any value above 1. `Market` appends `collateral` and `bountyToken`. `MarketCreated` appends `address collateral`. | Brief. |
| `src/VerdictMarkets.sol` | `bet`, `claim`, refunds, the pool cap and the fee split use the market's collateral token and its slot's fees and cap. `_pull`/`_pay` take the token explicitly. A zero burn share never calls the token for the sink. | Brief: collateral ledger per market. |
| `src/VerdictMarkets.sol` | The bounty is pulled in `oracle.asset()` at creation and recorded as `bountyToken`. `_ask` approves, pays and balance-checks that token and reverts `OracleAssetMismatch` when `oracle.asset()` differs from it; settler rewards and bounty returns pay from it. The creation-time check that the oracle asset equals the collateral is removed (the bounty token is the oracle asset by construction). When collateral and bounty token are the same, the creator still receives fee plus bounty in one transfer. | Brief: bounty ledger in IMD; audit note 6f6c7d50 (the four token sites). |
| `src/VerdictMarkets.sol` | `propose` accepts, for the first proposal, only the market's most recent paid primary request (`primaryRequests[asks - 1]`) instead of either of the two. | Audit 94b4f1d1 (reproduced): own-ask outcome shopping. |
| `src/VerdictMarkets.sol` | NatSpec on `createMarket` and `bet` stating that `agentId` is an unverified caller-supplied label; contract-level NatSpec on the two ledgers and the absence of a native ETH path. | Audit 71eb503b (reproduced); brief. |
| `script/SepoliaParameters.sol` | Encodes the 15 launch arguments: slot 0 test IMD 150/50/50 bps, 500 IMD cap; slot 1 Sepolia WETH `0xfff9976782d46cc05630d1f6ebab18b2324d6b14` 150/0/100 bps, 1 WETH cap; `maxSettlerReward` 0.25 IMD. | Exact requested deployment arguments; audit 339965eb. |
| `launch.json` | Removed. | Audit 339965eb (reproduced: it carried the 10-argument constructor); the launch reference assigns the manifest to the next step and rejects a stale one in the builder's tree. |
| `test/TestBase.sol` | Second mock token (`weth`), `newMarkets` helper building slot 0 with the test's terms and slot 1 with the launch's WETH terms, `collateralId` in `params()`, and `assertConserved` checking the two ledgers separately (now including `rewardsPaid`). | ABI change; two-ledger accounting. |
| `test/Deployment.t.sol`, `test/SettlerDeployment.t.sol` | Assert the 15 literal arguments, both slots' getters, WETH without code at rehearsal time, and `collateralConfig(2)` reverting. | Launch compatibility; stale-manifest regression. |
| `test/VerdictMarketsValidation.t.sol`, `test/SettlerIndependentReview.t.sol`, `test/SettlerBountyBoundaries.t.sol`, `test/VerdictSettlerRewards.t.sol`, `test/VerdictSettlementProperties.t.sol`, the four invariant handlers | Constructor calls through `newMarkets`; `maxPoolPerMarket(0)`; `MarketCreated` decoded with the appended collateral. Assertions otherwise unchanged. | ABI change only. |
| `test/RevisionRegression.t.sol` | `testFuzz_eitherPaidPrimaryRequestCanProposeButCannotReplace` becomes `testFuzz_onlyLatestPaidPrimaryRequestCanProposeRegardlessOfDeliveryOrder`; the tail of `test_otherMarketAnswerCannotSetOutcomeOrBlockRetry` now expects a late first answer to be refused after a retry and the retry's answer to be accepted. | These tests encoded the behaviour audit 94b4f1d1 changes. |
| `test/SettlerRewardSequence.t.sol` | The handler proposes only an answer to the latest primary ask. | Same finding; `fail_on_revert` campaign. |
| `test/VerdictCollateral.t.sol` | New: slots' own fees and caps; WETH market's fees, payouts and refunds in WETH with bounty, oracle spend and rewards in IMD; IMD market's two separate ledgers with the contract's IMD balance equal to their sum; `collateralId` out of range; constructor rejections (equal or zero tokens, zero caps, fees over 500 per slot); zero burn share emitting no transfer; `OracleAssetMismatch` on asset change for resolve and escalate, and the bounty token snapshot; `MarketCreated` collateral; a bettor without WETH cannot bet IMD into a WETH market. | Brief's new tests. |
| `test/VerdictCollateralInvariant.t.sol` | New: stateful lifecycle campaign over four markets, two per slot, with settler rewards and changing oracle prices; measured token movements per ledger; custody equalities for IMD and WETH; full drain with no dust. | Brief: full lifecycle invariant for both slots with settler rewards. |
| `test/VerdictImportedAudit.t.sol` | Added reproductions: fresh deployment cannot create until the guardian acts; `agentId` is an unverified label. | Audit 363cc8ba, 71eb503b. |
| `test/CollateralIndependentReview.t.sol`, `docs/COLLATERAL_INDEPENDENT_REVIEW.md` | Reviewer-authored probes (reentrancy through the collateral token, fee-on-transfer collateral, cross-ledger reach, price rise, payment shapes, bounty token after rotation) and the review report. | Brief: independent review. |
| `docs/AGENTS.md`, `docs/agents/addresses.json`, `docs/agents/abi/*.json` | Guide for agents and operators with the ABIs of this build and the addresses file the deployment handoff completes. | Brief. |
| `docs/DEPLOYMENT.md`, `README.md`, this file | Constructor table, collateral slots, two-ledger accounting, audit dispositions. | Launch documentation. |

`src/VerdictOracle.sol`, `src/VerdictBurnVault.sol`, `src/OracleAttestation.sol` and both
interfaces are byte-for-byte unchanged.

## Accounting

Per market, after every entitled claim:

```text
collateral token:  paidOut + refunded + fees                    == pool
bounty token (IMD): oracleSpend + rewardsPaid + returnedBounty  == params.bounty
```

The contract's IMD balance equals the sum over markets of (IMD pool still owed, for slot 0
markets) plus `bountyRemaining`; its WETH balance equals the sum of WETH pools still owed. Both
are asserted against measured transfers in `VerdictCollateralInvariant.t.sol`. WETH is a plain
ERC-20 here: Markets has no `receive`, `fallback` or payable function.

## Imported audit dispositions

1. **94b4f1d1 — own-ask outcome shopping: reproduced, fixed.** Before the change, both of a
   market's paid primary requests could establish the outcome, so when both were answered
   differently the first proposer chose. `propose` now accepts only the most recent paid primary
   ask. A retry is bought blind (only while the first ask is still pending), so no caller can
   choose between two answers. Cost: a first answer that arrives after a retry is unusable; if
   the retry is never answered the market voids and refunds. Regression:
   `testFuzz_onlyLatestPaidPrimaryRequestCanProposeRegardlessOfDeliveryOrder`.
2. **339965eb — stale launch.json and 10-argument parameters: reproduced, fixed.** The manifest
   is removed (the manifest step writes it) and the parameter library and deployment tests encode
   the 15 arguments literally.
3. **71eb503b — agentId undocumented: reproduced, fixed.** NatSpec on `createMarket` and `bet`;
   `test_agentIdIsAnUnverifiedLabel`. No behaviour change, as the brief requires.
4. **b9cde0e9 — creator schedule can lock bets: reproduced earlier, unchanged.** The brief asks
   for no behaviour change; `test_creatorCanSetVoidAfterFarInFuture` still documents it, and
   `docs/AGENTS.md` tells bettors to inspect `voidAfter`. With WETH the locked value is ETH.
5. **363cc8ba — allowlist on and empty: reproduced, unchanged by design.**
   `test_freshDeploymentCannotCreateUntilGuardianActs`. The first `createMarket` on Sepolia
   reverts until the owner admits a creator or disables the allowlist.
6. **af3a8acb — zero-delay oracle owner: not a defect, unchanged.** Requested configuration;
   documented as a trust assumption in README and `docs/AGENTS.md`.
7. **6f6c7d50 — adapter note on the four token sites: applied.** `_ask`, `_pull`, `_pay` and
   creation now use the bounty token where the audit marked it.
8. **f6d12f90 — coverage statement: no action.**

## Validation

- Before the change: `forge test` passed 156 tests in 22 suites with the project's configuration.
- After the change: `forge build` passes; `forge test` passes **178 tests in 25 suites**, all of
  the original tests (two regression tests rewritten for finding 1 as listed above), the 12 new
  collateral tests, the two-slot invariant campaign (128 runs × 64 calls, `fail_on_revert`, full
  drain after every run), the two added audit reproductions and the six review probes.
- VerdictMarkets runtime 17,715 bytes; the existing deployment rehearsal walks all three
  bytecodes for size and forbidden opcodes on an empty chain with no code at the IMD, WETH or
  Intake addresses, so the constructors call nothing.

## Deployment handoff

Sepolia only (11155111), order **VerdictBurnVault → VerdictOracle → VerdictMarkets**, arguments
in `docs/DEPLOYMENT.md` and `script/SepoliaParameters.sol`. The owner, treasury and guardian are
`0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`. The worker reads no keys and broadcasts nothing:
the launch's manifest, final review and deployment stages deploy the built bytecodes and write
the confirmed addresses into `docs/agents/addresses.json`. No addresses are invented here. The
launch-1296 website keeps its own ABI and addresses; a later site job must regenerate them.
