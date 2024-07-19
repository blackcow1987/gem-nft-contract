// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDepositManager {
    function requestWithdrawal(address layer2, uint256 amount) external returns (bool);
    function processRequest(address layer2, bool receiveTON) external returns (bool);
    function getDelayBlocks(address layer2) external view returns (uint256);
}

interface ICandidate {
    function updateSeigniorage() external returns (bool);
}

interface ISeigManager {
    function stakeOf(address account) external view returns (uint256);
}

interface ITON {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approveAndCall(address spender, uint256 amount, bytes memory data) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract WrappedStakedTON is ERC20 {
    ICandidate public constant LAYER2 = ICandidate(0x06D34f65869Ec94B3BA8c0E08BCEb532f65005E2);
    address public constant SEIG_MANAGER = 0x0b55a0f463b6DEFb81c6063973763951712D0E5F;
    address public constant DEPOSIT_MANAGER = 0x0b58ca72b12F01FC05F8f252e226f3E2089BD00E;
    address public constant WTON = 0xc4A11aaf6ea915Ed7Ac194161d2fC9384F15bff2;
    ITON public constant TON = ITON(0x2be5e8c109e2197D077D13A82dAead6a9b3433C5);
    uint256 public updatedAt;

    struct WithdrawRequest {
        address owner;
        uint256 amount;
        uint256 blockNumber;
        bool processed;
    }

    WithdrawRequest[] public withdrawRequests;

    event Mint(address indexed account, uint256 amount);
    event Burn(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped Staked TON", "WSTON") {}

    function mint(uint256 amount) external {
        require(amount > 0, "WrappedStakedTON: amount is zero");

        // update seigniorage once a day
        if (updatedAt < block.number) {
            require(LAYER2.updateSeigniorage(), "WrappedStakedTON: updateSeigniorage");
            updatedAt = block.number + 7200;
        }

        uint256 stakeOf = ISeigManager(SEIG_MANAGER).stakeOf(address(this));
        if (stakeOf == 0) {
            _mint(msg.sender, amount);
        } else {
            _mint(msg.sender, totalSupply() * amount / stakeOf);
        }

        TON.transferFrom(msg.sender, address(this), amount);
        bytes memory data = abi.encode(DEPOSIT_MANAGER, address(LAYER2));
        require(ITON(TON).approveAndCall(WTON, amount, data), "WrappedStakedTON: approveAndCall");

        emit Mint(msg.sender, amount);
    }

    function burn(uint256 amount) external {
        require(amount > 0, "WrappedStakedTON: amount is zero");

        // update seigniorage once a day
        if (updatedAt < block.number) {
            require(LAYER2.updateSeigniorage(), "WrappedStakedTON: updateSeigniorage");
            updatedAt = block.number + 7200;
        }
        uint256 stakeOf = ISeigManager(SEIG_MANAGER).stakeOf(address(this));
        uint256 withdrawAmount = amount * stakeOf / totalSupply();

        require(
            IDepositManager(DEPOSIT_MANAGER).requestWithdrawal(address(LAYER2), withdrawAmount),
            "WrappedStakedTON: requestWithdrawal"
        );

        WithdrawRequest memory request;
        request.owner = msg.sender;
        request.amount = withdrawAmount;
        request.blockNumber = block.number + IDepositManager(DEPOSIT_MANAGER).getDelayBlocks(address(LAYER2));
        withdrawRequests.push(request);

        _burn(msg.sender, amount);

        emit Burn(msg.sender, amount);
    }

    function withdraw(uint256 idx) external {
        require(idx < withdrawRequests.length, "WrappedStakedTON: invalid index");

        WithdrawRequest storage request = withdrawRequests[idx];
        require(request.owner == msg.sender, "WrappedStakedTON: not owner");
        require(request.blockNumber <= block.number, "WrappedStakedTON: block number");
        require(request.processed == false, "WrappedStakedTON: processed");
        require(
            IDepositManager(DEPOSIT_MANAGER).processRequest(address(LAYER2), false), "WrappedStakedTON: processRequest"
        );

        request.processed = true;

        uint256 amount = request.amount;
        IERC20(WTON).transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }
}
