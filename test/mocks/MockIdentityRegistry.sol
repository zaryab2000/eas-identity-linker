// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Minimal ERC-721 mock simulating the ERC-8004 Identity Registry.
contract MockIdentityRegistry is ERC721 {
    constructor() ERC721("MockAgent", "MAGT") {}

    function mint(address to, uint256 agentId) external {
        _mint(to, agentId);
    }

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        return _isAuthorized(_ownerOf(agentId), spender, agentId);
    }
}
