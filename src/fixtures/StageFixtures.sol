// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

/// @dev These fixtures deliberately do NOT declare `is IPhase` / `is IVote` / `is IMemberNFT`:
///      `Stake` calls each dependency through its interface, so what has to exist on chain is the one
///      function it calls. Inheriting would force implementing dozens of functions `Stake` never asks
///      about, and every unimplemented one would be dead code that could silently drift from core.
contract MockPhase {
    uint256 public currentPhaseNumber;

    function setPhase(uint256 phase) external {
        currentPhaseNumber = phase;
    }

    function currentPhase() external view returns (uint256) {
        return currentPhaseNumber;
    }
}

/// @dev Reports zero votes for everyone, so `mergeStake`'s "already voted" check stays open.
contract MockVote {
    function votesNumByMemberId(address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev A member NFT reduced to ownership: `Stake` only ever asks `ownerOf`.
contract MockMemberNFT {
    mapping(uint256 => address) internal _owner;

    function setOwner(uint256 memberId, address owner) external {
        _owner[memberId] = owner;
    }

    function ownerOf(uint256 memberId) public view returns (address owner) {
        owner = _owner[memberId];
        require(owner != address(0), "MockMemberNFT: no such member");
    }
}
