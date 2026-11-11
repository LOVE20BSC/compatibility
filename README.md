# compatibility

验证 BSC 上的 PancakeSwap 是否满足 `core/src/Stake.sol` 对 Uniswap V2 的依赖。
结论与完整证据见 [`results/compatibility-report.md`](results/compatibility-report.md)。

这个工程**单向**引用 `core/src`（为了把真实的 `Stake.sol` 部署到 fork 上跑回放），
不被任何业务仓库导入，也不改动业务规格。

## 用法

```bash
export PATH="$HOME/.foundry/bin:$PATH"
./script/run.sh <profile>            # 源码对拍 + 兼容性探针
./script/run.sh <profile> --no-verify # 只跑探针
python3 script/verify_source.py <profile> ...
```

`run.sh` 做三件事：把 profile 配置导出成环境变量；必要时先编译参考实现；跑 `forge test`
并落盘日志。探针本身不知道任何链的地址。

## 接一个新网络

在 `config/networks/` 加一份 JSON 即可，不需要碰代码：

```json
{
  "profile": "my_chain",
  "mode": "fork",
  "chainId": 56,
  "rpc": ["https://...", "https://..."],
  "forkBlock": 122503000,
  "addresses": {
    "wbnb": "0x...",
    "factory": "0x...",
    "router": "0x...",
    "pair": "derive"
  }
}
```

- `mode: "fork"` 需要能读历史状态的 RPC（archive）。公开的全节点只能回溯约 100 个区块，
  fork 会报 `missing trie node`；已验证可用的 archive 端点写在现有 profile 里。
- `pair: "derive"` 表示取 `factory.allPairs(0)` 来代表该工厂创建的池子模板，无需知道具体地址。
- 至少两个端点会在取码时交叉比对，不一致就拒绝下结论。

## 结构

| 路径 | 作用 |
| --- | --- |
| `config/networks/` | 每个网络一份：链 ID、RPC、区块、地址 |
| `config/source-candidates.json` | 候选源码单元、编译矩阵、Stake 依赖的签名清单 |
| `script/verify_source.py` | 编译候选源码，与链上运行时字节码逐字节对拍（含选择器存在性） |
| `script/fetch_reference.py` | 取官方 Uniswap V2 构建产物，生成 `src/fixtures/ReferenceCode.sol` |
| `src/CompatBase.sol` | 探针基座：profile 装配、断言、恒定乘积公式 |
| `test/CompatibilityProbe.t.sol` | 唯一的参数化探针，11 项检查，一次运行出判定 |
| `results/<profile>/` | 证据文件与日志 |

## 两个设计约束

**本地基线必须用官方发布产物，而不是重新编译源码。**
`UniswapV2Library.pairFor` 把 pair 模板的 init code hash 硬编码在源码里，
自己编译出来的 pair 与它不一致，路由器会去一个从未创建过的地址上找池子。
`fetch_reference.py` 直接取 npm 上的 `build/*.json` 部署，三者才互相自洽。

**判定必须和证据一致。**
早期版本把失败记成 `status=FAIL` 却不回滚，最终汇总又各自独立，
结果出现"12/12 全绿、证据里却有 FAIL"的自相矛盾。现在任何一项检查失败都会让它所在的探针失败，
退出码不可能与证据文件打架；需要人来裁决的差异才写成 `note=`。

## 许可

`lib/` 下是 GPL-3.0 的上游源码（Uniswap V2、PancakeSwap），仅作对照与对拍用；
`src/fixtures/ReferenceCode.sol` 由 GPL-3.0 的官方构建产物生成。
业务仓库不导入本目录任何内容。`lib/core` 是指向 `../core` 的软链。
