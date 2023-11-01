pragma solidity ^0.8.20;


import { ProxyAdmin as Admin } from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';

contract ProxyAdmin is Admin {

    constructor(address initialOwner) Admin(initialOwner) {

    }
}
