// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

/// @dev The subset of cheatcodes this harness needs, declared by hand exactly like the business
///      repositories do, so the compatibility project pulls in no third-party testing library.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    // configuration
    function envString(string calldata name) external view returns (string memory value);
    function envUint(string calldata name) external view returns (uint256 value);
    function envBool(string calldata name) external view returns (bool value);
    function envAddress(string calldata name) external view returns (address value);
    function envOr(string calldata name, bool defaultValue) external view returns (bool value);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256 value);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory value);
    function envExists(string calldata name) external view returns (bool result);

    // chains
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function activeFork() external view returns (uint256 forkId);
    function rpcUrl(string calldata alias_) external view returns (string memory url);
    function label(address account, string calldata newLabel) external;

    // state
    function deal(address account, uint256 newBalance) external;
    function getNonce(address account) external view returns (uint256 nonce);
    function computeCreateAddress(address deployer, uint256 nonce) external pure returns (address);
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;

    // artefacts
    function getCode(string calldata artifactName) external view returns (bytes memory creationBytecode);

    // evidence capture
    function writeFile(string calldata path, string calldata data) external;
    function writeLine(string calldata path, string calldata data) external;
    function removeFile(string calldata path) external;

    // formatting, used to make assertion messages carry the offending numbers
    function toString(uint256 value) external pure returns (string memory stringifiedValue);
    function toString(address value) external pure returns (string memory stringifiedValue);
    function toString(bool value) external pure returns (string memory stringifiedValue);

    // expectations
    function expectRevert(bytes calldata expectedData) external;
    function expectEmit() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}
