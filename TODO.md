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
