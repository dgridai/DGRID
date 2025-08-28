# DGRID Product Analysis

Empowering On-Chain Commerce: Transparent Node Sales, Tiered Pricing, and Automated Commissions.

## I. Product Positioning

DGRID is a decentralized, upgradeable module for selling ERC-1155 “nodes” with fair, transparent pricing and automated referral commissions. It supports native and ERC-20 payments with Chainlink-powered price conversion, enabling straightforward integration for dApps and platforms.

## II. Core Value Proposition

- **Transparent Pricing** – Tiered per-order pricing based on quantity, enforced on-chain.
- **Multi-Asset Payments** – Native token or ERC-20 assets with oracle conversion.
- **Automated Commissions** – Configurable commission rate, accrued by referrers and claimable anytime.
- **Upgradeable & Secure** – Non-reentrant flows, server-signed orders, and oracle safety.

## III. Feature Overview

### 1. Server-Signed Node Purchases

- Off-chain signature by `server` authorizes an order with `(chainId, orderId, user, parent, nodeCount, expireTime)`.
- On-chain validation prevents forgery, replays, and expired orders.
- Payer can differ from the `user` (supports custodial/3rd-party payments).

### 2. Tiered Pricing & Oracle Conversion

- `priceSteps` + `stepRanges` select a per-order price per node (non-incremental).
- Conversion via `ChainlinkPriceFeed.fetchPrice(asset)` to native/ERC-20 amounts.
- Defaults if unset: `priceSteps = [600, 550, 500]`, `stepRanges = [9, 49, type(uint256).max]`.

### 3. Commission System

- Commission accrues per `parent` per `asset`: `commission[parent][asset]`.
- `commissionRate` is percentage (e.g., `10` means 10%).
- Users claim their accrued balances across all configured assets plus native.

### 4. Transfer-Gated ERC-1155 Nodes

- Node `id = 1` minted to `user` upon purchase.
- Transfers are disabled by default and can be enabled by owner.

### 5. Oracle & Safety Controls

- Heartbeat staleness check, optional price deviation guard (default 50%).
- Per-block price caching to save gas.
- All prices normalized to 18 decimals for consistent math.

### 6. Lifecycle

- **Authorize**: Off-chain signature by `server`.
- **Purchase**: On-chain buy, price conversion, commission accrual, minting.
- **Claim**: Referrers claim accrued commissions.
- **Enable Transfers**: Owner may open public transfers when ready.

### 7. Node Economics

- Single node type `NODE_ID = 1`.
- Total cost per order = `pricePerNode(nodeCount) * nodeCount * 1e18`.
- Commission per order = `(payValue * commissionRate) / 100`.

## IV. Key Features Breakdown

| Feature Module           | Implementation                                       | User Value                                          |
| ------------------------ | ---------------------------------------------------- | --------------------------------------------------- |
| Server-Signed Purchases  | EIP-191 signature with expire/orderId validation     | Prevents forgery/replays; predictable purchase flow |
| Tiered Pricing           | `priceSteps` + `stepRanges`                          | Fair, transparent per-order pricing                 |
| Multi-Asset Payments     | Native + ERC-20, Chainlink conversion                | Flexible payment with accurate conversion           |
| Referral Commissions     | On-chain accrual per parent/asset + claim            | Simple and auditable incentives for growth          |
| ERC-1155 Node Minting    | `DgridNode` with transfer gating                     | Controlled distribution; can open transfers later   |
| Oracle Safety            | Heartbeat + deviation guard + per-block caching      | Reliable, gas-efficient, and safe pricing           |
| Upgradeable Architecture | Initializable + OwnableUpgradeable + ReentrancyGuard | Secure, maintainable, and future-proof              |

## V. Technical Highlights

- **Security**: `nonReentrant` on purchase/claim; unique `orderId`; signed order with `chainId` and `expireTime`.
- **Oracle Robustness**: Staleness and deviation checks; 18-decimal normalization; per-block caching.
- **Asset Handling**: Native path refunds excess; ERC-20 via low-level `transfer`/`transferFrom` with success checks.
- **Access Control**: Owner manages params; only `Dgrid` can mint; `DgridNode` owner controls transfer enablement.
- **Upgradeable**: Uses `Initializable`, `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`.

## VI. Key FAQs

- **Q: What fees are involved?**  
  A: Payments are split into developer proceeds and optional referral commissions per configured `commissionRate`.

- **Q: How is price determined?**  
  A: By the configured tier (`priceSteps`/`stepRanges`) based on `nodeCount`, then converted via Chainlink to the payment asset.

- **Q: How are commissions claimed?**  
  A: Referrers call `claimCommission(user)` to receive accrued balances across supported ERC-20s and native token.

- **Q: Can transfers be enabled later?**  
  A: Yes. `DgridNode` starts with transfers disabled; owner can enable them via `setPublicTransferEnabled(true)`.

- **Q: Does the payer have to be the recipient?**  
  A: No. The caller/payer can be different from `user`.

## VII. Smart Contract Development

**Contracts**

- `contracts/Dgrid.sol`
- `contracts/DgridNode.sol`
- `contracts/ChainlinkPriceFeed.sol`

**Installation**

```bash
npm install
```

**Compile**

```bash
npx hardhat compile
```

**Test**

```bash
npx hardhat test
```

**Deploy (example)**

```bash
npx hardhat run scripts/deploy.ts --network bsc
# or
npx hardhat run scripts/deploy.js --network bsc
```

**Verify**

```bash
npx hardhat verify --network bsc <contract_address> [constructor_args...]
```

## VIII. Contract Interfaces (Admin & Events)

- Admin (on `Dgrid`):
  - `setCommissionRate(uint256)`
  - `setServer(address)`
  - `setDev(address)`
  - `setPriceFeed(address)`
  - `setPriceSteps(uint256[] ranges, uint256[] prices)` (lengths must match)
  - `setAssets(address[] assets)`
- Admin (on `DgridNode`):
  - `setPublicTransferEnabled(bool)`
- Events:
  - `BuyNode(orderId, user, parent, nodeCount, asset, payValue, commissionAmount)`
  - `ClaimCommission(user, assets, amounts)`
