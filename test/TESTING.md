# Verdict test coverage

Run `forge build` and `forge test`. All tests use local deployments and the vendored
Foundry/OpenZeppelin dependencies. They need no RPC, fork, environment mutation, FFI,
or network. Test tokens and signer keys are fixtures, not deployment arguments.

The existing protocol conformance test pins the supplied Sepolia digest, signature,
struct hash, EIP-712 domain, and callback selector. The existing market, validation,
oracle, outcome, deployment, and review suites cover the specification's constructor
limits, permissions, timing, callback stipend, retry limits, and late escalation.
The additions below extend that coverage rather than replacing it.

| Added suite | Properties exercised |
| --- | --- |
| `VerdictOracleAdversarial.t.sol` | Every one of the 15 attestation fields is signed and committed in `answerOf`; malformed and malleable signatures cannot consume a pending request; exact expiry and clock-tolerance boundaries; four configuration generations delivered in arbitrary order, including asset/price/action/intake/signer changes and ownership handover; ERC-1271 acceptance and rejection. |
| `VerdictAtomicity.t.sol` | Failed requests restore bounty, ask count, allowances and dispute deadlines; failures at each finalize recipient roll back earlier payments; failed refunds and bounty returns remain retryable; a failed one-shot callback spends its price but permits a later market retry; a funded, eligible claimant cannot reenter a different market during finalize or claim. |
| `VerdictSettlementProperties.t.sol` | Fuzzed fee splits up to 500 bps and all winner permutations; payouts satisfy rational floor bounds and the final winner gets the remainder; explicit zero and one-wei payouts; full-precision payouts with overflowing intermediate products; generated half-open numeric buckets; malformed signed lists; settlement event amounts. |
| `VerdictLifecycleInvariant.t.sol` | Random creation, deposits, asks, invalid/valid delivery, escalation, clock advancement, pause, settlement, claims, donations and calls against terminal markets or the burn vault. |

## Stateful accounting model

The new lifecycle campaign runs 256 sequences of 64 calls, with four actors, all four
answer types, and up to twelve markets created during a sequence. It starts with
funded markets so withdrawal properties always have value to protect. Inputs include
one wei, the available pool cap, transfer fees on incoming deposits, empty winning
outcomes, and the first/last elements of list and numeric outcome definitions.

Independent ghost ledgers record **actual token balance changes** for deposits,
oracle purchases, fees, bounty returns, payouts and refunds. User stakes are recorded
from incoming transfers. After every call the campaign checks:

- Each market's deposits equal its outgoing transfers plus its remaining liability.
- The sum of all remaining liabilities plus separately tracked donations equals the
  markets contract's token balance; markets cannot subsidize one another.
- Each user/outcome stake and each outcome pool matches the independent ledger.
- The oracle holds no payment residue; intake receipts equal recorded oracle spend;
  both approval paths return to zero.
- Treasury and burn balances equal actual fees, with burn donations tracked separately.
- No market exceeds its cap or two paid asks. Terminal status and outcome remain fixed.
- Claim flags, remaining winning stake and remaining payouts agree with the ledger.

After **every sequence**, time advances beyond all deadlines, every market is settled,
and every eligible actor claims. Payouts + refunds + fees + oracle spend + returned
bounty must then equal deposits separately for every market. The only tokens allowed
to remain in `VerdictMarkets` are separately measured direct donations. These are not
market deposits and cannot conceal payout dust.

A deterministic handler test reaches primary delivery, replacement, failed delivery,
finalization, both void paths, claims while paused, and creation after older markets
expire. It checks action counters to catch accidental unreachable handler branches.
The original three-market invariant remains enabled as a separate campaign.

## Revision regression coverage

The numeric interval generator now bounds its first threshold above zero, matching
the revised validation. The explicit zero-bound rejection test remains enabled.
The pre-revision generator failed at `first = 0`, `spacing = 6047842`,
`valueSeed = 431597896588454`, `lengthSeed = 7` with `InvalidParams`; this was
an invalid generated market, not a settlement defect.

The lifecycle handler checks retries against the market's first recorded pending
request. Escalation attestations use their actual issuance time, including issuance
after `answerUntil`. A new random action purchases authenticated same-body answers
independently and attempts to propose them. It checks rejection and unchanged
market state and custody, before and after the market has paid for its own ask.
Independent purchases have a separate balance-delta ledger, so they cannot hide
market overspending or be counted as market deposits. Deterministic reachability
tests exercise these probes, retry after an independent delivery, and late escalation
settlement and complete withdrawal.

`RevisionRegression.t.sol` additionally tests identical escalation bodies across
markets, either arrival order of two paid primary answers, and fuzzed late escalation
latency and dispute windows. Both missing and delivered escalation responses retain
a finite settlement deadline; finalization rejects one second before that deadline,
succeeds at it, and all eligible claims drain the market exactly.

## Scope and interpretation

This is a local contract test suite. The mock Intake models exact payment, a single
attempted callback, swallowed callback failure and no refund. It does not validate
oracle JSON or establish live Sepolia service availability. Incoming transfer-fee
tests turn the mock fee off before oracle payments and settlement; they test credited
deposits, not a promise that an arbitrary taxed token pays recipients in full.

Random testing is bounded, not an exhaustive proof. A failing property must be checked
against the brief before being classified as an implementation defect. No production
contract or configuration changes are part of this test contribution.

## Two-collateral adversarial coverage

`CollateralAdversarial.t.sol` probes the edges of the two-slot adaptation rather than its
happy path: a fuzzed constructor (512 runs) checks each slot's 500 bps ceiling and zero-cap
rejection independently of the other slot and pins the check order (equal tokens and zero
tokens are rejected before fees and caps); WETH stakes of one wei against a one-wei cap and the
last wei of the launch cap; a stake taxed to zero; bets after close, while paused, on an unknown
outcome or id; a creator rich in WETH but without IMD; a fuzzed WETH fee split (512 runs, any
schedule up to 500 bps, stakes down to one wei) that must close the WETH ledger without dust
while the bounty ledger closes in IMD; a WETH double that re-enters `claim`, `finalize`,
`voidMarket` and `bet` from every finalize payout; claim failure paths; refunds while paused;
a price rise that clips rewards to zero without touching the WETH pool; and the bounty-token
snapshot: an IMD-collateral market opened while the oracle's asset is WETH keeps its two ledgers
in swapped tokens, a WETH/WETH market pays the creator once, a rotation after a proposal still
finalizes in the recorded token, and a rotation to a token nobody holds cannot open markets or
reach existing custody. Guardian actions leave both slots untouched, plausible mutator selectors
do not exist, and the contract refuses native ETH and unknown selectors.

`CollateralRotationInvariant.t.sol` is a second campaign (256 runs of 64 calls). Markets are
opened during the sequence in either slot while the oracle's asset rotates between IMD and WETH
and its price moves, so IMD/IMD, WETH/IMD, IMD/WETH and WETH/WETH collateral/bounty pairings
coexist. Asks against a rotated asset are driven into `OracleAssetMismatch` deliberately. Every
deposit, oracle payment, reward, fee, bounty return, payout and refund is measured in the token
it should move in, and the other token is asserted not to move. After every call, the contract's
IMD balance equals the IMD pools still owed plus the IMD bounties still held, and likewise for
WETH; the intake holds exactly the oracle spend per token; the settler's balance in the token
that is not a market's bounty token never changes. After every sequence all markets are settled
and claimed and both balances must reach zero. A deterministic walk reaches all four pairings,
the clipped-reward path and WETH-denominated rewards.

No defect was found by these additions; `.imd-findings.json` was therefore not written.
