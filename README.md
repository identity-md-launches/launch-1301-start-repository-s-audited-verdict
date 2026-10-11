# Verdict

The Verdict website is a static React / TypeScript application for the live Sepolia contracts. It reads markets, pools, oracle evidence and positions directly from public RPCs. There is no backend, analytics, tracker, remote font dependency or private key. **Sepolia testnet: test IMD has no value.**

The requested site label is **`verdict`**, for **https://verdict.sites.imd.fun**. The production export is in [`dist/`](dist/index.html), with source and the pinned npm lockfile in [`web/`](web/package.json). Hosting is performed by the assignment publisher after submission; this job does not publish or broadcast transactions.

## Install, rebuild and preview the website

Use Node **22.18+** (revision validated with Node 24.21.0) and npm. The isolated runner installs the exact lockfile into a content-addressed directory under the operating system’s temporary directory. It keeps dependencies and caches out of this repository and leaves the existing Foundry setup untouched.

```sh
node web/scripts/isolated.mjs install
node web/scripts/isolated.mjs typecheck
node web/scripts/isolated.mjs test
node web/scripts/isolated.mjs build
node web/scripts/isolated.mjs preview
```

Open the local preview URL printed by Vite. `dev` starts the development server. The production build replaces `dist/`; always rebuild after source changes. An ordinary local frontend workflow also works: `cd web`, `npm ci`, then `npm run build`, `npm run typecheck`, `npm test`, or `npm run preview`. Never include generated `node_modules/`, caches or dependency archives in a submission. The checked-in export needs no npm installation to serve.

## Browser and contract checks

```sh
node web/scripts/isolated.mjs browser:install
node web/scripts/isolated.mjs test:browser
node web/scripts/isolated.mjs test:wallet
node web/scripts/isolated.mjs test:wallet --revision
node web/scripts/isolated.mjs verify:contracts
```

The browser scripts serve the actual `dist/` at a temporary `/preview/` subpath, run Chromium, then close both the browser and server. `test:browser` uses live Sepolia RPCs and checks real chain records. `test:wallet` intercepts all external RPC requests and supplies a simulated EIP-6963 wallet; it exercises approval, bet, create, settlement and claim flows **without signing or broadcasting anything**. `test:wallet --revision` adds long list-key review, local-time display, font assertions, access rechecks, automatic refresh with an advanced browser clock, and failed-attestation recovery. A preinstalled browser can be selected with `CHROMIUM_EXECUTABLE=/absolute/path/to/chromium`. `verify:contracts` needs Foundry and network access; its compiler outputs stay in `/tmp`.

Revision checks on 2026-10-11 passed: production build, typecheck, 14 domain tests, 28 live browser checks, 37 original simulated-wallet checks and 37 targeted revision checks. Nine automated accessibility scans found no violations in the tested states; all 12 measured text/control contrast pairs passed. The revised phone home screen shows a real market and its View market action at 390×844. All nine reported defects reproduced and were fixed; individual answers are in `.imd-responses.json`, with before/after evidence in `web/validation/revision-before.json` and `web/validation/revision-results.json`. The export is 684,853 bytes; the conservative submission bound is below 5.2 MB (8 MiB limit). Live wallet broadcasts and production hosting were not exercised.

Reports and screenshots are written to `artifacts/` for the assignment’s artifact collector. Compact copies of final JSON reports are retained in `web/validation/`. The consolidated six-domain design review, actual commands, findings, and limitations are in [docs/WEBSITE_VALIDATION.md](docs/WEBSITE_VALIDATION.md). The implemented design system is documented in [DESIGN.md](DESIGN.md).

## Static publication

Publish the **contents of `dist/`** under label **`verdict`**. The assignment publisher pins that export and serves it at `verdict.sites.imd.fun`; it does not rebuild the source. No publishing command was run in this assignment. For another static host, upload the same directory unchanged. Vite uses `base: './'`; routes use hashes, so gateway subpaths and static hosts do not need rewrites. All runtime fonts, scripts, styles, favicon and social preview image are local. Open Graph metadata uses the requested canonical site URL.

Before submitting, include the source, `web/package.json`, `web/package-lock.json`, `dist/`, and documentation. Exclude dependencies, generated caches and temporary files. The static application never imports the captured test fixtures or validation reports.

## Chain configuration and data model

[`web/src/config.ts`](web/src/config.ts) is the only runtime source of chain IDs, deployment addresses and blocks, RPC lists, explorer URLs, wallet parameters, expected block intervals and verified runtime code hashes. Sepolia is the only configured Verdict deployment. Ethereum is available solely as a data chain for questions; there are no invented mainnet Verdict addresses. Add a verified deployment to the configuration to enable its network selector and wallet flow; no application code changes are needed for another deployment of the same contracts.

The ABIs in `web/src/abi/` were compiled from this repository and match the pinned deployment ABI hashes. `provenance.json` records those hashes and the deployment source commit. At runtime the site checks the RPC chain ID and full deployed code hashes before enabling transactions.

- History starts at the configured deploy block in inclusive chunks of at most 10,000 blocks. Publicnode is tried first, then configured fallbacks. A refused block range can be subdivided. Refreshes overlap 24 blocks to replace recent reorged logs; data is kept in memory, with no remote indexer.
- Every snapshot reads state and pools at the same block as its log scan. Market count is checked against the number of creation events. Public data refreshes every 30 seconds while the tab is visible; manual refresh and post-transaction refresh are also available. Errors retain the last successful snapshot and disable write controls until recovery.
- Questions and both oracle bodies come from `MarketCreated`, never a metadata API. `OracleAsked` intake IDs associate oracle `Answered` events with their market. Submission decodes `Intake.complete` calldata, decodes its callback arguments, verifies the request IDs and body hash, and compares `keccak256(abi.encode(attestation))` with `attHash` before offering `propose`. A successful refresh retries failed attestation reads while retaining already verified evidence. Recovery errors link to the oracle explorer directory and display the request UUID; panel job links require a recovered panel ID.
- Every permissionless settlement/claim control is simulated for the connected wallet. Every send is simulated again immediately before the wallet prompt. Bet and bounty approvals are exact, only when the existing allowance is insufficient. All UI bets use `agentId = 0`.
- “Settled markets” counts Finalized markets. “Total paid out” sums winning payouts, excluding refunds and creator fees. Volume sums credited market pools. Burned IMD is the token balance of the immutable burn vault. Display amounts are shortened with exact values available on hover; uint256 bucket bounds use full 18-decimal units. Oracle figures are shown raw because their units depend on the question.
- Creator access follows the on-chain allowlist, including its permanent disable switch. The builder validates schedules and outcomes, creates compact primary/escalation JSON, doubles escalation panel and quorum, and hashes recursively sorted question keys, including lexicographic ordering of integer-like definition keys. Routine allowlist rechecks preserve the current wallet’s draft and review; access errors disable creation until retried, and account/deployment changes or actual revocation reset the form. Closing-block warnings are estimates from the configured data chain’s current block and average interval.

No real wallet extension, physical mobile device or human screen reader was used in validation. Native browser 200% zoom and production DNS/IPFS publication were not tested. Public RPC availability and a compatible injected wallet remain external dependencies. Captured records prove the tested examples at their recorded blocks, not future availability or correctness of oracle judgments. See the validation report for exact coverage.

## Original contract documentation

The Solidity source now includes the two-collateral adaptation for the next Sepolia launch (after launch 1296, which added settler rewards); see [ADAPTATION.md](ADAPTATION.md) and, for agents and operators, [docs/AGENTS.md](docs/AGENTS.md). The website and export still target the earlier deployment and are intentionally unchanged. The new deployment uses Intake v2 and the constructor handoff in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

Verdict is an immutable parimutuel prediction market application for Sepolia (chain **11155111**). Creators fund oracle requests in IMD; bettors deposit the market's collateral token, IMD (slot 0) or WETH (slot 1), into outcome buckets; authenticated IdentityMD oracle answers establish a provisional outcome; a dispute window precedes settlement. The deployment set is exactly **VerdictBurnVault → VerdictOracle → VerdictMarkets**. There is no launch token, proxy, upgrade, or separate liquidity pool.

## Build and verification

```sh
forge build
forge test
forge fmt --check
```

The root `foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer 200 runs, via-IR, and `bytecode_hash = "none"`. No FFI, filesystem permissions, RPC, environment variables, or network are needed by the tests. All Solidity dependencies are vendored as ordinary files: OpenZeppelin Contracts **v5.5.0** and forge-std **v1.9.7**. The verifier supplies the pinned compiler; no compiler binary is included.

The suite includes the protocol's fixed EIP-712 digest/signature vector, independently encoded struct hash, domain/selector checks, exact Sepolia constructor rehearsal, adversarial callbacks, configuration rotation, all outcome types, deadline boundaries, entry controls, transfer-fee receipt accounting, reentrancy, actual token-transfer conservation, and a three-market stateful invariant. The invariant compares on-chain balances with each market's liabilities throughout randomized calls, then settles and drains every market. Independent review and reviewer-authored regressions are in [docs/INDEPENDENT_REVIEW.md](docs/INDEPENDENT_REVIEW.md) and [test/IndependentReview.t.sol](test/IndependentReview.t.sol).

The launch-1277 contracts are live on Sepolia. The website verification checked that earlier deployment's bytecode and ABI hashes, not this new adaptation; see [web/validation/contract-verification.json](web/validation/contract-verification.json). No wallet credentials were read and no transactions were broadcast by the website task. The original deployment procedure remains in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md); earlier contract test results are in [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Contracts

### VerdictBurnVault

An empty contract with no functions, owner, receive, fallback, or outgoing transfer path. ERC20 transfers to it succeed at the token contract and can never be recovered through the vault. It locks IMD without reducing the token's reported total supply. Plain ETH transfers and calls revert.

### VerdictOracle

`request(body)` is permissionless. It collects exactly the current price, approves that exact amount, calls `Intake.request` with callback `(this, 0x510379c7)`, and clears any remaining approval. Both incoming payment and Intake spending must be exact. It retains no request funds and has no sweep or arbitrary-call function.

Each returned Intake ID permanently reserves its replay key and stores `{bodyHash, intake, signer}`. A callback must come from that request's recorded Intake, carry an unexpired signature in **VerdictOracle's** EIP-712 domain, and use an oracle attestation UUID never stored before. The Intake request ID and attestation UUID are intentionally different IDs. The result contains `keccak256(abi.encode(a))` and the request body hash; the callback clears pending state, records `intakeRequestOf[attestationUUID]`, timestamps `lastDelivered`, and emits `Answered`. It does not decode outcomes or call Markets.

The canonical 15-field `OracleAttestation.Attestation` representation and consumer base are copied from the supplied protocol reference. Dynamic `answer` is hashed for EIP-712. Domain: `IdentityMD Oracle`, version `2`, current chain ID, verifying contract = VerdictOracle. Issued-at tolerance is five minutes. An inverted validity interval is rejected. Bodies must contain 1–16,384 bytes; callback answers are bounded to 16,384 bytes. A cold maximum-size answer callback through the mock Intake used **140,592 gas**, below the 150,000 target and 200,000 service stipend, with an EOA signer.

`answerOf(a)` returns the recorded body hash only for an exact attestation match. Delivery authenticates freshness once: stored results remain readable after expiry. Markets impose their own issued-at and proposal windows. No result can be edited or removed by the owner. The inherited optional `consumed` mapping is unused; `requested`, `pending`, and `results` implement Verdict's replay rules.

The owner can `proposeConfig(Config)` then `acceptConfig()` after the immutable delay, capped at 30 days. A new proposal replaces the pending proposal and restarts the delay. Config comprises Intake, asset, signer, action ID, and price; addresses/action/price must be nonzero. Ownership uses OpenZeppelin `Ownable2Step`. The configured launch delay is **zero**, so the two calls can occur immediately. Requests already paid retain their original Intake and signer through rotation. No cancellation, asset withdrawal, or callback override exists. The zero-delay owner can replace both Intake and signer immediately, and thereby control the truth of answers to future requests, including asks for markets with existing bets. Requests already paid retain their pinned authorities. Raising the price or changing the asset can also prevent future asks; bettor principal remains refundable under the timeout rules.

### VerdictMarkets

The oracle, treasury, burn sink, the two collateral slots (token, creator/burn/treasury fee rates and per-market pool cap each), and the maximum settler reward are immutable. `collateralConfig(slot)` and the per-slot fee and cap getters expose slot 0 and slot 1; any other slot reverts `InvalidCollateral`. The two tokens must differ and be nonzero, each slot's fees cannot exceed 500 bps, and each cap must be nonzero. Constructors perform no external calls and require no deployed dependency code. Every market bets in its slot's token; its bounty, oracle fees and settler rewards are in the oracle's asset (IMD), recorded at creation as the market's bounty token. WETH is a plain ERC-20 here: no native ETH, no `receive` or `fallback`.

The guardian may pause/unpause entry, add/remove creators, permanently disable the creator allowlist, propose a new guardian (who accepts), or renounce while unpaused with the allowlist disabled. It cannot move tokens, change terms, change outcomes, prevent asks/proposals/settlement/claims, or upgrade the application. Initially the allowlist is **on and empty**; the guardian must add creators or disable it. Renouncing with the allowlist still on reverts; disable it before relinquishing the guardian role.

## Market lifecycle

1. **Create.** An admitted creator calls `createMarket(p, body, escalationBody, uri, agentId)`, chooses `p.collateralId` (0 or 1; anything else reverts), and sets `settlerReward` no higher than `maxSettlerReward`. The bounty is pulled in the oracle's asset (IMD) whatever the slot. Both requested and actually received bounty must be at least `2 * oracle.price() + 5 * settlerReward`. The market stores the received bounty, terms, primary body hash, and optional escalation body hash. `MarketCreated` publishes both complete bodies, URI, creator, agent attribution and the collateral token. The URI and agent ID are event metadata, not authority: `agentId` is an unverified caller-supplied label. A nonempty escalation body must differ from the primary body.
2. **Bet.** Anyone calls `bet(id, outcome, amount, agentId)` before `closeAt` while entry is unpaused, paying in the market's collateral token. Credits use the actual balance increase. The slot's pool cap includes all credited bets, excludes bounty, and applies separately to each market. Bets cannot be withdrawn, transferred, or redirected before settlement.
3. **Ask.** Anyone calls `resolve(id, body)` during `[answerFrom, answerUntil)` while there is no provisional outcome. The exact published primary body is required. A second primary ask is available at least 24 hours after the first, only if that market's first request is still pending. Deliveries purchased by other callers or markets do not block this retry. A delivered but unusable answer still blocks retry under the specified no-delivery rule. There are at most **two bounty-funded asks total**, shared between primary retries and escalation.
4. **Propose.** Anyone submits the complete delivered attestation. The first proposal must authenticate against the primary body hash and the market's most recent recorded primary Intake request ID (after a retry, a late answer to the first ask is refused, so no proposer can choose between two answers). Question hash, answer type, data chain, and exact block window must match. The panel must meet `minPanelSize`, and agreement must meet `minAgreed` and signed quorum; quorum must be positive and agreement cannot exceed panel size. The signed `issuedAt` must be in the inclusive interval `[answerFrom, answerUntil]`. The first proposal is accepted from `answerFrom` until strictly before `voidAfter`, including after `answerUntil` for a timely signed answer. Direct purchases through VerdictOracle cannot establish an outcome; permissionless callers must trigger the market's `resolve` instead.
5. **Dispute.** A primary proposal starts its dispute window. Before it ends and before `answerUntil`, anyone may call `escalate(id, escalationBody)` once, spending one remaining ask and extending the window to at least 24 hours from that call. A matching escalation answer can replace the primary once, only inside the current window, and must have at least twice the current panel size. It starts one fresh full dispute window. A replacement must answer the market's recorded `escalate` request, so pre-bought answers cannot consume its dispute opportunity. Its issuance must be at or after that escalation ask and at or before the extended dispute deadline. Escalation delivery/replacement may occur after `answerUntil` or `voidAfter` while the current dispute window is still open. The replacement restarts the window only once, preserving finalization even past `voidAfter`.
6. **Finalize.** At or after the current dispute deadline, any caller can finalize a provisional market with a funded winning bucket, regardless of `voidAfter`. Separately rounded creator, burn, and treasury fees at the slot's rates are paid from the **entire pool** in the collateral token (a zero burn share sends nothing to the sink), and the bounty remaining after the finalizer reward returns to the creator in IMD. A missing escalation answer leaves the primary outcome in place.
7. **Claim or refund.** Winners call `claim(id)` once per address. Each receives `stake * (pool - fees) / winningPool`, rounded down; the last winning claimant receives the exact remaining payout. If no provisional outcome exists at `voidAfter`, anyone can void the market. A provisional outcome with no winning stake can be voided after its dispute window ends. Voiding charges no fees and returns the bounty remaining after the void caller's reward; every bettor then uses the same `claim(id)` to receive all their credited stakes across outcomes. A funded provisional winner cannot be timeout-voided.

Dispute duration is 1 hour through 3 days inclusive. Creation requires a future close and `closeAt <= answerFrom < answerUntil < voidAfter`. `minPanelSize >= 5`, `minAgreed > 0`, nonzero question/data-chain identifiers, and an ordered block interval are required. `minAgreed` may exceed `minPanelSize`; a larger actual panel can satisfy both. No maximum lifetime or minimum gap between `answerUntil` and `voidAfter` is imposed.

### Outcome definitions

| Type | Terms | Outcome |
| --- | --- | --- |
| `0` bool | No bounds or keys | `false → 0`, `true → 1` |
| `3` uint256 | 1–7 positive, strictly increasing bounds | Bucket `i` contains `bounds[i-1] <= value < bounds[i]`; first bucket starts at zero, last has no upper bound |
| `4` address[] | 1–7 unique keys, each fitting uint160 | Compare only the first address, encoded as `bytes32(uint256(uint160(address)))`, against keys |
| `5` bytes32[] | 1–7 unique keys | Compare only the first bytes32 against keys |

Lists use the final bucket for empty lists or an unmatched first element, even if a later element matches. Arrays with duplicate keys, unordered bounds, extraneous terms, or more than eight resulting outcomes are rejected. Answers use `abi.encode(value)`; malformed ABI cannot establish an outcome.

### Settler rewards

The constructor appends `maxSettlerReward` after `maxPoolPerMarket`; this launch sets it to 0.25 IMD. `Market` and `getMarket` expose `settlerReward` and cumulative `rewardsPaid`, and the immutable terms also include `params.settlerReward`.

Each successful resolve, each accepted first/replacement proposal, finalize, and void pays `msg.sender` from that market's bounty. Escalate earns no reward. Resolve/propose preserve `oracle.price() * (2 - asks)` using the current price after the action. If the reserve would be breached, the reward is clipped to the available surplus, possibly zero; already inadequate bounty does not cause reward arithmetic to revert. Finalize/void reserve nothing: they account for the reward, return the remainder, and transfer the reward before the creator payment, after all state changes.

`SettlerRewarded(id, settler, action, amount)` indexes the market and caller. Action codes are 0 resolve, 1 propose, 2 finalize, 3 void. A positive configured reward emits once per successful action even when clipped to zero. A configured reward of zero skips reward accounting, transfers, additional price reads, and reward events, preserving the previous behavior.

## Accounting and trust assumptions

For each completely claimed market:

```text
collateral token:  payouts + refunds + fees                     == creditedBetDeposits (pool)
bounty token (IMD): oracleSpend + rewardsPaid + returnedBounty  == creditedCreatorBounty
```

The two ledgers never mix, even when both are IMD. Each intermediate market liability is the right-hand side less completed outflows. Markets' IMD balance equals the sum of IMD pool liabilities and remaining bounties, and its WETH balance the sum of WETH pool liabilities, absent direct donations. Fees round down individually; rounding residue belongs to winners. Bounty is isolated from bettor principal. A later oracle price increase can make the remaining bounty insufficient, but cannot draw from the pool or another market. Changing the oracle asset away from a market's recorded bounty token blocks that market's asks (`OracleAssetMismatch`); existing results, settlement, bounty returns, and refunds remain usable.

IMD and WETH must remain transferable, non-rebasing ERC20s. Receipt measurement safely credits transfer-fee deposits, but oracle purchases require an exact payment and outgoing transfers are assumed to deliver their nominal amount. A paused, blocked, malicious, or rebasing collateral token is outside that operating assumption; failed transfers revert accounting atomically. There is no administrative rescue if a dependency stops operating.

The panel and signer are trusted for factual truth, and Intake is trusted to pair its request ID with the signed attestation UUID. The on-chain verifier authenticates the exact terms; it cannot judge evidence or repair a misleading creator body. Request bodies are opaque bytes on chain: creators must produce valid strict protocol JSON, use absolute confirmed block windows, select matching definitions/question hashes, use the VerdictOracle consumer domain, and configure appropriate panels/quorums. The UI must quote/escape untrusted user text before constructing oracle JSON. Relative windows, a wrong `consumer`, conflicting callbacks/delivery targets, or malformed JSON can spend the fee without producing a usable answer.

For list markets, the 16,384-byte callback answer limit includes the ABI encoding: at most 510 address/bytes32 entries (64 bytes of array overhead plus 32 bytes per entry). Markets uses only the first entry, but the entire answer must fit this cap. Oversize signed answers revert the one-shot callback and spend the fee. Creators must bound requested list output accordingly.

Primary issuance remains restricted to `[answerFrom, answerUntil]`, and new asks stop at `answerUntil`. A primary request paid immediately before that cutoff may return too late to be usable; no latency is guaranteed. Creators and keepers must leave response time before the cutoff. Primary proposals after `answerUntil` cannot initiate a new escalation ask, even if their dispute window remains open. This revision changes issuance timing for answers to an already-paid escalation only. A signature-valid primary delivery below the market's panel/agreement minima also prevents a second primary ask; principal can be refunded at `voidAfter`, but oracle spend is never refunded.

Oracle delivery is attempted once. A refused request, missing answer, expired result, invalid signature, or failed callback is not refunded. Failed callbacks leave a pending record but no funds in VerdictOracle; market timeout refunds provide economic recovery of principal, not already-spent oracle fees. Rotating a signer does not revoke its authority over requests that already pinned it. ERC-1271 signers are supported, but their own behavior determines signature validity and callback gas usage; the supplied signer is an EOA.

Direct token donations are outside deposit accounting and cannot be recovered. Unclaimed legitimate payouts stay available indefinitely; no-dust settlement assumes all entitled bettors claim. There is no automatic keeper: creators or independent callers must ask, propose, settle, and claim. Progressing a market earns its configured bounty-funded reward; claims and escalation are unrewarded. Caps and panel minima limit the application mechanically; they do not guarantee truthful answers.

## Files and responsibilities

- `src/`: the three applications, canonical attestation representation, and minimal interfaces.
- `test/`: success/failure, conformance, invariant, factory rehearsal, and independent review regressions. Mock tokens are test-only.
- `script/SepoliaParameters.sol`: exact static constructor argument encoding for the launch service/rehearsal; no deployment or wallet logic.
- `docs/DEPLOYMENT.md`: launch order, full parameters, initial operations, and post-launch verification.
- `docs/AGENTS.md`, `docs/agents/`: guide, ABIs and addresses file for AI agents and operators.
- `docs/COLLATERAL_INDEPENDENT_REVIEW.md`: review of the two-collateral adaptation.
- `docs/INDEPENDENT_REVIEW.md`: original review; superseded source hashes are identified there.
- `docs/REVISION_REVIEW.md`: review and decisions for this bounded revision.
- `.imd-responses.json`: response to every reopened finding.
- `DEPENDENCIES.md`: vendored dependency provenance and licenses.

The separate launch manifest/final review/deployment stages own publication and live deployment. The oracle owner owns future configuration and ownership transfers. The guardian owns creator admission and entry controls. Creators own body quality and parameter selection. Anyone can perform settlement operations; each bettor claims their own funds. Website work follows separately and must use the confirmed deployment handoff addresses.
