pragma solidity ^0.8.20;

import { TimelockController as TimelockBase } from "@openzeppelin/contracts/governance/TimelockController.sol";

contract Timelock is TimelockBase {

    constructor(address[] memory proposers, address[] memory executors) TimelockBase(
        48 hours, proposers, executors, address(0)
    ) {

    }
}
