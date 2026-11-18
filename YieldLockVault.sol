// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @dev 테스트용 기초 자산(ERC-20). 배포자에게 1,000,000 mUSDC 발행.
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }

    /// @dev 시연용: 누구나 테스트 토큰을 받을 수 있음 (실서비스 금지)
    function freeMint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title YieldLockVault (final)
 * @dev ERC-4626 + block.timestamp 기반 타임락 적금 보관소
 *
 *  - 지분(vUSDC) 전송 차단          : 다른 주소로 옮겨 락업 우회 불가
 *  - 본인 예치만 허용               : 제3자가 남의 락업을 연장 불가
 *  - 락업 중 maxWithdraw/maxRedeem=0: ERC-4626 표준 준수
 *  - 락업 기간 상한(30일)           : 관리자 실수/악용으로 예치 불능 방지
 *  - 예치자 없을 때 이자 투입 차단  : 이자가 첫 예치자에게 몰리는 상황 방지
 *  - getUserInfo()                  : 테스트 시 한 번에 상태 확인
 */
contract YieldLockVault is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_LOCK_DURATION = 30 days;

    /// @notice 락업 시간 (초). 예: 180 = 3분
    uint256 public lockDuration;

    /// @notice 주소별 만기 해제 시각 (Unix timestamp)
    mapping(address => uint256) public lockUntil;

    event Locked(address indexed user, uint256 unlockTime);
    event LockDurationUpdated(uint256 newDuration);
    event YieldInjected(address indexed provider, uint256 amount);

    error StillLocked(uint256 unlockTime);
    error OnlySelfDeposit();
    error ShareTransferDisabled();
    error ZeroAmount();
    error NoDepositors();
    error DurationTooLong();

    constructor(IERC20 _asset, uint256 _lockDuration)
        ERC4626(_asset)
        ERC20("YieldLock Vault Share", "vUSDC")
        Ownable(msg.sender)
    {
        if (_lockDuration > MAX_LOCK_DURATION) revert DurationTooLong();
        lockDuration = _lockDuration;
    }

    // ---------------- 관리자 ----------------

    /// @notice 락업 기간 변경 (이후 새로 예치하는 건부터 적용)
    function setLockDuration(uint256 _newDuration) external onlyOwner {
        if (_newDuration > MAX_LOCK_DURATION) revert DurationTooLong();
        lockDuration = _newDuration;
        emit LockDurationUpdated(_newDuration);
    }

    // ---------------- 핵심 오버라이드 ----------------

    /// @dev 예치 시 만기 설정. 추가 예치하면 전체 잔액의 만기가 새로 시작됨.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != receiver) revert OnlySelfDeposit();
        if (assets == 0 || shares == 0) revert ZeroAmount();

        super._deposit(caller, receiver, assets, shares);

        lockUntil[receiver] = block.timestamp + lockDuration;
        emit Locked(receiver, lockUntil[receiver]);
    }

    /// @dev 출금 시 만기 검증
    function _withdraw(
        address caller,
        address receiver,
        address shareOwner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 unlockTime = lockUntil[shareOwner];
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);

        super._withdraw(caller, receiver, shareOwner, assets, shares);
    }

    /// @dev 민트(from=0)와 소각(to=0)만 허용, 일반 전송은 차단
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert ShareTransferDisabled();
        super._update(from, to, value);
    }

    /// @dev 락업 중에는 출금 가능 한도 0
    function maxWithdraw(address user) public view override returns (uint256) {
        if (block.timestamp < lockUntil[user]) return 0;
        return super.maxWithdraw(user);
    }

    function maxRedeem(address user) public view override returns (uint256) {
        if (block.timestamp < lockUntil[user]) return 0;
        return super.maxRedeem(user);
    }

    // ---------------- 이자 유입 / 조회 ----------------

    /// @notice 모의 이자 투입: 기초 자산을 Vault로 보내 지분 가치를 올림
    /// @dev 먼저 asset.approve(vault, amount) 필요
    function injectYield(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (totalSupply() == 0) revert NoDepositors();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldInjected(msg.sender, amount);
    }

    /// @notice 출금까지 남은 시간(초)
    function getRemainingLockTime(address user) public view returns (uint256) {
        uint256 t = lockUntil[user];
        return block.timestamp >= t ? 0 : t - block.timestamp;
    }

    /// @notice 사용자 상태 한 번에 조회 (테스트/UI용)
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 shares,
            uint256 assetsValue,
            uint256 unlockTime,
            uint256 remainingSeconds
        )
    {
        shares = balanceOf(user);
        assetsValue = convertToAssets(shares);
        unlockTime = lockUntil[user];
        remainingSeconds = getRemainingLockTime(user);
    }
}
