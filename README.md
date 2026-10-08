## DGRID Project Documentation

### Overview

DGRID is a decentralized smart AI network built on BNB Smart Chain (BSC) and other EVM-compatible networks.

The current contracts cover:

- USDT-based node NFT purchases with server-signed orders
- Referral commission accounting
- Transfer-gated node NFTs with staking and jail states
- Node NFT staking with multi-token rewards
- DGAI staking by node and lock tier
- User top-ups with BNB, stablecoins, or configured tDGAI
- tDGAI TWAP pricing through PancakeSwap V3
- AI Arena winner upload and reward claiming

### Contracts

- `contracts/Dgrid.sol`: USDT node purchase, referral commission, node NFT minting, pause and emergency controls
- `contracts/DgridNode.sol`: ERC-721 node NFT with public-transfer gating and staked/jailed flags
- `contracts/DgridStakePool.sol`: node NFT staking, reward harvesting, tDGAI accounting, pre-claim flow, and DGAI reward restaking
- `contracts/DGAIStaking.sol`: DGAI staking by node and lock tier, unstake cooling, reward claiming, node commission, and jail controls
- `contracts/DgridTopUp.sol`: user top-ups paid with BNB, supported stablecoins, or configured tDGAI
- `contracts/DgridPriceFeed.sol`: PancakeSwap V3 TWAP adapter for tDGAI pricing
- `contracts/ChainlinkPriceFeed.sol`: Chainlink price adapter with cache, heartbeat, deviation guard, and 18-decimal scaling
- `contracts/DgridAIArena.sol`: user activation, server-uploaded winners, and multi-token reward claims
- `contracts/DGAI.sol`: capped mintable DGAI ERC-20
- `contracts/Proxy.sol`: OpenZeppelin transparent proxy imports for deployment

### Roles

- Owner: configures protocol parameters, assets, rewards, oracles, pause state, and emergency operations
- Server: signs or operates purchase orders, staking actions, pre-stake validation, jail/unjail actions, and AI Arena winners
- Dev: receives node purchase proceeds and top-up funds
- Treasury: source wallet for server-authorized DGAI pre-stake transfers
- User: buys nodes, stakes NFTs or DGAI, tops up, joins AI Arena, and claims rewards
- Referrer: receives node purchase commission

### Main Flows

#### Node Purchase (`Dgrid`)

- `buyNode(...)` currently supports purchases with the configured `usdt` token only.
- Server signature includes `chainId`, `address(this)`, `usdt`, order data, `nodePrice`, and `gasAmountPerNode`.
- Payment amount is:

```solidity
nodePrice * nodeCount * 1e18 + gasAmountPerNode * nodeCount * 1e18
```

- Referral commission is calculated from the node-price portion only.
- The net amount is transferred to `dev`; commission stays claimable for the referrer.
- Node NFTs are minted sequentially to the target user.

#### Node NFT Staking (`DgridStakePool`)

- Users stake owned `DgridNode` NFTs with a server-signed `deposit(...)`.
- Rewards accrue per block across configured reward tokens.
- Users can `harvest()` available rewards.
- Unstake is controlled by `unstakeEnabled`.
- Server can jail nodes; users can unjail with a server signature.
- DGAI rewards can be restaked into `DGAIStaking`.

#### DGAI Staking (`DGAIStaking`)

- Owner creates staking nodes.
- Users stake DGAI into a selected node and lock tier.
- Lock tiers use configurable fixed rates for reward weight.
- Users can claim rewards, restake rewards, change nodes, and request unstake.
- Unstaked principal is released after the lock-tier cooling period.
- Node owners can claim node commission.
- Emergency withdrawal is limited to surplus DGAI above user principal.

#### Top-Up (`DgridTopUp`)

- BNB top-ups use `ChainlinkPriceFeed.fetchPrice(address(0))`.
- Stablecoin top-ups are normalized by token decimals.
- tDGAI top-ups use `DgridPriceFeed.getTDGAITwapPrice18()`.
- `userTopUpAmount[user]` stores cumulative 18-decimal USD value.

#### AI Arena (`DgridAIArena`)

- Users call `activate()` once before receiving rewards.
- Server uploads winners by round with supported reward tokens.
- Users claim rewards with `claimReward()`.
- `getShortfall(token)` reports reward-token funding gaps.

### Pricing

- `ChainlinkPriceFeed` handles external asset prices such as BNB.
- `DgridPriceFeed` reads PancakeSwap V3 observations to calculate tDGAI TWAP.
- Prices are returned in 18 decimals.

### Admin Notes

- Call `Dgrid.initializeV2(usdt)` before node purchases.
- Configure the native BNB Chainlink feed as `asset == address(0)` before BNB top-ups.
- Configure `DgridTopUp.setTDGAI(...)` and `setTDGridPriceFeed(...)` before tDGAI top-ups.
- `DGAIStaking` starts paused after initialization and must be unpaused before user staking.
- `DgridNode` transfers are blocked while public transfers are disabled, or while a token is staked or jailed.
- Anyone can call `Dgrid.claimCommission(user, assets[])`; funds are sent to `user`.

### Development

Install dependencies:

```bash
npm install
```

Compile:

```bash
npx hardhat compile
```

### Audit

See `audits/**.pdf`.
