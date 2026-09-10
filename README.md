<p align="center">
  <img src="./ponstaking.jpg" alt="Pons V2 Ponstaking" width="180">
</p>

<h1 align="center">Pons V2 — Ponstaking</h1>

<p align="center">
  <strong>Experimental staking infrastructure for the Pons ecosystem</strong>
</p>

<p align="center">
  <code>STAKE → ACCRUE → COMPOUND → CLAIM</code>
</p>

<br>

<p align="center">
  <img src="./assets/ponstaking-flow.gif" alt="Ponstaking execution flow" width="900">
</p>

---

## Overview

**Ponstaking** is an experimental staking mode being developed for the Pons ecosystem.

The initial implementation introduces a standalone staking engine where users can deposit a supported token, maintain a proportional position in the staking pool, and continuously accrue rewards funded by the **Ponstaking tax mechanism**.

The first asset used throughout this implementation is:

> **Testing Asset — Ponstaking (`$PONSTAKE`)**

`$PONSTAKE` is used exclusively as the reference testing token for the current development phase.

The architecture is intentionally designed so that the staking engine can later be extended beyond the test asset and made available across **all eligible token pairs launched through Pons**.

```text
                         PONS ECOSYSTEM
                               │
                               ▼
                    ┌─────────────────────┐
                    │     PONSTAKING      │
                    │                     │
                    │  Staking Engine     │
                    │  Reward Accounting  │
                    │  Reward Emissions   │
                    └──────────┬──────────┘
                               │
                    ┌──────────┴──────────┐
                    │                     │
                    ▼                     ▼
              $PONSTAKE             FUTURE PAIRS
             TESTING ASSET          PONS LAUNCHES
```

---

## Status

| Component                  | Status                   |
| -------------------------- | ------------------------ |
| Staking engine             | Experimental             |
| Reward accounting          | Implemented              |
| Reward funding             | Implemented              |
| Compounding                | Implemented              |
| Emergency withdrawal       | Implemented              |
| Pause mechanism            | Implemented              |
| `$PONSTAKE` testing asset  | Reference implementation |
| Ponstaking tax integration | Under development        |
| Multi-pair support         | Planned                  |
| Production integration     | Not integrated           |
| Security audit             | Not audited              |

> **Important:** This implementation is experimental infrastructure intended for testing and protocol development. It should not be treated as production-ready financial infrastructure.

---

# 01 — Design Objective

Ponstaking is designed around a simple mechanism:

```text
                     PONSTAKING TAX
                           │
                           ▼
                    REWARD FUNDING
                           │
                           ▼
                    STAKING CONTRACT
                           │
              ┌────────────┴────────────┐
              │                         │
              ▼                         ▼
           STAKERS                  REWARD RATE
              │                         │
              └────────────┬────────────┘
                           ▼
                    PONS DISTRIBUTION
```

The fundamental objective is to create a reusable staking layer where protocol-generated tax revenue can be redirected into a reward pool.

Users contribute liquidity to the staking pool by locking their supported tokens.

The reward engine then distributes funded rewards according to:

* amount staked;
* time staked;
* active reward rate;
* available reward funding.

No fixed APY is promised by the contract.

The displayed APY is instead derived from the **actual emission rate relative to the current staking balance**.

---

# 02 — The Core Model

Ponstaking uses a continuous reward accumulator.

For every staked token, the protocol tracks a value called:

```text
rewardPerTokenStored
```

Conceptually:

```text
             REWARD EMISSION
                    │
                    ▼
          ┌───────────────────┐
          │ rewardPerToken    │
          │     accumulator   │
          └─────────┬─────────┘
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
      USER A      USER B      USER C
        │           │           │
        ▼           ▼           ▼
     earned()    earned()    earned()
```

This avoids maintaining individual timers for every user.

Instead, the global reward accumulator advances as rewards are emitted.

Each user's position records the accumulator value already accounted for.

The difference between the current accumulator and the user's previous accumulator determines the newly accrued reward.

---

# 03 — Execution Lifecycle

The complete lifecycle is:

```text
┌─────────────┐
│    STAKE    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   ACCRUE    │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   CLAIM     │
└──────┬──────┘
       │
       ├───────────────┐
       │               │
       ▼               ▼
   WITHDRAW         COMPOUND
                       │
                       ▼
                    STAKE
```

A user can therefore choose between:

**Claim**

```text
Stake
  ↓
Accrue
  ↓
Claim PONSTAKE
```

or:

**Compound**

```text
Stake
  ↓
Accrue
  ↓
Convert reward → additional stake
  ↓
Larger position
  ↓
Higher future reward exposure
```

---

# 04 — Automated Execution Sequence

<p align="center">
  <img src="./assets/ponstaking-execution.gif" alt="Ponstaking execution sequence" width="900">
</p>

The staking engine operates through a predictable sequence.

### Step 1 — User deposits

The user approves the staking contract and calls:

```solidity
stake(amount)
```

The contract:

1. updates the user's reward accounting;
2. increases `balanceOf[user]`;
3. increases `totalStaked`;
4. transfers the tokens into the staking contract.

---

### Step 2 — Rewards accumulate

As time passes, the reward engine calculates:

```text
elapsed time
       ×
reward rate
       ÷
total staked
```

This determines how much reward has accrued per staked token.

---

### Step 3 — User interacts

When the user calls:

```solidity
withdraw()
getReward()
compound()
exit()
```

the contract first updates the user's reward state.

This prevents reward accounting from becoming dependent on how frequently the user interacts with the protocol.

---

# 05 — Reward Funding

Ponstaking rewards are not created out of thin air.

The staking pool must be funded.

The intended future model is:

```text
PONS LAUNCH
     │
     ▼
PONSTAKING TAX
     │
     ▼
REWARD DISTRIBUTOR
     │
     ▼
PONSTAKING CONTRACT
     │
     ▼
STAKERS
```

During the current testing phase, the reward distributor can directly fund the contract through:

```solidity
notifyRewardAmount(amount, duration)
```

The contract then calculates a new emission rate.

---

# 06 — Reward Rate

The reward rate is denominated in:

```text
PONSTAKE / second
```

For a reward allocation:

```text
R = total reward tokens
D = reward duration

rewardRate = R / D
```

For example:

```text
Reward allocation: 300,000 PONSTAKE
Duration:           30 days

rewardRate ≈ 0.1157 PONSTAKE / second
```

The actual distribution per user then depends on their proportional share of the staking pool.

---

# 07 — APY Model

Ponstaking does **not** hardcode a permanent APY.

The contract exposes:

```solidity
estimatedAPY()
```

which provides an annualized estimate based on the current reward emission rate and current total stake.

Conceptually:

```text
                rewardRate × 365 days
APY ≈ ─────────────────────────────────────
                    totalStaked
```

This means APY naturally changes with the pool.

### If staking participation increases

```text
TVL ↑
rewardRate = constant

APY ↓
```

### If staking participation decreases

```text
TVL ↓
rewardRate = constant

APY ↑
```

This creates a dynamic emission system rather than a fictional guaranteed yield.

---

# 08 — Testing With `$PONSTAKE`

The entire current implementation is documented around:

```text
Ponstaking
$PONSTAKE
```

`$PONSTAKE` acts as the **testing reference asset** for:

* staking;
* reward funding;
* reward accounting;
* APY calculations;
* compounding;
* withdrawals;
* emergency withdrawals;
* protocol demonstrations;
* integration testing.

The testing asset is intentionally isolated from the production Pons token architecture.

```text
                 TESTING PHASE

             ┌──────────────────┐
             │     $PONSTAKE    │
             │                  │
             │  Stake           │
             │  Earn            │
             │  Compound        │
             │  Withdraw        │
             └────────┬─────────┘
                      │
                      ▼
               PONSTAKING ENGINE
```

---

# 09 — Future Multi-Pair Architecture

The long-term objective is to move beyond `$PONSTAKE`.

The staking architecture is being developed toward a model where **eligible pairs launched through Pons can eventually have their own Ponstaking market**.

Conceptually:

```text
                         PONS
                          │
             ┌────────────┼────────────┐
             │            │            │
             ▼            ▼            ▼
          PAIR A        PAIR B        PAIR C
             │            │            │
             ▼            ▼            ▼
        PONSTAKING    PONSTAKING    PONSTAKING
             │            │            │
             └────────────┼────────────┘
                          │
                          ▼
                   REWARD SYSTEM
```

The exact production architecture may ultimately use:

* pair-specific staking contracts;
* a shared rewards controller;
* Pons fee infrastructure;
* dedicated reward distributors;
* factory-created staking pools;
* or another standardized routing layer.

The current standalone implementation intentionally does not assume which architecture will be selected.

---

# 10 — Position Accounting

Each staker has three fundamental values:

```solidity
balanceOf[user]
rewards[user]
userRewardPerTokenPaid[user]
```

These represent:

| Variable                 | Meaning                                                  |
| ------------------------ | -------------------------------------------------------- |
| `balanceOf`              | Current amount staked                                    |
| `rewards`                | Previously accrued but unclaimed rewards                 |
| `userRewardPerTokenPaid` | Last global reward accumulator accounted for by the user |

A user's total economic position can therefore be represented as:

```text
                 USER POSITION
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
      STAKED TOKENS            PENDING REWARDS
          │                         │
          └────────────┬────────────┘
                       ▼
                  TOTAL POSITION
```

---

# 11 — Reward Calculation

For an account:

```text
earned(account)
```

is conceptually calculated as:

```text
user stake
    ×
(current rewardPerToken - user's paid rewardPerToken)
    +
previously accrued rewards
```

The implementation uses `PRECISION = 1e18` to maintain high-resolution accounting.

This allows fractional reward accrual without requiring floating-point arithmetic.

Solidity itself does not support floating-point numbers, so all calculations are performed using integer arithmetic with fixed-point scaling.

---

# 12 — Compounding

Because the staking asset and reward asset are the same token, Ponstaking can compound without an external swap.

```text
                 ACCRUED REWARD
                       │
                       ▼
              ┌────────────────┐
              │   COMPOUND()   │
              └───────┬────────┘
                      │
                      ▼
               ADD TO STAKE
                      │
                      ▼
                LARGER POSITION
                      │
                      ▼
               MORE REWARD SHARE
```

When `compound()` is called:

```text
rewards[user] → 0
balanceOf[user] += rewards[user]
totalStaked += rewards[user]
```

No additional approval is required.

No external router is involved.

No market transaction is required.

---

# 13 — Reward Period Rollover

Ponstaking supports funding a new reward period while a previous period is still active.

Any undistributed rewards from the previous period are carried forward.

```text
CURRENT PERIOD
██████████████████░░░░░░
                  │
                  │ remaining rewards
                  ▼
NEW FUNDING ──────────────┐
                          ▼
                ┌─────────────────┐
                │ NEW REWARD RATE │
                └─────────────────┘
```

Conceptually:

```text
new allocation
      +
undistributed previous allocation
      =
new emission pool
```

This prevents active reward allocations from being accidentally abandoned when a new funding cycle begins.

---

# 14 — Security Architecture

Ponstaking uses several established defensive mechanisms.

### Reentrancy protection

State-changing external functions use:

```solidity
nonReentrant
```

This protects the staking, withdrawal, reward and funding flows against reentrant execution.

---

### Checks-effects-interactions

State is updated before external token transfers wherever applicable.

This reduces the risk associated with external contract execution.

---

### Safe ERC20 operations

All token transfers use OpenZeppelin:

```solidity
SafeERC20
```

instead of assuming non-standard ERC20 return behavior.

---

### Two-step ownership

Administration uses:

```solidity
Ownable2Step
```

reducing the risk of accidentally transferring ownership to an incorrect address.

---

### Protected reward funding

Only:

```text
rewardDistributor
        OR
      owner
```

can create new reward emissions.

---

# 15 — Emergency Withdrawal

The protocol includes:

```solidity
emergencyWithdraw()
```

This function allows a user to recover their principal without claiming pending rewards.

The trade-off is explicit:

```text
EMERGENCY WITHDRAW
        │
        ├── Stake returned
        │
        └── Pending rewards forfeited
```

This is intentionally different from:

```solidity
exit()
```

which withdraws the stake **and** claims accrued rewards.

---

# 16 — Pause Mechanism

The owner can pause new staking operations.

When paused:

```text
stake()       ✕
compound()    ✕
```

Existing positions remain recoverable through:

```text
withdraw()    ✓
getReward()   ✓
emergencyWithdraw() ✓
```

This provides an operational safety mechanism without completely freezing user access to deposited capital.

---

# 17 — Administrative Controls

The contract intentionally keeps administration limited.

### Reward distributor

```solidity
setRewardDistributor(address)
```

Changes the address responsible for funding reward periods.

### Pause

```solidity
pause()
```

Temporarily prevents new staking and compounding.

### Unpause

```solidity
unpause()
```

Restores normal operation.

### Recovery

```solidity
recoverERC20(token, amount)
```

allows recovery of unrelated ERC20 tokens accidentally sent to the contract.

The staking token itself cannot be recovered through this mechanism.

---

# 18 — Contract Interface

### User operations

```solidity
stake(uint256 amount)
withdraw(uint256 amount)
getReward()
compound()
exit()
emergencyWithdraw()
```

### Reward operations

```solidity
notifyRewardAmount(uint256 amount)
notifyRewardAmount(uint256 amount, uint256 duration)
```

### Read operations

```solidity
earned(address account)
rewardPerToken()
estimatedAPY()
position(address account)
rewardBalance()
remainingRewardAllocation()
rewardPeriodActive()
configuration()
```

### Administration

```solidity
setRewardDistributor(address)
pause()
unpause()
recoverERC20(address, uint256)
```

---

# 19 — Event Architecture

All major state transitions emit explicit events.

```solidity
Staked(...)
Withdrawn(...)
RewardPaid(...)
RewardAdded(...)
RewardDistributorUpdated(...)
Recovered(...)
```

This provides an event-level history of:

```text
DEPOSIT
   ↓
REWARD ACCRUAL
   ↓
CLAIM / COMPOUND
   ↓
WITHDRAWAL
```

and makes the system suitable for indexing by future Pons infrastructure or external analytics systems.

---

# 20 — Protocol Accounting

<p align="center">
  <img src="./assets/ponstaking-accounting.gif" alt="Ponstaking accounting" width="900">
</p>

The contract maintains protocol-level statistics including:

```text
totalStaked
totalRewardsFunded
totalRewardsPaid
rewardRate
periodFinish
execution state
```

These values allow external interfaces to derive:

* current TVL;
* active emission rate;
* reward period status;
* historical reward funding;
* total distributed rewards;
* estimated annualized yield.

---

# 21 — Testing Model

The intended initial testing environment is deliberately aggressive.

Large reward allocations can be used to stress-test:

```text
High APY
High TVL
Low TVL
Rapid deposits
Rapid withdrawals
Compounding
Reward rollover
Reward exhaustion
Emergency withdrawals
Pause / unpause
```

A representative test cycle:

```text
1. Deploy $PONSTAKE
        ↓
2. Deploy PonsV2Staking
        ↓
3. Configure reward distributor
        ↓
4. Fund reward period
        ↓
5. User A stakes
        ↓
6. User B stakes
        ↓
7. Rewards accrue
        ↓
8. User A claims
        ↓
9. User B compounds
        ↓
10. User A withdraws
        ↓
11. New reward period begins
        ↓
12. Verify accounting invariants
```

---

# 22 — Recommended Invariants

Testing should verify the following properties.

### Principal conservation

Ignoring reward distributions:

```text
total deposited
-
total withdrawn
=
totalStaked
```

### Reward conservation

The system should never distribute more reward tokens than are available to fund the corresponding reward allocation.

### Position conservation

For each account:

```text
stake
+
accrued reward
=
economic position
```

subject to claims, withdrawals and compounding.

### No unauthorized funding

Only the configured reward distributor or owner can create reward periods.

### No staking-token recovery

The administrative recovery function must never be able to extract user principal or reward inventory.

---

# 23 — Failure Semantics

Ponstaking intentionally fails closed when invalid conditions occur.

Examples:

```text
stake(0)
        ↓
REVERT

withdraw(0)
        ↓
REVERT

withdraw(> balance)
        ↓
REVERT

reward funding = 0
        ↓
REVERT

invalid reward duration
        ↓
REVERT

unauthorized distributor
        ↓
REVERT
```

This keeps invalid state transitions explicit rather than silently ignoring them.

---

# 24 — Economic Model

Ponstaking is designed around a simple economic loop:

```text
             PONS ACTIVITY
                   │
                   ▼
             TAX REVENUE
                   │
                   ▼
             REWARD POOL
                   │
                   ▼
                STAKERS
                   │
                   ▼
          LONGER TOKEN HOLDING
                   │
                   ▼
          GREATER STAKING TVL
```

The eventual production implementation can determine exactly which Pons fees qualify for staking rewards and how those fees are routed.

The current contract intentionally isolates the reward engine from that decision.

---

# 25 — Why The Reward Engine Is Standalone

The current implementation deliberately separates:

```text
FEE GENERATION
```

from:

```text
REWARD DISTRIBUTION
```

This creates a clean architectural boundary.

```text
┌──────────────────────┐
│    PONS V2 SYSTEM    │
│                      │
│ Launch / Fees / Tax  │
└──────────┬───────────┘
           │
           │ future adapter
           ▼
┌──────────────────────┐
│   REWARD DISTRIBUTOR │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│    PONSTAKING        │
│                      │
│  Staking + Rewards   │
└──────────────────────┘
```

This allows the staking engine to be tested independently before the final Pons V2 integration architecture is selected.

---

# 26 — Current vs Future Architecture

| Capability            |  Current Prototype | Future Direction |
| --------------------- | -----------------: | ---------------: |
| `$PONSTAKE` staking   |                  ✓ |                ✓ |
| PONSTAKE rewards      |                  ✓ |                ✓ |
| Dynamic reward rate   |                  ✓ |                ✓ |
| Compounding           |                  ✓ |                ✓ |
| Emergency withdrawal  |                  ✓ |                ✓ |
| Reward funding        | Manual distributor |    Pons tax flow |
| Single asset          |                  ✓ |       Multi-pair |
| Pons V2 integration   |                  — |          Planned |
| Automated tax routing |                  — |          Planned |
| Factory deployment    |                  — |          Planned |
| Production deployment |                  — |          Planned |

---

# 27 — Future: Staking Across Pons

The long-term vision is for Ponstaking to become a reusable staking primitive within the Pons launch ecosystem.

Instead of:

```text
ONE TOKEN
    ↓
ONE STAKING POOL
```

the architecture can evolve toward:

```text
                         PONS
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
        ▼                 ▼                 ▼
     TOKEN A           TOKEN B           TOKEN C
        │                 │                 │
        ▼                 ▼                 ▼
      POOL A             POOL B             POOL C
        │                 │                 │
        └─────────────────┼─────────────────┘
                          ▼
                   PONSTAKING LAYER
```

Each eligible Pons launch could eventually expose staking functionality without requiring the token creator to implement an independent staking system.

This is the direction the current architecture is designed to explore.

---

# 28 — Design Principles

Ponstaking follows several principles.

### Minimal custody surface

The contract should only hold assets required for:

```text
user principal
+
funded rewards
```

### Deterministic accounting

Reward calculations are based on deterministic on-chain state.

### Explicit funding

Rewards must be funded before they can be distributed.

### No artificial APY

The protocol does not pretend that an APY is guaranteed.

### Modular integration

The staking engine remains independent from the current Pons V2 fee implementation.

### Test first

The first deployment is designed to aggressively test the economics and mechanics before production integration.

---

# 29 — What This Contract Does Not Do

The current prototype does **not**:

* modify the existing Pons V2 contracts;
* automatically collect production Pons taxes;
* create staking pools for every Pons launch;
* guarantee any APY;
* provide price protection;
* perform token swaps;
* determine token eligibility;
* provide a production governance system;
* constitute an audited production deployment.

These responsibilities belong to future integration layers.

---

# 30 — Production Integration Boundary

The current implementation ends at:

```text
REWARD FUNDING
       │
       ▼
PONSTAKING
       │
       ▼
STAKER REWARDS
```

Future Pons integration begins at:

```text
PONS V2
   │
   ▼
TAX / FEE SYSTEM
   │
   ▼
REWARD ROUTING
   │
   ▼
PONSTAKING
```

This boundary is intentional.

It allows the reward engine to be tested and reviewed independently before it becomes coupled to production Pons infrastructure.

---

# 31 — Repository Structure

Recommended structure:

```text
contracts/
└── staking/
    └── PonsV2Staking.sol

test/
└── staking/
    └── PonsV2Staking.t.sol

assets/
├── ponstaking-flow.gif
├── ponstaking-execution.gif
└── ponstaking-accounting.gif

README.md
```

The visual assets are intentionally separated from the Solidity implementation so the documentation layer can evolve independently.

---

# 32 — Deployment Configuration

Example deployment parameters:

```text
stakingToken:
    $PONSTAKE

rewardDistributor:
    <TEST REWARD DISTRIBUTOR>

initialOwner:
    <TEST OWNER>
```

Example test configuration:

```text
Reward Asset:
    $PONSTAKE

Reward Duration:
    30 days

Funding:
    Controlled by testing distributor

APY:
    Dynamic

Environment:
    Experimental
```

---

# 33 — Example Economic Scenario

Assume:

```text
Total staked:
1,000,000 PONSTAKE

Reward allocation:
250,000 PONSTAKE

Duration:
30 days
```

The reward engine distributes approximately:

```text
250,000 / 30 days
```

across the active staking pool.

If one user controls:

```text
10%
```

of the total stake for the entire period, they receive approximately:

```text
10% × 250,000

= 25,000 PONSTAKE
```

before accounting for changes in pool participation.

If another user compounds their rewards, their stake increases and therefore their future proportional share changes as well.

---

# 34 — Operational State

The protocol can be viewed as a finite execution system:

```text
                 ┌───────────────┐
                 │    DEPLOYED   │
                 └───────┬───────┘
                         │
                         ▼
                 ┌───────────────┐
                 │    FUNDED     │
                 └───────┬───────┘
                         │
                         ▼
                 ┌───────────────┐
                 │    ACTIVE     │
                 └───────┬───────┘
                         │
               ┌─────────┴─────────┐
               ▼                   ▼
          USER ACTIONS        PERIOD END
               │                   │
       ┌───────┼───────┐           ▼
       ▼       ▼       ▼      NEW FUNDING
     STAKE   CLAIM  COMPOUND       │
       │       │       │           │
       └───────┴───────┘           │
                                   ▼
                                ACTIVE
```

The contract does not require an explicit `ACTIVE` state variable.

The state is derived from:

```solidity
periodFinish
rewardRate
totalStaked
```

---

# 35 — Testing Philosophy

The purpose of this phase is not simply to demonstrate that:

```text
stake()
```

works.

The objective is to stress the complete economic machine.

Testing should progressively increase:

```text
                    COMPLEXITY
                       ▲
                       │
              ┌────────┴────────┐
              │ Multi-user      │
              │ interactions    │
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ Compounding     │
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ Reward rollover │
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ Withdrawals     │
              └────────┬────────┘
                       │
              ┌────────┴────────┐
              │ Basic staking   │
              └─────────────────┘
```

The test asset `$PONSTAKE` exists specifically to make these scenarios easy to reproduce.

---

# 36 — Implementation Status

```text
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  PONSTAKING                                             │
│                                                         │
│  ████████████████████████░░░░░░░░░░░░░░░░             │
│                                                         │
│  EXPERIMENTAL IMPLEMENTATION                            │
│                                                         │
│  Staking Engine             IMPLEMENTED                │
│  Reward Engine              IMPLEMENTED                │
│  Compounding                IMPLEMENTED                │
│  Emergency Controls         IMPLEMENTED                │
│  Test Asset                 $PONSTAKE                  │
│                                                         │
│  Pons Tax Integration       IN DEVELOPMENT              │
│  Multi-Pair Support         PLANNED                    │
│  Production Integration     NOT YET IMPLEMENTED        │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

# 37 — Final Architecture

The complete long-term concept can be summarized as:

<p align="center">
  <img src="./assets/ponstaking-flow.gif" alt="Ponstaking protocol flow" width="900">
</p>

```text
                         PONS
                          │
                          ▼
                   LAUNCH ACTIVITY
                          │
                          ▼
                   PONSTAKING TAX
                          │
                          ▼
                  REWARD DISTRIBUTOR
                          │
                          ▼
                ┌─────────────────────┐
                │     PONSTAKING      │
                │                     │
                │  Reward Accounting  │
                │  Emission Engine    │
                │  User Positions     │
                └──────────┬──────────┘
                           │
                 ┌─────────┴─────────┐
                 ▼                   ▼
              STAKERS             REWARDS
                 │                   │
                 └─────────┬─────────┘
                           ▼
                       COMPOUND
                           │
                           ▼
                    LONG-TERM STAKE
```

The current implementation uses **`$PONSTAKE` as the exclusive testing reference asset**.

The intended future direction is to generalize the mechanism so that **eligible token pairs launched through Pons can participate in the Ponstaking ecosystem**, with the final fee-routing and pool architecture determined during the integration phase.

---

# 38 — Summary

**Ponstaking** is an experimental staking layer designed around a simple protocol primitive:

```text
TAX REVENUE
     ↓
REWARD FUNDING
     ↓
STAKING
     ↓
REWARD ACCRUAL
     ↓
CLAIM / COMPOUND
```

The current standalone contract provides the underlying staking and reward accounting engine.

`$PONSTAKE` is the testing asset used throughout this development phase.

The next architectural layer is the connection between **Pons V2 tax generation** and the Ponstaking reward distributor.

The longer-term objective is to make the staking mechanism reusable across **Pons-launched pairs**, turning Ponstaking from an isolated testing contract into a standardized staking primitive for the broader Pons ecosystem.

---

## License

This implementation is released under the **MIT License**.

---

<p align="center">
  <sub>
    Pons V2 · Ponstaking · Experimental Protocol Infrastructure
  </sub>
</p>
