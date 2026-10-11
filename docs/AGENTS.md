# Verdict for AI agents and their operators

A plain guide to using the Verdict markets on Sepolia (chain id 11155111) from a script or an
agent. It covers finding markets, reading one, betting in IMD or WETH, earning settler rewards,
and claiming. It assumes you can sign and send Ethereum transactions and decode ABI data.

## Which ABIs and addresses to use

Use exactly these files from this repository:

- `docs/agents/addresses.json`: chain id, the three contract addresses, the external addresses
  (Intake, IMD, WETH, oracle signer, owner) and both collateral slots with their fees and caps.
  The three contract addresses are filled by the deployment handoff after the launch service
  deploys them. While they are `null` the contracts are not deployed yet.
- `docs/agents/abi/VerdictMarkets.json`, `docs/agents/abi/VerdictOracle.json`,
  `docs/agents/abi/VerdictBurnVault.json`: the ABIs of this build, exported with
  `forge inspect <Contract> abi --json`.

Do not use `web/src/config.ts` or `web/src/abi/*.json`. Those belong to launch 1296 and its
single-collateral `VerdictMarkets`, whose `createMarket`, `getMarket` and `MarketCreated` encode
differently from this build.

Tokens are plain ERC-20s. There is no native ETH path: to bet in ETH, wrap it into Sepolia WETH
(`deposit()` on `0xfff9976782d46cc05630d1f6ebab18b2324d6b14`) and approve `VerdictMarkets`.
Test IMD (`0x44a1cd38474fb1748400e7deb5f8d786cce3f89a`) has an open `mint(address,uint256)`.

## Collateral slots

Every market bets in one of two collateral slots fixed at construction:

| Slot | Token | Creator fee | Burn fee | Treasury fee | Pool cap per market |
| --- | --- | --- | --- | --- | --- |
| 0 | test IMD | 1.5% | 0.5% | 0.5% | 500 IMD |
| 1 | Sepolia WETH | 1.5% | 0% | 1% | 1 WETH |

Read a slot with `collateralConfig(uint8 slot)` which returns
`(token, creatorFeeBps, burnFeeBps, treasuryFeeBps, maxPoolPerMarket)`. Any other slot reverts
`InvalidCollateral`. Whatever the slot, the market's bounty, the oracle fees and the settler
rewards are in IMD, the oracle's asset.

## Finding markets from events

Scan `VerdictMarkets` logs from the deployment block in `addresses.json`:

- `MarketCreated(uint256 indexed id, address indexed creator, bytes32 indexed bodyHash,
  bytes32 escalationBodyHash, bytes body, bytes escalationBody, string uri, uint256 agentId,
  address collateral)`. One per market. `body` and `escalationBody` are the complete oracle
  request JSON, byte for byte, which you need again for `resolve` and `escalate`. `collateral`
  is the token the market bets in.
- `BetPlaced(uint256 indexed id, address indexed bettor, uint8 indexed outcome, uint256 amount,
  uint256 agentId)`: the credited stake in the market's collateral token.
- `OracleAsked(uint256 indexed id, bytes32 indexed intakeRequestId, bool escalation, uint256 price)`:
  a paid oracle request belonging to the market.
- `OutcomeProposed`, `DisputeExtended`, `Finalized`, `Voided`, `BountyReturned`,
  `SettlerRewarded`, `Claimed`: the rest of the lifecycle.

On `VerdictOracle`, `Answered(bytes32 indexed requestId, bytes32 indexed intakeRequestId,
bytes32 indexed bodyHash, bytes32 attHash)` tells you an answer was delivered for an Intake
request. Match `intakeRequestId` against the market's `OracleAsked` events.

## Reading a market and its bodies

`getMarket(id)` returns the full `Market` struct: the immutable `params`
(`questionHash`, `answerType`, `dataChainId`, block window, panel minima, `closeAt`,
`answerFrom`, `answerUntil`, `disputeWindow`, `voidAfter`, `bounds`, `keys`, `bounty`,
`settlerReward`, `collateralId`), the `status` (0 Open, 1 Provisional, 2 Finalized, 3 Voided),
`outcomes` (how many buckets), the current `outcome`, `asks`, `disputeEnds`, `pool`,
`bountyRemaining`, the two ledgers' counters, `primaryRequests`, `escalationRequest`,
`collateral` and `bountyToken`.

The bodies are not stored on chain. Take them from the market's `MarketCreated` event and check
`keccak256(body) == bodyHash` before relying on them. The body is the question the oracle
answers; `params.questionHash` is the protocol's hash of that question, window and definitions.

Outcome mapping by `answerType`: bool `false → 0`, `true → 1`; uint256 buckets by `bounds`;
address[] and bytes32[] by matching the first element to `keys`, with the last bucket for an
empty list or no match. Per-outcome stake is `outcomePool(id, outcome)`.

## Betting with an agentId

1. Read `getMarket(id)`: `status` must be 0 and `block.timestamp < params.closeAt`.
2. Read `collateralConfig(params.collateralId)` for the token and the cap. Your credited amount
   must fit `maxPoolPerMarket - pool` or the call reverts `PoolCapExceeded`.
3. Approve that token for `VerdictMarkets` and call `bet(id, outcome, amount, agentId)`.

`agentId` is a label you choose. It is emitted in `BetPlaced` and `MarketCreated` for
attribution and is not verified: nothing ties it to your address, a registry or a signature, and
anyone can emit any value. Operators who aggregate by `agentId` must treat it as a claim, not an
identity. By convention `0` means a person.

Bets cannot be withdrawn. The contract credits what actually arrived, so fee-on-transfer tokens
credit less than `amount`.

## Earning settler rewards

Each market's creator sets `params.settlerReward` (at most `maxSettlerReward()`, 0.25 IMD at
this launch), paid in IMD from the market's bounty to the caller of each successful step below.
`escalate` is unrewarded, and a reward is clipped to zero if paying it would leave less than the
price of the asks the market may still need. Every call is permissionless.

### resolve

When `status == 0` and `answerFrom <= now < answerUntil`, call `resolve(id, body)` with the
exact `body` bytes from `MarketCreated`. The market pays the oracle from its bounty, records
`OracleAsked`, and pays you the reward. A second `resolve` is possible 24 hours later only if the
first request is still unanswered. Only the most recent paid primary ask can establish the outcome.

### propose

Wait for the oracle's `Answered` event whose `intakeRequestId` is the market's latest
`OracleAsked`. The signed attestation itself is not stored on chain; recover it from the
delivery transaction:

1. Take the transaction that emitted `Answered`. Its outer call is `Intake.complete(bytes32
   requestId, uint8 status, bytes32 resultHash, string uri, bytes args)` on the Intake at
   `0xa43e6f75ee006411f79ac1c84120606c2330de82`.
2. ABI-decode `args` as `(bytes32 intakeRequestId, Attestation a, bytes signature)`. The
   `Attestation` tuple has 15 fields in this order: `requestId, chainId, questionHash,
   answerType, answer, figure, fromBlock, toBlock, blockHash, panelJobId, panelSize, quorum,
   agreed, issuedAt, expiresAt`. The ABI file's `answerOf` input gives the exact tuple type.
3. Check `keccak256(abi.encode(a)) == Answered.attHash` and `a.requestId == Answered.requestId`.
4. Call `propose(id, a)`. The contract checks the answer against the market's own paid request,
   the question hash, the block window, the panel minima and the issuance window, then sets a
   provisional outcome, starts the dispute window and pays you the reward.

`web/src/domain.ts` (`recoverAttestation`) is a working reference for this decoding.

### escalate and the replacement proposal

During the dispute window, before `answerUntil`, anyone may call `escalate(id, escalationBody)`
once if the market has an escalation body. It spends the market's last ask and extends the
window to at least 24 hours. When the escalation answer is delivered, `propose(id, a)` with that
attestation (panel at least twice the first one's) replaces the outcome and pays the proposal
reward. `escalate` itself pays nothing.

### finalize

When `status == 1` and `now >= disputeEnds`, call `finalize(id)`. It takes the fees in the
market's collateral token, returns the unspent bounty to the creator in IMD and pays you the
reward in IMD. It reverts `NoWinningStake` if nobody bet on the winning outcome; use
`voidMarket` then.

### voidMarket

Call `voidMarket(id)` when an open market reaches `voidAfter` with no outcome, or when a
provisional outcome's dispute window has ended with no stake on the winning bucket. It returns
the unspent bounty to the creator and pays you the reward, both in IMD. No fees are taken.

## Claiming

After `Finalized`, each winner calls `claim(id)` once and receives
`stake * (pool - fees) / winningPool` in the collateral token; the last claimant gets the exact
remainder. After `Voided`, every bettor calls `claim(id)` once and receives all their credited
stakes back in the collateral token. There is no deadline. A WETH payout is WETH: call
`withdraw(amount)` on WETH to get ETH.

## Accounting you can verify

For each market, in its collateral token: `paidOut + refunded + fees == pool` once every
entitled claim is made. In IMD: `oracleSpend + rewardsPaid + returnedBounty == params.bounty`
once the market is terminal. The contract's IMD balance is the sum over markets of IMD pools
still owed plus `bountyRemaining`; its WETH balance is the sum of WETH pools still owed.

## Trust notes for operators

- The oracle owner (`0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`) can change the Intake,
  asset, signer and price with zero delay. Future asks trust the new values; paid requests keep
  the old ones. If the oracle's asset is changed away from a market's bounty token, that market's
  asks revert `OracleAssetMismatch` until it is changed back, but refunds at `voidAfter` and
  claims still work.
- The guardian (same address) controls only entry: pause, creator allowlist. It cannot touch
  funds or outcomes. A fresh deployment accepts no markets until the guardian admits a creator or
  disables the allowlist.
- A creator chooses the market's schedule. Nothing bounds `voidAfter`; inspect it before betting.
