# Safety

The contracts square uses, where to read their source, what was reviewed, what everything costs, and what can go wrong.

## The contracts

All of them are on chain 4663 and verified on [the explorer](https://robin.etherscan.io). The source of every one is public: <https://github.com/Grolol666/maidmarian-curve-contracts>.

| Contract | Address | Role |
|---|---|---|
| Launcher, STOCKS are SEED | [`0x23A46e99356E5f11c0f2605733Ebdba7569b1b30`](https://robin.etherscan.io/address/0x23A46e99356E5f11c0f2605733Ebdba7569b1b30#code) ([source](../src/MaidMarianTokenLauncherV5.sol)) | Launches a token whose curve holds 2 to 10 stock tokens directly |
| Curve, STOCKS are SEED | [`0xd4034Fa8f669a5Aa9583720d5105c95fD559096b`](https://robin.etherscan.io/address/0xd4034Fa8f669a5Aa9583720d5105c95fD559096b#code) ([source](../src/MaidMarianLaunchCurveV5.sol)) | The curve every launch copies: buys, sells, bonds into pools |
| Hook, STOCKS are SEED | [`0x06dAEb519C54F8448644fA88e8e34f0E432dE000`](https://robin.etherscan.io/address/0x06dAEb519C54F8448644fA88e8e34f0E432dE000#code) ([source](../src/MaidMarianLaunchHook.sol)) | Lets only the curve open its own bond pools |
| Launcher, ETF is SEED | [`0x041FdB47373b9f620FC0c8B3B37Df3A87c39B17d`](https://robin.etherscan.io/address/0x041FdB47373b9f620FC0c8B3B37Df3A87c39B17d#code) ([source](../src/launcher-v4/MaidMarianTokenLauncher.sol)) | Launches a token backed by an ETF made with it |
| Curve, ETF is SEED | [`0xa5151D6d98DB2E346238A079c8e3AcF72d56cB56`](https://robin.etherscan.io/address/0xa5151D6d98DB2E346238A079c8e3AcF72d56cB56#code) ([source](../src/launcher-v4/MaidMarianLaunchCurve.sol)) | The curve every launch copies |
| Hook, ETF is SEED | [`0xCF2a336984d45Ac8eb2e5aA545284833Ee93e000`](https://robin.etherscan.io/address/0xCF2a336984d45Ac8eb2e5aA545284833Ee93e000#code) ([source](../src/launcher-v4/MaidMarianLaunchHook.sol)) | Lets only the curve open its own bond pools |
| ETF factory | [`0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA`](https://robin.etherscan.io/address/0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA#code) ([source](../src/etf-v4/MaidMarianEtfFactoryV4.sol)) | Anyone creates an ETF of 1 to 10 listed tokens |
| ETF | [`0x2d506E246fCcE5A2f379835FC60B04F716FC4872`](https://robin.etherscan.io/address/0x2d506E246fCcE5A2f379835FC60B04F716FC4872#code) ([source](../src/MaidMarianEtfV4.sol)) | The ETF every factory ETF copies: mint, redeem, rebalance |
| Previous ETF factory | [`0xC70c7C3259497E195d76a290601a4650E02090Eb`](https://robin.etherscan.io/address/0xC70c7C3259497E195d76a290601a4650E02090Eb#code) ([source](../src/etf-v3/MaidMarianEtfFactory.sol)) | Its ETFs stay listed and tradable |
| Permit2 gate | [`0x67162DE03B31F9be637D9dDc216f3163E44BeE5a`](https://robin.etherscan.io/address/0x67162DE03B31F9be637D9dDc216f3163E44BeE5a#code) ([source](../src/UniswapPermit2Gate.sol)) | Pays a Uniswap route with a plain approval |

Earlier launchers keep the curves they made and are listed, with the ETFs of the collection, in the repository's README.

### How anyone checks the source

The repository states the compiler settings every contract was built with: the same compiler, the same optimizer settings, the same libraries pinned by a lock file. Build a contract with them and its code, down to the metadata hash, matches byte for byte what is deployed at its address. The explorer's "verified" mark says the same.

## Reviews

These are **internal reviews**, written by a reviewer who did not write the code. They are not a third-party audit. Each one ran the contracts' tests and wrote its own proofs.

**STOCKS are SEED**

- **F1, high: fixed.** A first buy split off the basket's weights could open the pools far apart in price and let an arbitrageur take stock from the holders' pools. The first buy now always follows the weights.
- **F2, medium: fixed.** The first buy's slippage floor guarded nothing, so a launch could be sandwiched. The first buy is now counted from what it really got.
- **F3, medium: accepted.** If a stock's price is pushed and held for 30 minutes, a curve can bond early and open that stock's pool off price. It takes a thin pool, no one correcting it for half an hour, and a lot of money. Blocking it would also block honest bonds after a real market move, so it stays, and it is told here.
- **F4, low: noted.** When a stock is off its 30 minute average, a buy can get slightly less than its USDG's worth of the basket, never more. The difference stays with the holders.

A final pass over the whole of the code confirmed F1 and F2 closed.

**ETF is SEED**

- One medium finding: the 30 minute average of one stock, pushed and held, could skew the pools opened at the bond. The share of each pool is now kept within a band around its stock's weight.
- Three low findings, accepted: a stock whose price does not fit a pool at the bond loses its pool; a bond with ETF-in-ETF legs can cost more gas than a wallet simulates; a sell-only rebalance can move a little value at the bond.
- Earlier reviews of the curve found a way to block a bond for a dust amount, closed by the hook.

**ETFs**

- No high or medium finding. The ETF keeps its own count of what it holds, so a gift sent to it moves no one's share. A holder can always leave in kind, whatever happens to one stock, its pool or its hook.
- Low findings, edge cases: a hook run by someone else could take up to 0.5 % of a rebalance trade; a stock that rebases would break a count (no stock token on the chain does); a mint can fail until a sale left in the fund is used.

## Fees

| What | How much | Who gets it |
|---|---|---|
| Launch a token | 0.0005 ETH (ETF is SEED: 0.001 ETH to create its ETF) | Protocol |
| Trade on a curve | 0.75 % | 70 % creator, 30 % protocol |
| Creator tax | 0 to 10 %, the creator's pick, fixed at the launch | Creator |
| Snipe tax | First 5 seconds of a STOCKS are SEED curve (3 in ETF is SEED), falling to nothing | 70 % creator, 30 % protocol |
| The bond, STOCKS are SEED | 75 % of the stocks open the pools, 25 % to the protocol | Pools / protocol |
| The bond, ETF is SEED | 70 % opens a pool, 30 % to the protocol | Pool / protocol |
| Pool fees after the bond (STOCKS are SEED) | 1 % per swap | 70 % creator, 30 % protocol |
| ETF entry and exit fees | 0 to 5 % each, the creator's pick (0.10 % at least on entry) | 70 % creator, 30 % protocol |
| ETF hold period and penalties | Set by the creator | 70 % creator, 30 % protocol |
| ETF management fee | 0.50 % a year | 0.30 creator, 0.20 protocol |

## Risks

- **Market risk.** Stock tokens move. A STOCKS are SEED curve holds stocks: what a sale pays follows their price. The bond depends on the market too: it can come sooner, later, or never.
- **Thin pools after the bond.** A bond opens pools with a limited amount of liquidity. A large sale can move the price a lot, and the pools are locked: no one can take their liquidity back out.
- **Smart-contract risk.** The contracts are new, internally reviewed, and not audited by a third party. A bug can lose funds. Only put in what you can lose.
- **The chain itself.** Everything runs on chain 4663. If the chain, its bridge, its data feeds or the exchanges your pools rely on fail or change, the contracts cannot work around it. Stock tokens depend on their issuer.

*Experimental software. These are not registered funds; nothing here is an offer or investment advice. Unaudited.*
