pragma solidity ^0.8.20;

interface ISEFVesting {
    /// @param _recipient Address of the Vesting. recipient entitled to claim the vested funds
    /// @param _amount Total number of tokens Vested
    function deposit(address _recipient, uint256 _amount) external;
}
