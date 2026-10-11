# Independent review: two-collateral VerdictMarkets

Automated review of the adaptation described in `ADAPTATION.md`, performed as a separate pass
after the implementation and its tests were complete, by the same automated worker that wrote
them. It is not a human audit and not a guarantee. The launch's own final independent review
reads this result before anything deploys.

## Scope

Read in full: `src/VerdictMarkets.sol` (the only changed contract), `src/VerdictOracle.sol`,
`src/VerdictBurnVault.sol`, `src/interfaces/IVerdictOracle.sol`, `test/TestBase.sol`,
`test/VerdictCollateral.t.sol`, `test/VerdictCollateralInvariant.t.sol`,
`script/SepoliaParameters.sol`, the pinned `eth-security` and `oracle-consumer` references and
the protected factory test. The review walked every state-changing function for which token
moves, who receives it and which ledger records it.

## Method

- Checks, effects, interactions on every payout: all accounting precedes every transfer; every
  rewarded or paying entry point keeps `nonReentrant`.
- Token identity at each site: `_pull` and `_pay` now take the token explicitly. Bets, payouts,
  refunds and fees use `m.collateral` or the slot's token; bounty pull, oracle approval and
  balance check, settler rewards and bounty return use `m.bountyToken`.
- Lying tokens: fee-on-transfer WETH double, a WETH double that calls back into Markets during
  a payout.
- Cross-ledger leakage: IMD held for other markets or donated, reached through a WETH market.
- Same-token versus distinct-token payment paths at finalization.
- Constructor rejections and the empty-chain constructor rule (no external calls).

## Findings

No defect that moves value to the wrong party or breaks either ledger was found. Observations:

1. **Creator payment path differs by token (informational).** When the collateral is the bounty
   token the creator receives fee plus bounty in one transfer, exactly as before the adaptation;
   otherwise two transfers. Verified by `test_creatorPaymentIsOneTransferForIMDAndTwoForWeth`.
   A creator contract that counts transfers must expect both shapes.
2. **Bounty token is a snapshot of `oracle.asset()` at creation (informational, by design).**
   If the owner rotates the asset, existing markets cannot ask until it is rotated back
   (`OracleAssetMismatch`), while a market created during the rotation holds a different bounty
   token. Returns always use the recorded token, so no market can be paid in the wrong one.
   Verified by `test_bountyReturnsInTheTokenItWasPulledInAfterAssetRotation` and
   `test_oracleAssetMismatchWhenOracleAssetChanges`.
3. **Zero burn share emits no transfer.** `_pay` skips zero amounts, so a slot with
   `burnFeeBps == 0` never calls the token for the sink. Verified by log inspection.
4. **Fee-on-transfer collateral.** Credits only the received amount for stake, cap and refund;
   the pool cannot exceed the slot cap by any path. Verified.
5. **Reentrancy through the collateral token.** A callback during `claim` cannot re-enter
   `claim`, `bet` or any settlement function; the guard reverts and the hook's failure is
   swallowed by the token, leaving the payout exact. Verified.
6. **Runtime size.** VerdictMarkets runtime is 17,715 bytes (initcode 18,764 before arguments),
   below EIP-170 and the factory's 49,152-byte initcode bound; no DELEGATECALL, CALLCODE or
   SELFDESTRUCT (the existing deployment rehearsal walks the bytecode).

## Not reached

The live Sepolia Intake, TestIMD and WETH contracts (no RPC used), the oracle service's body
validation, and the website. The WETH double is a plain ERC-20 with optional fee and hook; the
real Sepolia WETH9 returns `true` from `transfer` and `transferFrom` and has no fee, which is the
simpler case.

## Result

`forge test` after adding the six reviewer tests: all suites pass (see `ADAPTATION.md` for the
counts). Build with the project's own configuration and `forge fmt` produce no error.
