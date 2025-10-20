## DGRID Project Documentation (English)

### Overview

DGRID is an upgradeable on-chain commerce module for selling ERC-721 “nodes” with:

- Multi-asset payment (native token or ERC-20) via Chainlink price conversion
- Automated referral commissions
- Per-order pricing and configurable lock-amount per node
- Transfer-gated NFTs, plus a staking pool with multi-reward support

Core contracts:

- `contracts/Dgrid.sol`: purchase, pricing, commission, minting, lock transfer, pause/emergency
- `contracts/DgridNode.sol`: ERC-721 node NFT with transfer gating and stake/jail flags
- `contracts/DgridStakePool.sol`: staking for node NFTs with multi reward tokens
- `contracts/DgridLock.sol`: lock vault receiving the locked portion of payments
- `contracts/ChainlinkPriceFeed.sol`: oracle adapter (cache, heartbeat, deviation guard)

### Roles

- Owner: config/admin (prices, feeds, assets, params, pause)
- Server: authorized signer for orders and staking operations
- Dev: receives net payment after commission and lock
- DgridLock Operator: withdraws locked funds per policy
- User: purchaser and/or recipient; Referrer (parent) accrues commission

### Key Features

- Server-signed order: `(chainId, orderId, user, parent, nodeCount, expireTime)` with EIP-191 signature
- Pricing and lock:
  - `nodePrice`: price per node in 18 decimals
  - `lockAmountPerNode`: lock portion per node in 18 decimals
  - `calculatePaymentAmount(nodeCount)` = `nodePrice * nodeCount * 1e18`
  - `calculateLockAmount(nodeCount)` = `lockAmountPerNode * nodeCount * 1e18`
- Commission: `(paidAmount * commissionRate) / 100` credited to `commission[parent][asset]`
- Payments:
  - Native: convert with `fetchPrice(address(0))`; refund excess `msg.value`
  - ERC-20: allowance check + `safeTransferFrom`, using token decimals
- Lock routing: lock portion → `dgridLock`; net proceeds → `dev`
- ERC-721 minting: mints sequential `NODE_ID` to `user`; transfers disabled by default
- Staking pool: stake/unstake with per-block multi-token rewards; server-signed deposit; jail/unjail controls

### Purchase Flow

1. Off-chain: `server` signs payload `abi.encode(chainId, orderId, user, parent, nodeCount, expireTime)` and EIP-191 wrap.
2. On-chain: call `buyNode(orderId, user, parent, nodeCount, expireTime, signature, asset)`:
   - Validates signature, `expireTime`, asset allowlist, and unique `orderId`
   - Computes payment + lock, converts via `ChainlinkPriceFeed.fetchPrice`
   - Handles commission, lock transfer to `dgridLock`, net to `dev`, refund (if native)
   - Mints `nodeCount` NFTs to `user`
   - Emits `Locked` and `BuyNode`

### Staking Flow (DgridStakePool)

- Server-signed deposit: `abi.encode(chainId, nodeIds, staker, expireTime)`
- `deposit(nodeIds, staker, expireTime, signature)`: stakes NFTs, updates rewards accrual
- Rewards:
  - Multiple `rewardToken` entries with `rewardPerBlock`
  - `pendingRewards(user)` and `harvest()` to claim
- Moderation:
  - `jailNodes([{owner, tokenIds}, ...])` by `server` reduces stake and marks jailed
  - `unjailNodes(nodeIds, owner)` restores stake after checks
- Pausable; emergency withdraw for reward tokens when paused

### Oracle and Safety (ChainlinkPriceFeed)

- Per-block caching of price; staleness guard via `heartbeat`
- Deviation guard vs last cached price (`MAX_PRICE_DEVIATION`, default 50%)
- All prices scaled to 18 decimals
- Requires configuring feed for native via `asset == address(0)`

### Admin and Configuration

- `Dgrid.sol`
  - `initialize(owner, server, dev, priceFeed, dgridNodeProxy, commissionRate, assets, nodePrice, dgridLock, lockAmountPerNode)`
  - `setCommissionRate(uint256<=100)`, `setServer(address)`, `setDev(address)`
  - `setPriceFeed(address)`, `setAssets(address[])`, `setNodePrice(uint256)`, `setLockAmountPerNode(uint256)`, `setDgridLock(address)`
  - `pause()`, `unpause()`, `emergencyWithdraw(address to)` when paused
- `DgridNode.sol`
  - `setPublicTransferEnabled(bool)`, `setDgrid(address)`, `setDgridStakePool(address)`
  - Transfers revert if disabled or if token is staked/jailed
- `DgridStakePool.sol`
  - `addRewardToken(token, perBlock)`, `setRewardPerBlock([...])`, `setRewardTokenEnabled(index, enabled)`
  - `setStartBlock(uint256)`, `setServer(address)`, `pause()`, `unpause()`, `emergencyWithdraw(address to)`
- `ChainlinkPriceFeed.sol`
  - `setPriceFeed(asset, aggregator)`, `setHeartbeat(uint32)`, `setMaxPriceDeviation(uint256)`

### Events (selected)

- Dgrid: `BuyNode`, `Locked`, `ClaimCommission`, `Pause`, `Unpause`, `EmergencyWithdraw`
- DgridNode: `Mint`, `Stake`, `Unstake`, `Jail`, `Unjail`
- DgridStakePool: `Deposit`, `JailNodes`, `UnjailNodes`, `Harvest`, `Update*`, `Pause`, `Unpause`, `EmergencyWithdraw`

### Development

- Install

```bash
npm install
```

- Compile

```bash
npx hardhat compile
```

### Notes

- Anyone can call `claimCommission(_user, assets[])`; funds are transferred to `_user` and balances zeroed.
- Ensure native price feed (`address(0)`) configured before enabling native purchases.
- Audit: see `audits/Metatrust_Dgrid.pdf`.
