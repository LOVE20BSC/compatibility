# Core 接口迁移：已完成

`lib/core` 是指向 `../core` 工作树的软链，不是 pin 的子模块，core 的改名会立刻作用到本仓。下列调用点已于 2026-10-31 全部跟进，`forge build` 与 `forge test --list` 均可通过。

| 位置 | 现调用 |
| --- | --- |
| `test/CompatibilityProbe.t.sol:366`、`:409`、`:427` | `stake.memberStake(tokenAddress, memberId)`，6 元组；探针取首位 `liquidityShares`，位置不变 |
| `test/CompatibilityProbe.t.sol:492` | `stake.totalStake(tokenAddress)`，7 元组；探针取前四位 `shares/lp/withdrawable/fee`，位置不变 |
| `test/CoreAuditFindings.t.sol:191` | `s.stake.totalStake(...)`；该行取第 5 位（`boostLiability` ← `totalBoostShares`），位置不变 |
| `test/CoreAuditFindings.t.sol:219` | `s.launch.remainingLaunchCount(tokenAddress, memberId)`（成员可用次数；累计已产生读 `issuedLaunchCount(tokenAddress)`） |
| `test/CoreAuditFindings.t.sol:235`、`:243` | `s.submit.proposalIdBySubmitterId(tokenAddress, round, submitterId)`；测试里传的就是该成员 id |

## 说明

- `stakeData` / `totalStakeData` 是更早的命名批次遗留，与 `launchCount` / `proposalIdBySubmitter` 不是同一批；本次一并修完。
- 不能按名字批量替换：`test/CompatibilityProbe.t.sol:22` 有一个同名本地 helper `proposalIdBySubmitterId(address, uint256, uint256)`，与本迁移无关。
- 完整回放 `./script/run.sh <profile>` 仍需要 archive RPC；本仓不参与三仓门禁，也不导入业务规格。

# Core 接口迁移（二）：`stakeLiquidity` 去掉滑点、事件改版

`lib/core` 是软链，core 于 2026-11-13 把「单向增质押 + 无滑点记账」合入工作树后本仓立刻编译失败，下列调用点当轮跟进。改动前后的 fork 结论逐位一致（见文末对照）。

| 位置 | 现调用 |
| --- | --- |
| `test/CompatibilityProbe.t.sol:532`（`stakeAs`） | `stakeLiquidity(address(token), tokenAmount, parentAmount, PROMISED_PHASES, memberId)`，5 参；原第 4 参 `slippage` 删除 |
| `test/CompatibilityProbe.t.sol:487` | `abi.encodeWithSelector(IStake.stakeLiquidity.selector, address(token), OFF_RATIO_TOKEN, OFF_RATIO_PARENT, PROMISED_PHASES, uint256(2))`；选择器按 5 参新签名拼接 |
| `test/CoreAuditFindings.t.sol:182`、`:197`、`:241`、`:272`、`:298`、`:300` | 同上 5 参形态；`1e18` 的滑点实参删除，`1` 即原有 `promisedWaitingPhases` |
| `test/CompatibilityProbe.t.sol:44`（原 `SLIPPAGE` 行） | 常量删除；第 11 项改用 `:46` `OFF_RATIO_TOKEN` / `:47` `OFF_RATIO_PARENT` |
| `test/CompatibilityProbe.t.sol:447` | `test_11_slippageGuard` → `test_11_offRatioDeposit`；`IStakeErrors` 导入随之删除（错误 `SlippageExceeded` 已不存在） |

## 说明

- 探针仍是 11 项、判定条数不减：第 11 项原为 4 条判定（拒绝、错误选择器、池子回滚、余额回滚），新 ABI 下改为 5 条（接受、折算剩余留在调用者、父币侧不动、按落地量记票、池子增长）。`check()` 失败即回滚，退出码与证据一致这条性质不变。
- 事件 `LiquidityStaked` 的 `govVotes` 字段已删除、`BoostStaked` 新增 `caller`/`memberOwner`/`prevPromisedWaitingPhases`，但本仓没有解析这两个事件的调用点，无需改；ABI 变更由 core 自己的事件登记脚本负责。
- **附带修好一个与 ABI 无关的老问题**：`forge test` 不带环境变量时，`loadProfile()` 会在 `envString("COMPAT_RPC_URL")` 处失败（改动前即如此，与本次 ABI 无关）。现在完全没配置时按 `anvil`（`mode: local`，唯一不需要 RPC 的 profile）跑；一旦显式指定了 `COMPAT_PROFILE` 却缺 RPC 变量，仍然报错退出，不会把本地判定冒充成某个网络的判定。
- 对拍：`anvil` / `bsc56_public` / `bsc97_dev` 三个 profile 改动前后，除第 11 项外全部判定逐条相同，全部 24–25 个实测数值逐位相同；`bsc56_public` 的源码对拍（四类合约 `NO MATCH`、选择器全存在）也逐字节一致。
