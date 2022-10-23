// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {TokenProvider} from "./utils/TokenProvider.sol";
import {Permit2} from "../src/Permit2.sol";
import {
    Permit,
    InvalidSignature,
    SignatureExpired,
    InvalidNonce,
    PackedAllowance,
    ExcessiveInvalidation,
    LengthMismatch
} from "../src/Permit2Utils.sol";
import {PermitSignature} from "./utils/PermitSignature.sol";
import {SignatureVerification} from "../src/libraries/SignatureVerification.sol";
import {AddressBuilder} from "./utils/AddressBuilder.sol";
import {AmountBuilder} from "./utils/AmountBuilder.sol";

import {MockPermit2} from "./mocks/MockPermit2.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

contract AllowanceTransferTest is Test, TokenProvider, PermitSignature, GasSnapshot {
    using stdStorage for StdStorage;

    event InvalidateNonces(address indexed owner, uint32 indexed toNonce, address token, address spender);

    MockPermit2 permit2;

    address from;
    uint256 fromPrivateKey;

    address fromDirty;
    uint256 fromPrivateKeyDirty;

    address address0 = address(0);
    address address2 = address(2);

    uint160 defaultAmount = 10 ** 18;
    uint32 defaultNonce = 0;
    uint64 defaultExpiration = uint64(block.timestamp + 5);

    // has some balance of token0
    address address3 = address(3);

    bytes32 DOMAIN_SEPARATOR;

    function setUp() public {
        permit2 = new MockPermit2();
        DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        fromPrivateKey = 0x12341234;
        from = vm.addr(fromPrivateKey);

        // Use this address to gas test dirty writes later.
        fromPrivateKeyDirty = 0x56785678;
        fromDirty = vm.addr(fromPrivateKeyDirty);

        initializeERC20Tokens();

        setERC20TestTokens(from);
        setERC20TestTokenApprovals(vm, from, address(permit2));

        setERC20TestTokens(fromDirty);
        setERC20TestTokenApprovals(vm, fromDirty, address(permit2));

        // dirty the nonce for fromDirty address
        permit2.setAllowance(fromDirty, address(token0), address(this), 1);

        // ensure address3 has some balance of token0 for dirty sstore on transfer
        token0.mint(address3, defaultAmount);
    }

    function testApprove() public {
        vm.prank(from);
        permit2.approve(address(token0), address(this), defaultAmount, defaultExpiration);

        (uint160 amount, uint64 expiration,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);
        assertEq(expiration, defaultExpiration);
    }

    function testSetAllowance() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        snapStart("permitCleanWrite");
        permit2.permit(permit, from, sig);
        snapEnd();

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);
    }

    function testSetAllowanceDirtyWrite() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 1);
        bytes memory sig = getPermitSignature(permit, 1, fromPrivateKeyDirty, DOMAIN_SEPARATOR);

        snapStart("permitDirtyWrite");
        permit2.permit(permit, fromDirty, sig);
        snapEnd();

        (uint160 amount,,) = permit2.allowance(fromDirty, address(token0), address(this));
        assertEq(amount, defaultAmount);
    }

    // test setting allowance with ordered nonce and transfer
    function testSetAllowanceTransfer() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        permit2.permit(permit, from, sig);

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));

        assertEq(amount, defaultAmount);

        permit2.transferFrom(address(token0), from, address0, defaultAmount);
        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address0), startBalanceTo + defaultAmount);
    }

    function testTransferFromWithGasSnapshot() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        permit2.permit(permit, from, sig);

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));

        assertEq(amount, defaultAmount);

        snapStart("transferFrom");
        permit2.transferFrom(address(token0), from, address0, defaultAmount);
        snapEnd();
        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address0), startBalanceTo + defaultAmount);
    }

    function testBatchTransferFromWithGasSnapshot() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        permit2.permit(permit, from, sig);

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);

        // permit token0 for 10 ** 18
        address[] memory tokens = AddressBuilder.fill(3, address(token0));
        uint160[] memory amounts = AmountBuilder.fillUInt160(3, 1 ** 18);
        address[] memory recipients = AddressBuilder.fill(3, address0);
        snapStart("batchTransferFrom");
        permit2.batchTransferFrom(tokens, from, recipients, amounts);
        snapEnd();
        assertEq(token0.balanceOf(from), startBalanceFrom - 3 * 1 ** 18);
        assertEq(token0.balanceOf(address0), startBalanceTo + 3 * 1 ** 18);
        (amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount - 3 * 1 ** 18);
    }

    // dirty sstore on nonce, dirty sstore on transfer
    function testSetAllowanceTransferDirtyNonceDirtyTransfer() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 1);
        bytes memory sig = getPermitSignature(permit, 1, fromPrivateKeyDirty, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(fromDirty);
        uint256 startBalanceTo = token0.balanceOf(address3);
        // ensure its a dirty store for the recipient address
        assertEq(startBalanceTo, defaultAmount);

        snapStart("permitDirtyNonce");
        permit2.permit(permit, fromDirty, sig);
        snapEnd();

        (uint160 amount,,) = permit2.allowance(fromDirty, address(token0), address(this));
        assertEq(amount, defaultAmount);

        permit2.transferFrom(address(token0), fromDirty, address3, defaultAmount);
        assertEq(token0.balanceOf(fromDirty), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address3), startBalanceTo + defaultAmount);
    }

    function testSetAllowanceInvalidSignature() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);
        snapStart("permitInvalidSigner");
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit.spender = address0;
        permit2.permit(permit, from, sig);
        snapEnd();
    }

    function testSetAllowanceDeadlinePassed() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        vm.warp(block.timestamp + 101);
        snapStart("permitSignatureExpired");
        vm.expectRevert(SignatureExpired.selector);
        permit2.permit(permit, from, sig);
        snapEnd();
    }

    function testMaxAllowance() public {
        uint160 maxAllowance = type(uint160).max;
        Permit memory permit = defaultERC20PermitAllowance(address(token0), maxAllowance, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        snapStart("permitSetMaxAllowanceCleanWrite");
        permit2.permit(permit, from, sig);
        snapEnd();

        (uint160 startAllowedAmount0,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(startAllowedAmount0, type(uint160).max);

        permit2.transferFrom(address(token0), from, address0, defaultAmount);
        (uint160 endAllowedAmount0,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(endAllowedAmount0, type(uint160).max);

        assertEq(token0.balanceOf(from), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address0), startBalanceTo + defaultAmount);
    }

    function testMaxAllowanceDirtyWrite() public {
        uint160 maxAllowance = type(uint160).max;
        Permit memory permit = defaultERC20PermitAllowance(address(token0), maxAllowance, defaultExpiration, 1);
        bytes memory sig = getPermitSignature(permit, 1, fromPrivateKeyDirty, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(fromDirty);
        uint256 startBalanceTo = token0.balanceOf(address0);

        snapStart("permitSetMaxAllowanceDirtyWrite");
        permit2.permit(permit, fromDirty, sig);
        snapEnd();

        (uint160 startAllowedAmount0,,) = permit2.allowance(fromDirty, address(token0), address(this));
        assertEq(startAllowedAmount0, type(uint160).max);

        permit2.transferFrom(address(token0), fromDirty, address0, defaultAmount);
        (uint160 endAllowedAmount0,,) = permit2.allowance(fromDirty, address(token0), address(this));
        assertEq(endAllowedAmount0, type(uint160).max);

        assertEq(token0.balanceOf(fromDirty), startBalanceFrom - defaultAmount);
        assertEq(token0.balanceOf(address0), startBalanceTo + defaultAmount);
    }

    function testPartialAllowance() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        permit2.permit(permit, from, sig);

        (uint160 startAllowedAmount0,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(startAllowedAmount0, defaultAmount);

        uint160 transferAmount = 5 ** 18;
        permit2.transferFrom(address(token0), from, address0, transferAmount);

        (uint160 endAllowedAmount0,,) = permit2.allowance(from, address(token0), address(this));
        // ensure the allowance was deducted
        assertEq(endAllowedAmount0, defaultAmount - transferAmount);

        assertEq(token0.balanceOf(from), startBalanceFrom - transferAmount);
        assertEq(token0.balanceOf(address0), startBalanceTo + transferAmount);
    }

    function testReuseOrderedNonceInvalid() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        permit2.permit(permit, from, sig);
        (,, uint32 nonce) = permit2.allowance(from, address(token0), address(this));
        assertEq(nonce, 1);

        (uint160 amount, uint64 expiration,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);
        assertEq(expiration, defaultExpiration);

        vm.expectRevert(InvalidNonce.selector);
        permit2.permit(permit, from, sig);
    }

    function testInvalidateNonces() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        // just need to invalidate 1 nonce on from address
        vm.prank(from);
        vm.expectEmit(true, true, false, true);
        emit InvalidateNonces(from, 1, address(token0), address(this));
        permit2.invalidateNonces(address(token0), address(this), 1);
        (,, uint32 nonce) = permit2.allowance(from, address(token0), address(this));
        assertEq(nonce, 1);

        vm.expectRevert(InvalidNonce.selector);
        permit2.permit(permit, from, sig);
    }

    function testExcessiveInvalidation() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint32 numInvalidate = type(uint16).max;
        vm.startPrank(from);
        vm.expectRevert(ExcessiveInvalidation.selector);
        permit2.invalidateNonces(address(token0), address(this), numInvalidate + 1);
        vm.stopPrank();

        permit2.permit(permit, from, sig);
        (,, uint32 nonce) = permit2.allowance(from, address(token0), address(this));
        assertEq(nonce, 1);
    }

    function testBatchTransferFrom() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        uint256 startBalanceFrom = token0.balanceOf(from);
        uint256 startBalanceTo = token0.balanceOf(address0);

        permit2.permit(permit, from, sig);

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);

        // permit token0 for 10 ** 18
        address[] memory tokens = AddressBuilder.fill(3, address(token0));
        uint160[] memory amounts = AmountBuilder.fillUInt160(3, 1 ** 18);
        address[] memory recipients = AddressBuilder.fill(3, address0);

        snapStart("batchTransferFrom");
        permit2.batchTransferFrom(tokens, from, recipients, amounts);
        snapEnd();
        assertEq(token0.balanceOf(from), startBalanceFrom - 3 * 1 ** 18);
        assertEq(token0.balanceOf(address0), startBalanceTo + 3 * 1 ** 18);
        (amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount - 3 * 1 ** 18);
    }

    function testBatchTransferFromLengthMismatch() public {
        Permit memory permit = defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, 0);
        bytes memory sig = getPermitSignature(permit, defaultNonce, fromPrivateKey, DOMAIN_SEPARATOR);

        permit2.permit(permit, from, sig);

        (uint160 amount,,) = permit2.allowance(from, address(token0), address(this));
        assertEq(amount, defaultAmount);

        // permit token0 for 10 ** 18
        address[] memory tokens = AddressBuilder.fill(3, address(token0));
        uint160[] memory amounts = AmountBuilder.fillUInt160(3, 1 ** 18);
        address[] memory recipients = AddressBuilder.fill(4, address0);

        vm.expectRevert(LengthMismatch.selector);
        permit2.batchTransferFrom(tokens, from, recipients, amounts);
    }
}