pragma solidity ^0.8.20;


import { BeaconProxy } from '@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol';

contract Beacon is BeaconProxy {

    constructor(address beacon, bytes memory data) BeaconProxy(beacon, data) {

    }
}
