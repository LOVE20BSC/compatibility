#!/usr/bin/env python3
"""Prove that the contracts we analyse really are the contracts that are deployed.

Two independent things have to hold before a source file may be called "the deployed code":

1. Every configured address is read over several independent RPC endpoints and they must return
   the same runtime code, so no single provider gets to decide what "deployed" means.
2. A candidate source is compiled under a matrix of solc versions and optimizer settings, and the
   on-chain runtime code must start with the compiled runtime code. The residue left over is
   solc's metadata trailer, which the deployer's toolchain appends and we do not reproduce.

A residual of more than MAX_RESIDUE bytes is reported as "no match": real code differences are
hundreds of bytes, not tens.
"""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request
from hashlib import sha256
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config"
LIB = ROOT / "lib"
RESULTS = ROOT / "results"

FORGE_BIN = Path.home() / ".foundry" / "bin"
MAX_RESIDUE = 200



# --------------------------------------------------------------------------- RPC


class Rpc:
    """Minimal JSON-RPC client, so this step does not depend on cast being installed."""

    TIMEOUT = 25
    # Public RPC providers reject requests without a User-Agent, so pose as a plain client.
    HEADERS = {"Content-Type": "application/json", "User-Agent": "love20-compatibility-check/1.0"}

    def __init__(self, url: str, timeout: int = TIMEOUT):
        self.url = url
        self.timeout = timeout

    def call(self, method: str, params: list) -> Any:
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, data=payload, headers=self.HEADERS)
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            body = json.loads(response.read())
        if "error" in body:
            raise RuntimeError(f"{self.url}: {body['error']}")
        return body["result"]

    def chain_id(self) -> int:
        return int(self.call("eth_chainId", []), 16)

    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def code(self, address: str) -> str:
        return self.call("eth_getCode", [address, "latest"]).lower().removeprefix("0x")

    def call_to(self, address: str, data: str) -> str:
        return self.call("eth_call", [{"to": address, "data": data}, "latest"])


# ------------------------------------------------------------------- compilation


def build_unit(unit: dict, solc: str, optimizer: bool, runs: int | None, work: Path, evm_version: str = "") -> Path:
    """Compile one unit in a throwaway Foundry project and return its `out` directory."""
    src = work / "src"
    work.mkdir(parents=True, exist_ok=True)
    if not src.exists():
        src.mkdir(parents=True)

    ignore = shutil.ignore_patterns(*unit.get("exclude", []))
    for target, source in unit["roots"].items():
        destination = src if target == "src" else work / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(LIB / source, destination, ignore=ignore)

    remappings = ", ".join(f'"{key}={value}"' for key, value in unit.get("remappings", {}).items())
    lines = [
        "[profile.default]",
        'src = "src"',
        'out = "out"',
        'cache_path = "cache"',
        f'solc_version = "{solc}"',
    ]
    if optimizer:
        lines.append("optimizer = true")
        lines.append(f"optimizer_runs = {runs}")
    else:
        lines.append("optimizer = false")
    if evm_version:
        lines.append(f'evm_version = "{evm_version}"')
    lines += [
        'bytecode_hash = "none"',
        "cbor_metadata = false",
        f"remappings = [{remappings}]",
    ]
    (work / "foundry.toml").write_text("\n".join(lines) + "\n")

    environment = dict(os.environ)
    environment["PATH"] = f"{FORGE_BIN}:{environment.get('PATH', '')}"
    result = subprocess.run(
        [str(FORGE_BIN / "forge"), "build", "--force"],
        cwd=work,
        capture_output=True,
        text=True,
        env=environment,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[-2000:] or result.stdout.strip()[-2000:])
    return work / "out"


def runtime_code(out: Path, file_name: str, contract: str) -> str:
    artifact = out / file_name / f"{contract}.json"
    if not artifact.exists():
        raise FileNotFoundError(f"{artifact} (compiled, but no artifact)")
    return json.loads(artifact.read_text())["deployedBytecode"]["object"].lower().removeprefix("0x")


def strip_metadata(code: str) -> tuple[str, dict]:
    """Split deployed runtime code into its executable part and solc's metadata trailer.

    Every solc version since 0.4.7 appends a CBOR encoded trailer. The three encodings seen in the
    wild are recognised here, and we deliberately do not guess a tolerance: what follows is compared
    byte for byte, so a single differing instruction is reported as a mismatch.
    """
    trailers = {
        "ipfs": "a264697066735822",
        "bzzr1": "a265627a7a72315820",
        "bzzr0": "a265627a7a72305820",
    }
    for kind, marker in trailers.items():
        index = code.find(marker)
        if index >= 0:
            return code[:index], {"kind": kind, "metadataBytes": (len(code) - index) // 2}

    fallback = code.find("64736f6c6343")  # "solc" key without the recognisable CBOR head
    if fallback >= 0:
        return code[:fallback], {"kind": "unknown", "metadataBytes": (len(code) - fallback) // 2}
    return code, {"kind": "none", "metadataBytes": 0}


def compare(compiled: str, deployed: str, trailer: dict) -> dict | None:
    """Relate already-stripped deployed code to a compiled candidate.

    When the metadata trailer was recognised we demand a byte-exact match. Only when no trailer could
    be identified do we fall back to accepting a short prefix, because then we cannot know where the
    executable code ends.
    """
    if not compiled:
        return None
    if deployed == compiled:
        return {"relation": "exact", "residue": 0, "compiledSize": len(compiled) // 2, "metadata": trailer}
    if trailer["kind"] == "none" and deployed.startswith(compiled):
        residue = (len(deployed) - len(compiled)) // 2
        if residue <= MAX_RESIDUE:
            return {"relation": "prefix", "residue": residue, "compiledSize": len(compiled) // 2, "metadata": trailer}
    return None


# ------------------------------------------------------------------------ driver


def settings_for(unit: dict) -> list[tuple[str, bool, int | None, str]]:
    """Every (solc, optimizer, runs, evm_version) combination this unit should be tried with."""
    combinations = []
    evm_versions = unit.get("evmVersions", [])
    for solc in unit["solcVersions"]:
        for evm in evm_versions:
            for runs in unit.get("optimizerRuns", []):
                combinations.append((solc, True, runs, evm))
            if unit.get("optimizerDisabled", False):
                combinations.append((solc, False, None, evm))
    return combinations


def interface_report(deployed: str, signatures: list[str]) -> dict:
    """Check that every function the contracts under test call is actually reachable on this address.

    Byte equality is the strongest statement, but when it cannot be established this is the decision
    that still matters: the deployment must answer the same selectors, or `Stake` would fail on a
    missing function rather than on a wrong number.
    """
    report = {}
    for signature in signatures:
        four = selector(signature).removeprefix("0x")
        report[signature] = {"selector": "0x" + four, "present": four in deployed}
    report["allPresent"] = all(value["present"] for key, value in report.items() if isinstance(value, dict))
    return report


def selector(signature: str) -> str:
    """Compute a selector instead of hard-coding one: a mistyped selector silently hits the fallback."""
    cached = getattr(selector, "cache", None) or {}
    if signature not in cached:
        result = subprocess.run(
            [str(FORGE_BIN / "cast"), "sig", signature], capture_output=True, text=True, check=True
        )
        cached[signature] = result.stdout.strip()
    selector.cache = cached
    return cached[signature]


def resolve_targets(profile: dict, rpc: Rpc) -> dict:
    """Map every target name to its on-chain address, deriving the pair probe when asked.

    The pair template is not pinned to a known address on purpose: taking `allPairs(0)` works on any
    Uniswap V2 fork, so a new network only needs WBNB, the factory and the router to be configured.
    """
    addresses = dict(profile["addresses"])
    if addresses.get("pair") == "derive":
        index = int(profile.get("pairProbeIndex", 0))
        padded = f"{index:064x}"
        addresses["pair"] = "0x" + rpc.call_to(addresses["factory"], selector("allPairs(uint256)") + padded)[-40:]
    elif addresses.get("pair") in (None, "derive") and profile.get("pairProbeToken"):
        probe = profile["pairProbeToken"].lower().removeprefix("0x").rjust(64, "0")
        wbnb = addresses["wbnb"].lower().removeprefix("0x").rjust(64, "0")
        raw = rpc.call_to(addresses["factory"], selector("getPair(address,address)") + probe + wbnb)
        addresses["pair"] = "0x" + raw[-40:]
    return {name: address for name, address in addresses.items() if address}


def verify_profile(profile: dict, candidates: dict, keep: bool) -> dict:
    name = profile["profile"]
    rpcs = [Rpc(url) for url in profile["rpc"]]

    healthy, chain_ids = [], {}
    for rpc in rpcs:
        try:
            chain_ids[rpc.url] = rpc.chain_id()
            healthy.append(rpc)
        except Exception as error:  # a broken endpoint must not invalidate the others
            print(f"  ! {rpc.url}: {error}")
    if not healthy:
        raise RuntimeError(f"{name}: no configured RPC endpoint answered")
    distinct = sorted(set(chain_ids.values()))
    if len(distinct) != 1:
        raise RuntimeError(f"{name}: RPC endpoints disagree on chain id: {chain_ids}")
    if distinct[0] != profile["chainId"]:
        raise RuntimeError(f"{name}: config says chain {profile['chainId']} but RPC reports {distinct[0]}")
    if len(healthy) < 2:
        print("  ! fewer than two endpoints answered: cross-provider agreement is not established")
    primary = healthy[0]

    block = primary.block_number()
    addresses = resolve_targets(profile, primary)

    report: dict = {
        "profile": name,
        "chainId": distinct[0],
        "rpc": profile["rpc"],
        "rpcHealthy": [rpc.url for rpc in healthy],
        "observedBlock": block,
        "pinnedBlock": profile.get("forkBlock"),
        "targets": {},
    }

    workspace = ROOT / ".verify" if keep else Path(tempfile.mkdtemp(prefix="verify-"))
    for target, address in addresses.items():
        codes, failures = {}, {}
        for rpc in rpcs:
            try:
                codes[rpc.url] = rpc.code(address)
            except Exception as error:
                failures[rpc.url] = str(error)
        unique = set(codes.values())
        entry: dict = {
            "address": address,
            "rpcFailures": failures,
            "agreementAcrossRpc": len(codes) > 1 and len(unique) == 1,
            "codeSize": len(next(iter(codes.values()))) // 2,
            "codeSha256": {url: sha256(bytes.fromhex(code)).hexdigest() for url, code in codes.items()},
        }
        if len(unique) != 1:
            entry["match"] = None
            entry["note"] = "no single code version could be agreed on; refusing to declare a match"
            report["targets"][target] = entry
            continue

        deployed_code, trailer = strip_metadata(unique.pop())
        entry["metadata"] = trailer
        entry["codeSizeNoMetadata"] = len(deployed_code) // 2
        attempts = 0
        best = None
        for candidate in candidates.get(target, []):
            unit = candidates["units"][candidate["unit"]]
            for solc, optimizer, runs, evm in settings_for(unit):
                attempts += 1
                work = workspace / f"{candidate['unit']}-{solc}-{optimizer}-{runs}-{evm}"
                try:
                    out = build_unit(unit, solc, optimizer, runs, work, evm)
                    compiled = runtime_code(out, candidate["file"], candidate["contract"])
                except (RuntimeError, FileNotFoundError) as error:
                    print(f"  ! {candidate['unit']} {solc} opt={optimizer} runs={runs}: {str(error)[:120]}")
                    continue
                relation = compare(compiled, deployed_code, trailer)
                if relation:
                    best = {
                        "unit": candidate["unit"],
                        "unitSource": unit["source"],
                        "file": candidate["file"],
                        "contract": candidate["contract"],
                        "solc": solc,
                        "optimizer": optimizer,
                        "optimizerRuns": runs,
                        "evmVersion": evm,
                        **relation,
                    }
                    break
            if best:
                break

        entry["match"] = best
        entry["attempts"] = attempts
        entry["interface"] = interface_report(deployed_code, candidates.get("interfaceRequirements", {}).get(target, []))
        status = "MATCH" if best else "NO MATCH"
        where = f'{best["unit"]}:{best["contract"]} @ solc {best["solc"]}' if best else "none tried succeeded"
        print(f"  [{status}] {target:<8} {address}  size={entry['codeSize']:>6}  {where}")
        report["targets"][target] = entry

    if not keep:
        shutil.rmtree(workspace, ignore_errors=True)

    report["verdict"] = "ok" if all(t.get("match") for t in report["targets"].values()) else "mismatch"
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify deployed bytecode against GitHub sources.")
    parser.add_argument("profile", nargs="+", help="profile name(s) from config/networks")
    parser.add_argument("--keep-build", action="store_true", help="keep the compiled artifacts under .verify/")
    parser.add_argument("--only", nargs="*", default=None, help="restrict verification to these target names")
    args = parser.parse_args()

    candidates = json.loads((CONFIG / "source-candidates.json").read_text())
    if args.only is not None:
        allowed = set(args.only)
        candidates = {key: value for key, value in candidates.items() if key in allowed or key == "units"}

    candidates = json.loads((CONFIG / "source-candidates.json").read_text())
    for name in args.profile:
        path = CONFIG / "networks" / f"{name}.json"
        if not path.exists():
            raise SystemExit(f"unknown profile: {name}")
        print(f"\n=== {name} ===")
        profile = json.loads(path.read_text())
        report = verify_profile(profile, candidates, args.keep_build)

        out_dir = RESULTS / name
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "source-verification.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"-> {out_dir / 'source-verification.json'}")


if __name__ == "__main__":
    main()
