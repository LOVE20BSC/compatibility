# PancakeSwap × Uniswap V2 兼容性分析（BSC）

针对 `core/src/Stake.sol` 实际依赖的 DEX 表面（Pair / Factory / Router / 父币），在 BSC 主网（56）与测试网（97）上做 Uniswap V2 兼容性验证，并以本地部署的官方 Uniswap V2 构建作为对照基线。

结论先行：

| | 结论 |
| --- | --- |
| Stake 用到的每个接口与参数在两条链上都可用 | ✅ 是 |
| 是否存在会破坏 Stake 的差异 | ❌ 未发现阻断项 |
| 是否存在需要知晓并记录的数字差异 | ⚠️ 有 3 处（费率、协议费、源码版本），见下 |

## 1. 被测对象

| profile | 链 | Factory | Router | WBNB |
| --- | --- | --- | --- | --- |
| `anvil`（基线） | 31337 | 官方 Uniswap V2 build @1.0.1 | 官方 Router02 @1.1.0-beta.0 | 参考 WETH9 |
| `bsc97_dev` | 97 | `0x6725F303…7a17` | `0xD99D1c33…50D1` | `0xae13d989…a7cd` |
| `bsc56_public` | 56 | `0xcA143Ce3…0c73` | `0x10ED43C7…024E` | `0xbb4CdB9C…095c` |
| `bsc56_public_test` | 56 | 同上（配置隔离） | 同上 | 同上 |

三个地址在每个网络上交叉核验：`router.factory() == factory`，`router.WETH() == wbnb`，两条链均一致。

## 2. 实测结果（11 项探针 × 4 个 profile，全部通过）

| 探针 | 覆盖内容 |
| --- | --- |
| `wrapper` | 存款/取款闭环、小数位、`approve` 返回单字布尔 |
| `factory` | `getPair` 顺序无关且未注册返回 0、`createPair` 登记、重复创建回滚、token0 按地址排序 |
| `pair.mint` | 首次铸造锁定 MINIMUM_LIQUIDITY、二次铸造按稀缺侧计价 |
| `pair.burn` | **`Stake._canBurn` 守卫边界：lp=31 回滚、lp=32 两侧都付出**（逐位对齐） |
| `pair.protocolFee` | 协议费铸造量（记录） |
| `pair.erc20` | LP 代币布尔返回、可转给自身 |
| `router.quote` | 报价与恒定乘积模型逐位比对 |
| `router.swap` | **以报价作为 `amountOutMin` 仍精确成交**；`deadline == block.timestamp` 被接受 |
| `router.failures` | `amountOutMin` 过高/过期 deadline/未注册池均回滚，且状态不变 |
| `stake.replay` | 真实 `Stake.sol` 端到端：首次/二次质押、结算销毁两侧、每轮一次、提取比例 |
| `slippage` | 偏离回滚且资金不动 |

### 三项实测出来的数字差异

**① 交易费率：主网是 0.25%，不是 Uniswap V2 的 0.30%**

同一组储备下，路由器报价与三个模型的逐位比对：

| profile | 实测报价 | 0.30%（997/1000） | 0.25%（9975/10000） | 0.20%（998/1000） | 判定 |
| --- | --- | --- | --- | --- | --- |
| anvil | 99690060900928 | ✅ 命中 | — | — | 30 bps |
| bsc97_dev | 99790040953912 | — | — | ✅ 命中 | 20 bps |
| bsc56_public | 99740050929919 | — | ✅ 命中 | — | **25 bps** |

对 Stake 无影响：Stake 不自己算报价，它读 `getAmountsOut` 并把它当作 `amountOutMin`；实测主网与测试网都**精确交付报价**（`probe=router.swapDeliversTheQuote PASS`）。0.25% 只意味着手续费积累比 Uniswap V2 假设的慢一些，不改变任何代码路径。

**② 协议费：两条链的 `feeTo` 都不为零，每次 mint/burn 都向国库铸 LP**

| profile | feeTo | 单次向国库铸造 | 占当时总供应 |
| --- | --- | --- | --- |
| anvil | 未配置 | 0 | 0 |
| bsc97_dev | 已配置 | 1,824,706,796,726,387 | 约 0.0058% |
| bsc56_public | 已配置 | 2,919,716,218,400,518 | 约 0.0092% |

后果是**稀释**：国库凭空多出 LP，`pairTotalSupply` 变大而 Stake 的 LP 余额不变，于是 Stake 记的每份 LP 对应的 sqrt(k) 偏低，增长被少记、费用少销毁。量级上属渗漏而非错账，且方向是"费用池少收、质押者多留"，不会让成员取不出钱。

附带一个可观测后果：提现时 Stake 的报价与实际到手有微小正向偏差（报价略高），因为 `withdraw` 会先结算、且 `pair.burn` 会先铸协议费，池子在报价之后又动了一次——

| profile | 报价与到手的差（token 侧） | 相对偏差 |
| --- | --- | --- |
| anvil | 0 | 0 |
| bsc97_dev | 28,737,758,986,766 / 1.1497e21 | 2.5e-8 |
| bsc56_public | 45,975,618,632,934 / 1.1496e21 | 4.0e-8 |

探针以"报价与到手差距不超过百万分之一"为判据通过。这个偏差是**任何开了协议费的 Uniswap V2 分叉都会有**的，不是 PancakeSwap 独有。

**③ 链上合约与 GitHub 源码不是同一份（主网与测试网都不是）**

`script/verify_source.py` 用多个 RPC 交叉取码（端点间须一致），剥离 solc 元数据尾部后，与候选源码在 solc 版本 × 优化器 runs × evm 版本矩阵下逐字节对拍：

| profile | 目标 | 剥离元数据后大小 | 字节码匹配 | Stake 依赖的函数选择器 |
| --- | --- | --- | --- | --- |
| bsc56_public | pair | 14929 B | ❌ 未匹配 | ✅ 全部存在 |
| bsc56_public | factory | 18898 B | ❌ 未匹配 | ✅ 全部存在 |
| bsc56_public | router | 21883 B | ❌ 未匹配 | ✅ 全部存在 |
| bsc56_public | wbnb | 3124 B | ❌ 未匹配 | ✅ 全部存在 |

**四类合约没有一个与 GitHub 源码逐字节一致。**

候选源码覆盖 `PancakeFactory`/`PancakePair`/`PancakeRouter`（pancake-swap-core@3b21430、periphery@d769a6d）
与 `UniswapV2Factory`/`UniswapV2Pair`/`UniswapV2Router01|02`（v2-core@v1.0.1、v2-periphery）、
以及官方 WBNB（`bnb-chain/bsc-genesis-contract@8464181`）与参考 WETH9；
编译矩阵 solc × optimizer runs ∈ {1, 200, 1000, 5000, 999999} × 关优化 × evm ∈ {默认, istanbul}。
受沙箱限制，只能用本地已缓存的编译器（WBNB 的 `^0.4.18` 只能试 0.4.26）。

对照源码：[pancake-swap-core@3b21430](https://github.com/pancakeswap/pancake-swap-core)、[pancake-swap-periphery@d769a6d](https://github.com/pancakeswap/pancake-swap-periphery)、[Uniswap/v2-core@v1.0.1](https://github.com/Uniswap/v2-core)、[Uniswap/v2-periphery](https://github.com/Uniswap/v2-periphery)。

佐证这一点的是源码 diff 与链上行为的互相印证：GitHub master 的 `PancakePair` 用的是 2/1000（0.20%），而**主网实测 0.25%**，测试网才是 0.20%；工厂暴露的 `INIT_CODE_PAIR_HASH = 0x00fb7f63…` 也与 master 里 `PancakeLibrary` 硬编码的 `0xd0d4c4cd…` 不同。也就是说链上跑的是**更新过的一版 pair/factory**，"GitHub 源码 == 链上部署"这一条无法被证实。

因此本报告的结论**不依赖源码比对**，而建立在两层链上证据之上：

1. **接口层**：Stake 实际调用的函数（`token0`、`getReserves`、`totalSupply`、`mint`、`burn`、
   `getPair`、`createPair`、`getAmountsOut`、`swapExactTokensForTokens`、ERC20 三个方法、
   `deposit`、`withdraw`）在四类合约上**选择器全部存在**——上表最后一列，四类全 ✅。
   这排除了"函数签名不同导致调用落到 fallback"这类最隐蔽的失败。
2. **行为层**：11 项探针在 4 个 profile 上实测全部通过（数值、状态变化、回滚语义）。

"源码是否一致"回答的是"我读的代码对不对"，"接口与行为是否一致"回答的是"能不能接"。
后者才是决定性的，且已被正面证实；前者目前为否，需要 BscScan API key 才能查到链上部署的确切版本。

## 3. 判定

按 `matt-gov/docs/specs/compatibility.md` 的判定表：

- **通过**：Stake 依赖的接口、状态变化、数值、回滚语义在两条链上全部满足 —— ✅ 可部署
- **有记录的差异**：费率 0.25% 与协议费稀释，二者都影响数值但不破坏正确性，证据完整 —— 已记录
- **阻断**：无

需要明确的一点：协议费稀释会让"销毁量"略低于纯 Uniswap V2 模型的理论值。若业务上要求销毁量与模型严格一致，办法是改用 `feeTo == 0` 的工厂（例如自部署一份 Uniswap V2 系工厂给 LOVE20 的池子用），而不是改 Stake。

## 4. 复现

```bash
export PATH="$HOME/.foundry/bin:$PATH"
./script/run.sh anvil              # 本地 Uniswap V2 基线
./script/run.sh bsc97_dev          # BSC 测试网
./script/run.sh bsc56_public       # BSC 主网
python3 script/verify_source.py bsc56_public   # 源码与链上对拍
```

新增一个网络：在 `config/networks/` 放一份 JSON（链 ID、RPC、区块、三个地址），无需改代码。

每份 profile 的证据在 `results/<profile>/probe.evidence.txt`（逐条 `probe=… status=…` 与实测数值），源码对拍在 `results/<profile>/source-verification.json`。
