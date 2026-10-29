# Square Maid Marian contracts

Square Maid Marian is a launchpad and a set of stock-token ETFs on Robinhood Chain (chain id 4663). This repository holds the source of every contract its pages call.

## Contracts

Explorer: [robin.etherscan.io](https://robin.etherscan.io). Every address below is verified there.

| Contract | Address | Source | Role |
|---|---|---|---|
| Launcher v5 | [`0x23A46e99356E5f11c0f2605733Ebdba7569b1b30`](https://robin.etherscan.io/address/0x23A46e99356E5f11c0f2605733Ebdba7569b1b30#code) | `src/MaidMarianTokenLauncherV5.sol` | Launches a token whose bonding curve holds 2 to 10 stock tokens directly |
| Launch curve v5 (implementation) | [`0xd4034Fa8f669a5Aa9583720d5105c95fD559096b`](https://robin.etherscan.io/address/0xd4034Fa8f669a5Aa9583720d5105c95fD559096b#code) | `src/MaidMarianLaunchCurveV5.sol` | The curve every v5 launch clones: buys, sells, bonds into Uniswap V4 pools |
| Launch hook v5 | [`0x06dAEb519C54F8448644fA88e8e34f0E432dE000`](https://robin.etherscan.io/address/0x06dAEb519C54F8448644fA88e8e34f0E432dE000#code) | `src/MaidMarianLaunchHook.sol` | `beforeInitialize` only: no one but the curve opens its bond pools |
| Launcher v4 | [`0x041FdB47373b9f620FC0c8B3B37Df3A87c39B17d`](https://robin.etherscan.io/address/0x041FdB47373b9f620FC0c8B3B37Df3A87c39B17d#code) | `src/MaidMarianTokenLauncher.sol` | Launches a token whose bonding curve is quoted in an ETF, USDG or WETH |
| Launch curve v4 (implementation) | [`0xa5151D6d98DB2E346238A079c8e3AcF72d56cB56`](https://robin.etherscan.io/address/0xa5151D6d98DB2E346238A079c8e3AcF72d56cB56#code) | `src/MaidMarianLaunchCurve.sol` | The curve every v4 launch clones |
| Launch hook v4 | [`0xCF2a336984d45Ac8eb2e5aA545284833Ee93e000`](https://robin.etherscan.io/address/0xCF2a336984d45Ac8eb2e5aA545284833Ee93e000#code) | `src/MaidMarianLaunchHook.sol` | Same hook, for the v4 bond pools |
| ETF factory v4 | [`0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA`](https://robin.etherscan.io/address/0x1854fB4dE64515d8050e7B48D8d8Af2aBac67AAA#code) | `src/MaidMarianEtfFactoryV4.sol` | Anyone creates an ETF of 1 to 10 listed tokens; one approve mints any of them |
| ETF v4 (implementation) | [`0x2d506E246fCcE5A2f379835FC60B04F716FC4872`](https://robin.etherscan.io/address/0x2d506E246fCcE5A2f379835FC60B04F716FC4872#code) | `src/MaidMarianEtfV4.sol` | The ETF every v4 factory ETF clones: mint, redeem, rebalance |
| ETF factory v3 | [`0xC70c7C3259497E195d76a290601a4650E02090Eb`](https://robin.etherscan.io/address/0xC70c7C3259497E195d76a290601a4650E02090Eb#code) | `src/etf-v3/MaidMarianEtfFactory.sol` | The previous factory; its ETFs stay listed and tradable |
| ETF v3 (implementation) | [`0x39A146368eAA8B73C9656e95428081CD5dc75dC5`](https://robin.etherscan.io/address/0x39A146368eAA8B73C9656e95428081CD5dc75dC5#code) | `src/etf-v3/MaidMarianEtfV3.sol` | The ETF every v3 factory ETF clones |
| m7m | [`0x51ac9114399C9236a3C165cb42CEF8Fc5AA6Aa28`](https://robin.etherscan.io/address/0x51ac9114399C9236a3C165cb42CEF8Fc5AA6Aa28#code) | `src/MaidMarianSevenMagnificent.sol` | The seven Magnificent Seven stock tokens in equal value |
| Permit2 gate | [`0x67162DE03B31F9be637D9dDc216f3163E44BeE5a`](https://robin.etherscan.io/address/0x67162DE03B31F9be637D9dDc216f3163E44BeE5a#code) | `src/UniswapPermit2Gate.sol` | Pays a Uniswap Universal Router route with a plain `approve`; used by m7m |
| mAI | [`0xd55b7C09541699c765e93c9837afD73338E74cAd`](https://robin.etherscan.io/address/0xd55b7C09541699c765e93c9837afD73338E74cAd#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mCHIP | [`0x26Aa41616390FFE3c799D4059CCB42CdAD7261c9`](https://robin.etherscan.io/address/0x26Aa41616390FFE3c799D4059CCB42CdAD7261c9#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mCRYPTO | [`0x06e1084D3c3d8e17C2626f8E12052bAAED5Bdf67`](https://robin.etherscan.io/address/0x06e1084D3c3d8e17C2626f8E12052bAAED5Bdf67#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mELON | [`0x7dF756fE1A4A630103203c22479525A1ABF0273B`](https://robin.etherscan.io/address/0x7dF756fE1A4A630103203c22479525A1ABF0273B#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mGLP1 | [`0x94F57D6CD2358216C023303Ca105366656EC3DA7`](https://robin.etherscan.io/address/0x94F57D6CD2358216C023303Ca105366656EC3DA7#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mGOIL | [`0xee49ed3d39c0ba0d7ea71cfb565b7972997baedb`](https://robin.etherscan.io/address/0xee49ed3d39c0ba0d7ea71cfb565b7972997baedb#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mHANDS | [`0x67eCBe883ca5974eE404b44d192a25B92d19115C`](https://robin.etherscan.io/address/0x67eCBe883ca5974eE404b44d192a25B92d19115C#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mLAZY | [`0x6fb5F5E41a365cc3723613182d9AAaB8A25CF6C3`](https://robin.etherscan.io/address/0x6fb5F5E41a365cc3723613182d9AAaB8A25CF6C3#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mMEME | [`0x94e8b7E39862be53D13e34d053516FAbA591b606`](https://robin.etherscan.io/address/0x94e8b7E39862be53D13e34d053516FAbA591b606#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mMETAL | [`0x3441Ff0E9fA5C2e1D8B1d5Ac2F1a727eF7E1f3f5`](https://robin.etherscan.io/address/0x3441Ff0E9fA5C2e1D8B1d5Ac2F1a727eF7E1f3f5#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mSHOP | [`0x8105890ab234D6B3e27aA60137D90e1292F73dfB`](https://robin.etherscan.io/address/0x8105890ab234D6B3e27aA60137D90e1292F73dfB#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mSLEEP | [`0x26c602445b3dFA7e1842bEC02f4D570FcB521d45`](https://robin.etherscan.io/address/0x26c602445b3dFA7e1842bEC02f4D570FcB521d45#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |
| mWORLD | [`0x4b7F0Df8025DD9E548d88AFd6764bb0752e3B670`](https://robin.etherscan.io/address/0x4b7F0Df8025DD9E548d88AFd6764bb0752e3B670#code) | `src/etf-v2/MaidMarianEtf.sol` | ETF of the collection |

The contracts these deploy themselves are in the same sources: each launch's token (`MaidMarianToken2.sol` for v5, `MaidMarianToken.sol` for v4), each factory's TWAP reader (`MaidMarianBagPoolOracle.sol`), each ETF logo stored as code (`MaidMarianTokenChecks.sol`).

`src/etf-v3/` and `src/etf-v2/` hold the text the ETF factory v3 and the collection were built from, where it differs from `src/` (the factory's name and profile checks, the TWAP reader's spot quote); each folder is complete on its own.

## Build and test

```
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0 --no-git
forge build
forge test
```

`foundry.lock` pins both libraries to the commits the contracts were built with. The tests run offline, on mocks.

## Verified with these exact settings

solc 0.8.35, EVM `cancun`, optimizer on with 1,000,000 runs, `viaIR`, metadata `bytecodeHash` `ipfs`; remappings as in `remappings.txt`. Each contract was verified from the import closure of its file, at the paths it has in `src/` (the contracts of `src/etf-v3/` and `src/etf-v2/` at `src/` itself).

A few comments were edited for this repository: references to internal notes and a few French remarks removed. The compiled code is the same; only the metadata hash at the end of the bytecode moves for the files concerned.
