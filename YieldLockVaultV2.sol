// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title YieldLockVaultV2
 * @dev V1 + "시간에 따라 이자가 자동으로 늘어나는" 모의 이자.
 *
 *  원리
 *   - 이자 재원: 누군가 fundReserve()로 넣어 둔 '이자 보관금(rewardReserve)'.
 *     이 돈은 처음엔 지분 가치(totalAssets)에 포함되지 않는다.
 *   - 시간이 흐르면 (예치금 x 초당 이율 x 경과 초)만큼이 보관금에서 빠져나와
 *     totalAssets에 들어간다 -> 지분 1개의 가치가 시간에 비례해 오른다.
 *   - 보관금이 바닥나면 이자는 멈춘다.
 *
 *  주의: 실제 수익원이 아니라 시연용 모의 이자다. 보관금은 컨트랙트 소유자 등이 직접 채운 돈이다.
 */
contract YieldLockVaultV2 is ERC4626, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_LOCK_DURATION = 30 days;

    /// @dev 이율 단위: 1e18 = 초당 100%
    uint256 public constant RATE_SCALE = 1e18;
    /// @dev 이율 상한(시연용으로 넉넉히): 초당 0.1%
    uint256 public constant MAX_RATE_PER_SECOND = 1e15;

    uint256 public lockDuration;
    mapping(address => uint256) public lockUntil;

    /// @notice 초당 이율 (RATE_SCALE 기준)
    uint256 public ratePerSecond;
    /// @notice 마지막으로 이자를 장부에 반영한 시각
    uint256 public lastAccrual;
    /// @notice 아직 지분 가치에 반영되지 않은 이자 보관금
    uint256 public rewardReserve;

    event Locked(address indexed user, uint256 unlockTime);
    event LockDurationUpdated(uint256 newDuration);
    event YieldInjected(address indexed provider, uint256 amount);
    event ReserveFunded(address indexed provider, uint256 amount);
    event RateUpdated(uint256 newRatePerSecond);
    event YieldAccrued(uint256 amount);

    error StillLocked(uint256 unlockTime);
    error OnlySelfDeposit();
    error ShareTransferDisabled();
    error ZeroAmount();
    error NoDepositors();
    error DurationTooLong();
    error RateTooHigh();

    constructor(IERC20 _asset, uint256 _lockDuration, uint256 _ratePerSecond)
        ERC4626(_asset)
        ERC20("YieldLock Vault Share", "vUSDC")
        Ownable(msg.sender)
    {
        if (_lockDuration > MAX_LOCK_DURATION) revert DurationTooLong();
        if (_ratePerSecond > MAX_RATE_PER_SECOND) revert RateTooHigh();
        lockDuration = _lockDuration;
        ratePerSecond = _ratePerSecond;
        lastAccrual = block.timestamp;
    }

    // ---------------- 관리자 ----------------

    function setLockDuration(uint256 _newDuration) external onlyOwner {
        if (_newDuration > MAX_LOCK_DURATION) revert DurationTooLong();
        lockDuration = _newDuration;
        emit LockDurationUpdated(_newDuration);
    }

    /// @notice 초당 이율 변경 (변경 전까지 쌓인 이자는 먼저 반영)
    function setRatePerSecond(uint256 _newRate) external onlyOwner {
        if (_newRate > MAX_RATE_PER_SECOND) revert RateTooHigh();
        _accrue();
        ratePerSecond = _newRate;
        emit RateUpdated(_newRate);
    }

    // ---------------- 이자 ----------------

    /// @dev 아직 장부에 반영되지 않은 이자 (보관금을 넘지 않음)
    function _pendingYield() internal view returns (uint256) {
        if (rewardReserve == 0 || ratePerSecond == 0 || totalSupply() == 0) return 0;
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return 0;

        uint256 principal = IERC20(asset()).balanceOf(address(this)) - rewardReserve;
        uint256 p = (principal * ratePerSecond * elapsed) / RATE_SCALE;
        return p > rewardReserve ? rewardReserve : p;
    }

    /// @dev 이자를 보관금에서 꺼내 장부에 반영하고 기준 시각을 갱신
    function _accrue() internal {
        uint256 p = _pendingYield();
        if (p > 0) {
            rewardReserve -= p;
            emit YieldAccrued(p);
        }
        lastAccrual = block.timestamp;
    }

    /// @notice 조회용: 아직 반영 전인 이자
    function pendingYield() external view returns (uint256) {
        return _pendingYield();
    }

    /// @notice 이자 보관금 채우기 (먼저 asset.approve(vault, amount) 필요)
    function fundReserve(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice (V1 호환) 즉시 지분 가치를 올리는 모의 이자 투입
    function injectYield(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (totalSupply() == 0) revert NoDepositors();
        _accrue();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit YieldInjected(msg.sender, amount);
    }

    /// @dev 보관금은 제외하고, 시간이 지나 쌓인 이자는 포함
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - rewardReserve + _pendingYield();
    }

    // ---------------- 핵심 오버라이드 ----------------

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != receiver) revert OnlySelfDeposit();
        if (assets == 0 || shares == 0) revert ZeroAmount();

        _accrue();
        super._deposit(caller, receiver, assets, shares);

        lockUntil[receiver] = block.timestamp + lockDuration;
        emit Locked(receiver, lockUntil[receiver]);
    }

    function _withdraw(
        address caller,
        address receiver,
        address shareOwner,
        uint256 assets,
        uint256 shares
    ) internal override {
        uint256 unlockTime = lockUntil[shareOwner];
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);

        _accrue();
        super._withdraw(caller, receiver, shareOwner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert ShareTransferDisabled();
        super._update(from, to, value);
    }

    function maxWithdraw(address user) public view override returns (uint256) {
        if (block.timestamp < lockUntil[user]) return 0;
        return super.maxWithdraw(user);
    }

    function maxRedeem(address user) public view override returns (uint256) {
        if (block.timestamp < lockUntil[user]) return 0;
        return super.maxRedeem(user);
    }

    // ---------------- 조회 ----------------

    function getRemainingLockTime(address user) public view returns (uint256) {
        uint256 t = lockUntil[user];
        return block.timestamp >= t ? 0 : t - block.timestamp;
    }

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
